#!/usr/bin/env bash
# =============================================================
# deploy-node.sh — Redis 哨兵拓扑「分角色」部署（懒人模式，systemd 托管）
#
# 一条命令部署一个角色，redis.conf / sentinel.conf 按当前环境自动生成，
# 不需要手写配置、不需要手写 systemd 单元。
#
# 典型流程（1 主 2 从 3 哨兵，三台机器）：
#   # A 机（主库），只要密码和端口
#   sudo ./deploy-node.sh master --password 'YourPass' --port 6379
#
#   # B / C 机（从库），脚本会打印出可直接复制的命令
#   sudo ./deploy-node.sh replica --master-host <A的IP> --password 'YourPass'
#
#   # A/B/C 三台都执行（哨兵）
#   sudo ./deploy-node.sh sentinel --master-host <A的IP> --password 'YourPass'
#
# 单台机器做测试环境：**必须显式声明** --single-host（或直接用 single 子命令），
# 否则脚本按「一机一实例」的生产假设来调优（maxmemory 会取整机内存的 60%）。
#   sudo ./deploy-node.sh master  --single-host --port 16379 --password 'p'
#   sudo ./deploy-node.sh replica --single-host --port 16380 --master-port 16379 --password 'p'
#   sudo ./deploy-node.sh sentinel --single-host --port 26379 --master-port 16379 --password 'p'
#   sudo ./deploy-node.sh single --password 'p'     # 一步到位：1 主 2 从 3 哨兵
#
# 子命令：
#   master            部署主库
#   replica           部署从库（需 --master-host）
#   sentinel          部署哨兵（需 --master-host）
#   single            单机测试环境：声明后一条命令拉起 1 主 2 从 3 哨兵
#   status            查看本机已部署实例与角色
#   uninstall         停止并禁用本机实例（--purge 连同配置/数据删除）
#
# 通用参数：
#   --password <p>        访问密码（master 必填；replica/sentinel 建议同值）
#   --port <n>            本实例端口（master/replica 默认 6379，sentinel 默认 26379）
#   --master-host <ip>    replica/sentinel 必填：主库地址
#   --master-port <n>     主库端口（默认 6379）
#   --master-name <name>  哨兵监控名（默认 mymaster）
#   --quorum <n>          哨兵判定客观下线的票数（默认 2 = 三哨兵多数派）
#   --pkg <tar.gz|dir>    从产物包安装二进制（未安装时必须给，或就地放在脚本同目录）
#   --bind-ip <ip>        bind 地址（默认：本机内网 IP + 127.0.0.1；填 0.0.0.0 则全网卡）
#   --announce-ip <ip>    NAT / 云主机场景下对外宣告的地址
#   --maxmemory <size>    maxmemory（如 2gb / 512mb；默认按内存自动算，0 = 不限制）
#   --policy <name>       maxmemory-policy（默认 noeviction，纯缓存可用 allkeys-lru）
#   --single-host         声明「这台机器上会跑多个实例」的测试布局
#   --dry-run             只打印将要写入的配置与执行的动作，不做任何改动
#   --no-start            只写配置和单元，不启动
#   --force               覆盖已存在的配置/单元（配置会先备份）
#   --purge               配合 uninstall：删除配置、数据、systemd 单元
#
# 自动优化依据：内存（maxmemory）、CPU 核数（io-threads）、AOF/RDB 策略、
# 内核 THP、vm.overcommit_memory、文件句柄上限。运行时会把你机器上探测到的
# 值打印出来，便于核对。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
REDIS_CONF_DIR="/etc/redis"
LOG_DIR="/var/log/redis"
BASE_DATA_DIR="/var/lib/redis"
UNIT_DIR="/etc/systemd/system"
RUN_USER="redis"

ROLE="${1:-}"
[ -n "$ROLE" ] && shift || true

PASSWORD=""
PORT=""
MASTER_HOST=""
MASTER_PORT="6379"
MASTER_NAME="mymaster"
QUORUM="2"
PKG=""
BIND_IP=""
ANNOUNCE_IP=""
MAXMEMORY=""
POLICY="noeviction"
SINGLE_HOST="no"
DRY_RUN="no"
NO_START="no"
FORCE="no"
PURGE="no"

# 单机测试布局下的实例总数（用于分摊内存）
SINGLE_HOST_INSTANCES=6

while [ $# -gt 0 ]; do
  case "$1" in
    --password)     PASSWORD="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --master-host)  MASTER_HOST="$2"; shift 2 ;;
    --master-port)  MASTER_PORT="$2"; shift 2 ;;
    --master-name)  MASTER_NAME="$2"; shift 2 ;;
    --quorum)       QUORUM="$2"; shift 2 ;;
    --pkg)          PKG="$2"; shift 2 ;;
    --bind-ip)      BIND_IP="$2"; shift 2 ;;
    --announce-ip)  ANNOUNCE_IP="$2"; shift 2 ;;
    --maxmemory)    MAXMEMORY="$2"; shift 2 ;;
    --policy)       POLICY="$2"; shift 2 ;;
    --single-host)  SINGLE_HOST="yes"; shift ;;
    --dry-run)      DRY_RUN="yes"; shift ;;
    --no-start)     NO_START="yes"; shift ;;
    --force)        FORCE="yes"; shift ;;
    --purge)        PURGE="yes"; shift ;;
    -h|--help)      sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[ERROR] 未知参数: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '>>> %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# =============================================================
# 环境探测
# =============================================================
MEM_MB="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
CORES="$(nproc 2>/dev/null || echo 1)"

detect_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s' "$ip"
}
HOST_IP="$(detect_ip)"

# 注意：脚本开了 pipefail，读这些伪文件必须容错，否则 cat 失败会把整个脚本带崩
THP_STATE="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | sed -n 's/.*\[\(.*\)\].*/\1/p' || true)"
OVERCOMMIT="$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo unknown)"
ULIMIT_N="$(ulimit -n 2>/dev/null || echo unknown)"

select_maxmemory() {
  # 已显式指定
  if [ -n "$MAXMEMORY" ]; then printf '%s' "$MAXMEMORY"; return; fi
  if [ "$MEM_MB" -le 0 ]; then printf ''; return; fi

  local mb
  if [ "$SINGLE_HOST" = "yes" ]; then
    # 单机多实例：整机 60% 由 SINGLE_HOST_INSTANCES 个实例分摊
    mb=$(( MEM_MB * 60 / 100 / SINGLE_HOST_INSTANCES ))
  else
    mb=$(( MEM_MB * 60 / 100 ))
  fi
  # 太小就没意义，也别把机器吃干
  [ "$mb" -lt 64 ] && mb=64
  [ "$mb" -gt $(( MEM_MB * 80 / 100 )) ] && mb=$(( MEM_MB * 80 / 100 ))
  printf '%dm' "$mb"
}

select_io_threads() {
  [ "$CORES" -ge 4 ] || { printf '1'; return; }
  local t=$(( CORES / 2 ))
  [ "$t" -lt 2 ] && t=2
  [ "$t" -gt 8 ] && t=8
  printf '%s' "$t"
}

# =============================================================
# 路径（生产：标准路径；单机测试：带端口后缀，避免互相覆盖）
# =============================================================
CONF_FILE=""
SENTINEL_CONF_FILE=""
DATA_DIR=""
LOG_FILE=""
UNIT_FILE=""
UNIT_NAME=""
SERVICE_ROLE=""

resolve_paths() {
  case "$ROLE" in
    master|replica)
      if [ "$SINGLE_HOST" = "yes" ]; then
        CONF_FILE="${REDIS_CONF_DIR}/redis-${PORT}.conf"
        DATA_DIR="${BASE_DATA_DIR}-${PORT}"
        LOG_FILE="${LOG_DIR}/redis-${PORT}.log"
        UNIT_NAME="redis-${PORT}.service"
      else
        CONF_FILE="${REDIS_CONF_DIR}/redis.conf"
        DATA_DIR="${BASE_DATA_DIR}"
        LOG_FILE="${LOG_DIR}/redis.log"
        UNIT_NAME="redis.service"
      fi
      UNIT_FILE="${UNIT_DIR}/${UNIT_NAME}"
      ;;
    sentinel)
      if [ "$SINGLE_HOST" = "yes" ]; then
        SENTINEL_CONF_FILE="${REDIS_CONF_DIR}/sentinel-${PORT}.conf"
        DATA_DIR="${BASE_DATA_DIR}-sentinel-${PORT}"
        LOG_FILE="${LOG_DIR}/sentinel-${PORT}.log"
        UNIT_NAME="redis-sentinel-${PORT}.service"
      else
        SENTINEL_CONF_FILE="${REDIS_CONF_DIR}/sentinel.conf"
        DATA_DIR="${BASE_DATA_DIR}-sentinel"
        LOG_FILE="${LOG_DIR}/sentinel.log"
        UNIT_NAME="redis-sentinel.service"
      fi
      UNIT_FILE="${UNIT_DIR}/${UNIT_NAME}"
      ;;
  esac
}

apply_defaults() {
  case "$ROLE" in
    master|replica)
      [ -n "$PORT" ] || { [ "$SINGLE_HOST" = "yes" ] && PORT=16379 || PORT=6379; }
      ;;
    sentinel)
      [ -n "$PORT" ] || { [ "$SINGLE_HOST" = "yes" ] && PORT=26379 || PORT=26379; }
      ;;
  esac
  [ -n "$BIND_IP" ] || BIND_IP="$HOST_IP"
  # 单机测试模式下所有实例都在 127.0.0.1，对外宣告也用 127.0.0.1，
  # 免得哨兵看到「主库在 127.0.0.1、从库在 内网IP」这种混搭地址
  if [ -n "$ANNOUNCE_IP" ]; then
    :
  elif [ "$SINGLE_HOST" = "yes" ]; then
    ANNOUNCE_IP="127.0.0.1"
  else
    ANNOUNCE_IP="$HOST_IP"
  fi
}

# =============================================================
# 前置检查
# =============================================================
preflight() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限（写 /etc/redis、/etc/systemd/system）"
  command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd（systemctl），本脚本依赖 systemd 托管"
  [ -d /run/systemd/system ] || die "systemd 未作为 init 运行（容器里请用 deploy-sentinel.sh）"

  case "$ROLE" in
    master)
      [ -n "$PASSWORD" ] || die "master 需要 --password <密码>（从库与哨兵都要用同一口令）"
      ;;
    replica)
      [ -n "$MASTER_HOST" ] || die "replica 需要 --master-host <主库IP>"
      [ -n "$PASSWORD" ] || die "replica 需要 --password（必须与主库一致，否则同步失败）"
      ;;
    sentinel)
      [ -n "$MASTER_HOST" ] || die "sentinel 需要 --master-host <主库IP>"
      [ -n "$PASSWORD" ] || die "sentinel 需要 --password：哨兵自身也要设密码，否则 protected-mode 会拒掉其它哨兵的连接，三台哨兵互不可见、永远凑不齐 quorum"
      ;;
    *) die "未知角色: ${ROLE}（可用：master / replica / sentinel / single / status / uninstall）" ;;
  esac

  # 单机测试模式：数据实例不允许占用 6379（会和机器上已有的 Redis 撞车）；
  # 哨兵用 26379 起是正常的（单机测试就是 26379/26380/26381）。
  if [ "$SINGLE_HOST" = "yes" ] && [ "$FORCE" != "yes" ]; then
    if [ "$PORT" = "6379" ]; then
      die "单机测试模式请避开标准数据端口 6379（会和机器已有的 Redis 冲突），例如 --port 16379；确要如此请加 --force"
    fi
  fi
}

# =============================================================
# 二进制安装
# =============================================================
install_binaries() {
  if [ -x "${BIN_DIR}/redis-server" ] && [ -x "${BIN_DIR}/redis-cli" ]; then
    log "已存在 ${BIN_DIR}/redis-server，跳过二进制安装"
    return 0
  fi

  local src=""
  if [ -n "$PKG" ]; then
    if [ -d "$PKG" ]; then
      src="$PKG"
    else
      [ -f "$PKG" ] || die "找不到产物包: ${PKG}"
      local tmp
      tmp="$(mktemp -d)"
      log "解包 ${PKG}"
      tar xzf "$PKG" -C "$tmp"
      src="$(find "$tmp" -maxdepth 2 -type d -exec test -e '{}/redis-server' ';' -print 2>/dev/null | head -n 1)"
      [ -n "$src" ] || die "产物包内找不到 redis-server"
    fi
  elif [ -x "${SCRIPT_DIR}/redis-server" ]; then
    src="$SCRIPT_DIR"          # 直接在解压出来的产物目录里执行本脚本
  else
    die "未安装二进制，且未指定 --pkg（可指向产物 tar.gz 或解压目录）"
  fi

  mkdir -p "$BIN_DIR"
  cp -a "${src}"/redis-* "$BIN_DIR"/ || die "复制二进制失败（源目录：${src}）"
  chmod 0755 "${BIN_DIR}"/redis-server "${BIN_DIR}"/redis-cli
  log "已安装二进制到 ${BIN_DIR}：$("${BIN_DIR}/redis-server" --version 2>&1 | head -n 1)"
}

ensure_user_dirs() {
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    log "创建运行用户 ${RUN_USER}"
    useradd -r -s /sbin/nologin "$RUN_USER" 2>/dev/null || \
      adduser -r -s /sbin/nologin "$RUN_USER" 2>/dev/null || true
  fi
  mkdir -p "$REDIS_CONF_DIR" "$LOG_DIR" "$DATA_DIR"
  chown -R "${RUN_USER}:${RUN_USER}" "$DATA_DIR" "$LOG_DIR" 2>/dev/null || true
  chmod 0750 "$DATA_DIR" 2>/dev/null || true
  # 哨兵要改写自己的配置文件（同目录建临时文件再 rename），所以配置目录必须归 redis；
  # 这是 Debian/Ubuntu 官方 redis 包的做法，否则哨兵日志会一直刷
  # "Sentinel was not able to save the new configuration on disk!!! Permission denied"
  chown "${RUN_USER}:${RUN_USER}" "$REDIS_CONF_DIR" 2>/dev/null || true
  chmod 0750 "$REDIS_CONF_DIR" 2>/dev/null || true
}

# =============================================================
# 配置生成
# =============================================================
gen_redis_conf() {
  local mm io
  mm="$(select_maxmemory)"
  io="$(select_io_threads)"

  cat <<EOF
# Generated by deploy-node.sh ($(date -u '+%Y-%m-%dT%H:%M:%SZ')) — role=${ROLE} host=${HOST_IP}
# 重新生成会覆盖手工修改；需要长期保留的改动请改本脚本或另行管理。

# ---------------- 网络 ----------------
bind ${BIND_IP} 127.0.0.1
protected-mode yes
port ${PORT}
tcp-backlog 511
timeout 0
tcp-keepalive 300
EOF

  # 多网卡 / NAT：显式宣告对外地址，否则哨兵与从库可能拿到不可达地址
  if [ -n "$ANNOUNCE_IP" ]; then
    echo "replica-announce-ip ${ANNOUNCE_IP}"
  fi

  cat <<EOF

# ---------------- 通用 ----------------
daemonize no
supervised no
pidfile /run/redis-${PORT}/redis.pid
loglevel notice
logfile ${LOG_FILE}
databases 16
maxclients 10000

# ---------------- 持久化 ----------------
# AOF 每秒钟 fsync 一次：兼顾安全与性能；RDB 作为兜底快照
save 3600 1 300 100 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir ${DATA_DIR}
appendonly yes
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-use-rdb-preamble yes
EOF

  # 内存：按机器内存自动推算（单机测试模式会按实例数分摊）
  if [ "$mm" != "0" ] && [ -n "$mm" ]; then
    cat <<EOF

# ---------------- 内存（自动推算：总内存 ${MEM_MB}MB） ----------------
maxmemory ${mm}
maxmemory-policy ${POLICY}
EOF
  fi

  cat <<EOF

# ---------------- 慢查询 / 延迟 ----------------
slowlog-log-slower-than 10000
slowlog-max-len 128
latency-monitor-threshold 100

# ---------------- 主从 ----------------
replica-serve-stale-data yes
replica-read-only yes
replica-priority 100
repl-diskless-sync yes
repl-diskless-sync-delay 5
repl-backlog-size 64mb
EOF

  if [ "$ROLE" = "replica" ]; then
    cat <<EOF
replicaof ${MASTER_HOST} ${MASTER_PORT}
EOF
  fi

  # 并发 I/O 线程：≥4 核才有意义
  if [ "$io" -gt 1 ]; then
    cat <<EOF

# ---------------- I/O 线程（自动推算：${CORES} 核） ----------------
io-threads ${io}
io-threads-do-reads yes
EOF
  fi

  if [ -n "$PASSWORD" ]; then
    cat <<EOF

# ---------------- 认证 ----------------
requirepass ${PASSWORD}
# 切换后本机会变成从库，必须能连上新主库
masterauth ${PASSWORD}
EOF
  fi
}

gen_sentinel_conf() {
  cat <<EOF
# Generated by deploy-node.sh ($(date -u '+%Y-%m-%dT%H:%M:%SZ')) — sentinel host=${HOST_IP}
# 哨兵会自行改写本文件（epoch / 已知哨兵 / 已知从库），请保持可写。

port ${PORT}
bind ${BIND_IP} 127.0.0.1
protected-mode yes
daemonize no
pidfile /run/redis-${PORT}/sentinel.pid
loglevel notice
logfile ${LOG_FILE}
dir ${DATA_DIR}

sentinel monitor ${MASTER_NAME} ${MASTER_HOST} ${MASTER_PORT} ${QUORUM}
sentinel down-after-milliseconds ${MASTER_NAME} 5000
sentinel failover-timeout ${MASTER_NAME} 60000
sentinel parallel-syncs ${MASTER_NAME} 1
EOF
  if [ -n "$ANNOUNCE_IP" ]; then
    cat <<EOF
sentinel announce-ip ${ANNOUNCE_IP}
sentinel announce-port ${PORT}
EOF
  fi
  if [ -n "$PASSWORD" ]; then
    cat <<EOF
# 哨兵自身也要密码：否则 protected-mode 会拒掉来自其它哨兵的（非 loopback）连接，
   三台哨兵互不可见就永远凑不齐 quorum，主库挂了也不会切换。
requirepass ${PASSWORD}
sentinel auth-pass ${MASTER_NAME} ${PASSWORD}
EOF
  fi
}

gen_unit() {
  # gen_unit <redis|sentinel> <conf-path> <描述>
  local kind="$1" conf="$2" desc="$3"
  local exec_line
  if [ "$kind" = "sentinel" ]; then
    exec_line="${BIN_DIR}/redis-server ${conf} --sentinel"
  else
    exec_line="${BIN_DIR}/redis-server ${conf}"
  fi
  cat <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
# systemd 负责创建 /run/redis-<port>（属主为下面的 User），Redis 才有地方写 pidfile
RuntimeDirectory=redis-${PORT}
RuntimeDirectoryMode=0750
ExecStart=${exec_line}
# 用 SIGTERM 停止：Redis 会自行做一次干净退出，避免把密码写进命令行
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=always
RestartSec=3
LimitNOFILE=65535
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
}

# =============================================================
# 落盘 + 启动
# =============================================================
write_file() {
  # write_file <path> <mode> ; 内容从 stdin
  local path="$1" mode="$2" content
  content="$(cat)"
  if [ "$DRY_RUN" = "yes" ]; then
    echo "---------- ${path} (mode ${mode}) ----------"
    printf '%s\n' "$content"
    echo "---------- (dry-run，未写入) ----------"
    return 0
  fi
  if [ -f "$path" ] && [ "$FORCE" != "yes" ]; then
    local bak="${path}.bak-$(date +%Y%m%d%H%M%S)"
    cp -a "$path" "$bak"
    log "已存在 ${path}，备份到 ${bak}"
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
  # 哨兵会改写自己的配置，属主给 redis；其余配置 root:redis 只读即可
  case "$path" in
    */sentinel*.conf) chown "${RUN_USER}:${RUN_USER}" "$path" ;;
    /etc/redis/*.conf) chown "root:${RUN_USER}" "$path" ;;
  esac
}

start_unit() {
  if [ "$DRY_RUN" = "yes" ]; then
    echo "  systemctl daemon-reload && systemctl enable --now ${UNIT_NAME}"
    return 0
  fi
  if [ "$NO_START" = "yes" ]; then
    log "--no-start：已写入配置与单元，未启动"
    return 0
  fi
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || warn "设置开机自启失败，请手动 systemctl enable ${UNIT_NAME}"
  systemctl restart "$UNIT_NAME"
  sleep 1
  if systemctl is-active --quiet "$UNIT_NAME"; then
    log "${UNIT_NAME} 已启动"
  else
    warn "${UNIT_NAME} 未处于运行状态，最近日志："
    journalctl -u "$UNIT_NAME" -n 20 --no-pager 2>/dev/null | sed 's/^/      /' || true
    die "启动失败，请检查 ${LOG_FILE}"
  fi
}

redis_cli_local() {
  # redis_cli_local <port> <args...>
  local port="$1"; shift
  if [ -n "$PASSWORD" ]; then
    "${BIN_DIR}/redis-cli" -h 127.0.0.1 -p "$port" -a "$PASSWORD" --no-auth-warning "$@" 2>/dev/null
  else
    "${BIN_DIR}/redis-cli" -h 127.0.0.1 -p "$port" "$@" 2>/dev/null
  fi
}

verify() {
  [ "$DRY_RUN" = "yes" ] && return 0
  [ "$NO_START" = "yes" ] && return 0

  local i out
  case "$ROLE" in
    master)
      for i in 1 2 3 4 5 6 7 8 9 10; do
        out="$(redis_cli_local "$PORT" ping || true)"
        [ "$out" = "PONG" ] && { log "主库就绪：PONG（端口 ${PORT}）"; break; }
        sleep 1
      done
      [ "$out" = "PONG" ] || die "主库未能响应 PING，检查 ${LOG_FILE}"
      ;;
    replica)
      for i in $(seq 1 30); do
        if [ "$(redis_cli_local "$PORT" info replication | tr -d '\r' | awk -F: '$1=="master_link_status"{print $2}')" = "up" ]; then
          log "从库已与主库同步（master_link_status:up）"
          return 0
        fi
        sleep 1
      done
      redis_cli_local "$PORT" info replication | sed 's/^/      /' || true
      die "从库未在 30s 内完成同步，检查 ${LOG_FILE}（主库地址 ${MASTER_HOST}:${MASTER_PORT}、密码是否一致）"
      ;;
    sentinel)
      for i in $(seq 1 30); do
        if [ -n "$(redis_cli_local "$PORT" sentinel get-master-addr-by-name "$MASTER_NAME" | tr '\n' ' ')" ]; then
          log "哨兵已识别主库：$(redis_cli_local "$PORT" sentinel get-master-addr-by-name "$MASTER_NAME" | tr '\n' ' ')"
          break
        fi
        sleep 1
      done
      ;;
  esac
}

# =============================================================
# 下一步提示
# =============================================================
next_steps() {
  echo
  log "下一步（可直接复制到其它机器执行）："
  case "$ROLE" in
    master)
      echo "  # 从库 x2（在 B、C 机器上执行）"
      echo "  sudo ./deploy-node.sh replica --master-host ${HOST_IP} --master-port ${PORT} --password '${PASSWORD}'"
      echo
      echo "  # 哨兵（A、B、C 三台都执行，三票里两票多数派）"
      echo "  sudo ./deploy-node.sh sentinel --master-host ${HOST_IP} --master-port ${PORT} --password '${PASSWORD}' --quorum 2"
      ;;
    replica)
      echo "  # 哨兵（每台都执行一遍）"
      echo "  sudo ./deploy-node.sh sentinel --master-host ${MASTER_HOST} --master-port ${MASTER_PORT} --password '${PASSWORD}' --quorum 2"
      ;;
    sentinel)
      echo "  # 在任一哨兵上核对拓扑"
      echo "  redis-cli -p ${PORT} sentinel master ${MASTER_NAME}"
      echo "  redis-cli -p ${PORT} sentinel sentinels ${MASTER_NAME}"
      ;;
  esac
  echo
  echo "  客户端请走哨兵发现主库，不要写死 IP；端口放通：数据节点 6379（或本实例端口）、哨兵 26379。"
}

# =============================================================
# status / uninstall
# =============================================================
do_status() {
  [ -x "${BIN_DIR}/redis-cli" ] || die "未找到 ${BIN_DIR}/redis-cli"
  printf '%-22s %-10s %-9s %-8s %s\n' "实例" "端口" "角色" "状态" "备注"
  local conf port role is_sentinel pass args
  for conf in "${REDIS_CONF_DIR}"/redis.conf "${REDIS_CONF_DIR}"/redis-*.conf \
              "${REDIS_CONF_DIR}"/sentinel.conf "${REDIS_CONF_DIR}"/sentinel-*.conf; do
    [ -f "$conf" ] || continue
    port="$(sed -n 's/^[[:space:]]*port[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' "$conf" | head -n 1)"
    [ -n "$port" ] || continue
    # 注意：故障切换后哨兵会让 Redis 执行 CONFIG REWRITE，配置值会被规范化成带引号
    # （requirepass "xxx"），这里必须把引号去掉，否则 redis-cli -a 会 WRONGPASS
    pass="$(sed -n 's/^[[:space:]]*requirepass[[:space:]]\{1,\}//p' "$conf" | head -n 1 | tr -d '"')"
    case "$conf" in
      *sentinel*) is_sentinel="yes" ;;
      *)          is_sentinel="no" ;;
    esac
    args="-h 127.0.0.1 -p ${port}"
    [ -n "$pass" ] && args="${args} -a ${pass} --no-auth-warning" || true
    if "${BIN_DIR}/redis-cli" $args ping >/dev/null 2>&1; then
      if [ "$is_sentinel" = "yes" ]; then
        role="sentinel"
      else
        role="$("${BIN_DIR}/redis-cli" $args info replication 2>/dev/null | tr -d '\r' | awk -F: '$1=="role"{print $2}')"
      fi
      printf '%-22s %-10s %-9s %-8s %s\n' "$(basename "$conf")" "$port" "${role:-?}" "up" \
        "$([ "$role" = "slave" ] && "${BIN_DIR}/redis-cli" $args info replication 2>/dev/null | tr -d '\r' | awk -F: '$1=="master_link_status"{printf "link=%s", $2}' || true)"
    else
      printf '%-22s %-10s %-9s %-8s %s\n' "$(basename "$conf")" "$port" "-" "down" ""
    fi
  done
}

do_uninstall() {
  local units
  units="$(cd "$UNIT_DIR" 2>/dev/null && ls redis.service redis-sentinel.service redis-[0-9]*.service redis-sentinel-[0-9]*.service 2>/dev/null || true)"
  if [ -z "$units" ]; then
    log "未发现本脚本创建的 systemd 单元，无需清理"
    return 0
  fi
  local u
  for u in $units; do
    log "停止并禁用 ${u}"
    systemctl stop "$u" 2>/dev/null || true
    systemctl disable "$u" >/dev/null 2>&1 || true
    if [ "$PURGE" = "yes" ]; then
      rm -f "${UNIT_DIR}/${u}"
    fi
  done
  systemctl daemon-reload

  if [ "$PURGE" = "yes" ]; then
    log "清理配置与数据（--purge）"
    rm -f "${REDIS_CONF_DIR}"/redis.conf "${REDIS_CONF_DIR}"/redis-[0-9]*.conf \
          "${REDIS_CONF_DIR}"/sentinel.conf "${REDIS_CONF_DIR}"/sentinel-[0-9]*.conf
    rm -rf "${BASE_DATA_DIR}" "${BASE_DATA_DIR}"-[0-9]* "${BASE_DATA_DIR}-sentinel"
    log "数据目录与配置已删除（日志目录 ${LOG_DIR} 保留）"
  else
    log "仅停止实例；如需删除配置与数据，请加 --purge"
  fi
}

# =============================================================
# single：单机测试环境（显式声明）
# =============================================================
do_single() {
  local helper="${SCRIPT_DIR}/deploy-sentinel.sh"
  [ -f "$helper" ] || die "单机测试拓扑需要同目录下的 deploy-sentinel.sh（产物包里自带）"
  warn "单机测试布局：这台机器会跑 6 个实例（1 主 2 从 3 哨兵），仅用于验证功能，不是生产拓扑"
  warn "生产请用 master / replica / sentinel 子命令分机器部署"
  local args=(--password "$PASSWORD")
  [ -n "$PKG" ] && args+=(--pkg "$PKG")
  [ "$SINGLE_HOST" = "yes" ] || warn "提示：single 已隐含单机测试声明，无需再加 --single-host"
  exec bash "$helper" "${args[@]}"
}

# =============================================================
# 主流程
# =============================================================
case "$ROLE" in
  status)    do_status ;;
  uninstall) do_uninstall ;;
  single)    do_single ;;
  master|replica|sentinel)
    case "$ROLE" in
      master)   SERVICE_ROLE="Redis master" ;;
      replica)  SERVICE_ROLE="Redis replica" ;;
      sentinel) SERVICE_ROLE="Redis Sentinel" ;;
    esac
    apply_defaults
    preflight
    resolve_paths

    MMM="$(select_maxmemory)"
    echo "=============================================="
    echo " Redis 部署计划（角色 ${ROLE}）"
    echo "  机器内网 IP : ${HOST_IP}"
    echo "  实例端口    : ${PORT}"
    echo "  绑定地址    : ${BIND_IP} + 127.0.0.1"
    echo "  配置/单元   : $([ "$ROLE" = sentinel ] && echo "$SENTINEL_CONF_FILE" || echo "$CONF_FILE") / ${UNIT_NAME}"
    echo "  数据目录    : ${DATA_DIR}"
    echo "  内存 / 核数 : ${MEM_MB}MB / ${CORES} 核"
    echo "  maxmemory   : ${MMM:-未设置}"
    echo "  THP / overcommit : ${THP_STATE:-?} / ${OVERCOMMIT}"
    echo "  句柄上限    : ${ULIMIT_N}"
    echo "  布局        : $([ "$SINGLE_HOST" = yes ] && echo '单机测试（已声明 --single-host）' || echo '生产（一机一实例）')"
    [ "$DRY_RUN" = "yes" ] && echo "  模式        : dry-run（只打印，不落盘）"
    echo "=============================================="

    if [ "$SINGLE_HOST" = "yes" ] && [ "$MEM_MB" -lt 2048 ]; then
      warn "单机测试模式 + 内存不足 2GB：6 个实例可能吃紧，建议 --maxmemory 调小"
    fi

    install_binaries
    ensure_user_dirs

    if [ "$ROLE" = "sentinel" ]; then
      gen_sentinel_conf | write_file "$SENTINEL_CONF_FILE" 0640
      gen_unit sentinel "$SENTINEL_CONF_FILE" "${SERVICE_ROLE} (monitor ${MASTER_NAME} @ ${MASTER_HOST}:${MASTER_PORT})" | write_file "$UNIT_FILE" 0644
    else
      gen_redis_conf | write_file "$CONF_FILE" 0640
      gen_unit redis "$CONF_FILE" "${SERVICE_ROLE} (port ${PORT})" | write_file "$UNIT_FILE" 0644
    fi

    if [ "$DRY_RUN" != "yes" ]; then
      [ "$ROLE" = "sentinel" ] || chown "${RUN_USER}:${RUN_USER}" "$LOG_FILE" 2>/dev/null || true
      touch "$LOG_FILE" 2>/dev/null || true
      chown "${RUN_USER}:${RUN_USER}" "$LOG_FILE" 2>/dev/null || true
      [ "$ROLE" = "sentinel" ] || chown "${RUN_USER}:${RUN_USER}" "$CONF_FILE" 2>/dev/null || true
    fi

    start_unit
    verify

    if [ "$THP_STATE" = "always" ]; then
      warn "透明大页(THP)为 always：建议 echo never > /sys/kernel/mm/transparent_hugepage/enabled，或写入 /etc/rc.local"
    fi
    if [ "$OVERCOMMIT" != "1" ] && [ "$ROLE" != "sentinel" ]; then
      warn "vm.overcommit_memory 不是 1：建议 echo 'vm.overcommit_memory = 1' > /etc/sysctl.d/99-redis.conf && sysctl --system"
    fi

    next_steps
    ;;
  *) die "用法：$0 {master|replica|sentinel|single|status|uninstall} [--help]" ;;
esac
