#!/usr/bin/env bash
# =============================================================================
# redis-docker-build · 一键安装 / 更新脚本（纯离线）
#
# 特点
# ---------------------------------------------------------------------------
#   * 完全离线：不联网、不依赖 curl / wget，适合内网与信创环境
#   * 自动识别：在当前目录（及脚本所在目录）寻找可用的 Redis 二进制包
#       - 已解压的产物目录（含 redis-server + BUILD-INFO.txt）
#       - 产物压缩包 redis-<版本>-<架构>.tar.gz
#   * 版本比对：读取「包内版本」与「本机已安装版本」，自动判断
#       未安装        -> 执行安装
#       包内 > 已安装 -> 执行更新（覆盖，自动备份旧二进制）
#       包内 = 已安装 -> 提示无需更新（同版本不同构建会给出提示）
#       包内 < 已安装 -> 默认拒绝（防止误降级，可用 --force 强制）
#
# 快速开始
# ---------------------------------------------------------------------------
#   # 方式 1：包内直接执行（推荐）
#   tar xzf redis-7.2.16-aarch64.tar.gz
#   cd redis-7.2.16-aarch64
#   sudo ./install.sh
#
#   # 方式 2：脚本与压缩包放在同一目录
#   sudo ./install.sh                      # 自动发现 redis-*.tar.gz
#   sudo ./install.sh --pkg redis-7.2.16-x86_64.tar.gz
#   sudo ./install.sh --from /tmp/redis-7.2.16-x86_64.tar.gz
#
#   # 只想看看会不会装 / 装什么版本
#   ./install.sh --check
#
# 参数
# ---------------------------------------------------------------------------
#   -p, --prefix  <dir>     安装前缀，默认 /usr/local（二进制落在 <prefix>/bin）
#       --pkg     <file>    指定当前目录下的产物压缩包
#       --from    <file>    指定任意路径的产物压缩包（或已解压目录）
#       --dir     <dir>     指定已解压的产物目录
#       --user    <name>    运行用户，默认 redis（--no-user 跳过创建）
#       --port    <n>       冒烟测试端口，默认 16399
#       --force             忽略版本比较，强制重装/覆盖
#       --check             只检测与比对，不做任何改动
#       --no-systemd        不安装/更新 systemd 单元
#       --no-config         不安装 redis.conf（已存在时默认也不覆盖）
#       --no-backup         覆盖前不备份旧二进制（危险）
#       --uninstall         卸载（停服、移除二进制与单元，保留数据）
#   -h, --help              显示本帮助
#
# 兼容：CentOS 7 的 bash 4.2（不使用 bash 4.3+ 特性）
# =============================================================================

set -e

SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BINARIES="redis-server redis-cli redis-benchmark redis-sentinel redis-check-rdb redis-check-aof"

# ── 默认参数 ────────────────────────────────────────────────────────────────
PREFIX="/usr/local"
RUN_USER="redis"
SMOKE_PORT="16399"
WITH_SYSTEMD="yes"
WITH_CONFIG="yes"
WITH_BACKUP="yes"
FORCE="no"
CHECK_ONLY="no"
DO_UNINSTALL="no"
PKG_ARG=""
FROM_ARG=""
DIR_ARG=""

UNIT_DIR="/etc/systemd/system"
CONF_DIR="/etc/redis"
DATA_DIR="/var/lib/redis"
LOG_DIR="/var/log/redis"
PID_DIR="/run/redis"

BIN_DIR="${PREFIX}/bin"

# ── 输出辅助 ────────────────────────────────────────────────────────────────
c_info() { printf '\033[32m[INFO]\033[0m %s\n'  "$*"; }
c_warn() { printf '\033[33m[警告]\033[0m %s\n'  "$*"; }
c_err()  { printf '\033[31m[错误]\033[0m %s\n'  "$*" >&2; }
c_step() { printf '\n\033[36m===> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/,""); print; next }
              else if ($0 ~ /^[[:space:]]*$/) { next }
              else { exit } }' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--prefix)   PREFIX="${2:?--prefix 需要参数}";   BIN_DIR="${PREFIX}/bin"; shift 2 ;;
    --pkg)         PKG_ARG="${2:?--pkg 需要参数}";     shift 2 ;;
    --from)        FROM_ARG="${2:?--from 需要参数}";   shift 2 ;;
    --dir)         DIR_ARG="${2:?--dir 需要参数}";     shift 2 ;;
    --user)        RUN_USER="${2:?--user 需要参数}";   shift 2 ;;
    --no-user)     RUN_USER=""; shift ;;
    --port)        SMOKE_PORT="${2:?--port 需要参数}"; shift 2 ;;
    --force)       FORCE="yes"; shift ;;
    --check)       CHECK_ONLY="yes"; shift ;;
    --no-systemd)  WITH_SYSTEMD="no"; shift ;;
    --no-config)   WITH_CONFIG="no"; shift ;;
    --no-backup)   WITH_BACKUP="no"; shift ;;
    --uninstall)   DO_UNINSTALL="yes"; shift ;;
    -h|--help)     usage ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

# ── 小工具 ──────────────────────────────────────────────────────────────────
need_root() {
  [ "$(id -u)" = "0" ] || die "需要 root 权限（写入 ${BIN_DIR} 与 ${UNIT_DIR}）。请用 sudo 重跑。"
}

# 版本比较：打印 -1 / 0 / 1
cmp_ver() {
  _a="$1"; _b="$2"
  if [ "$_a" = "$_b" ]; then printf '0'; return 0; fi
  _hi="$(printf '%s\n%s\n' "$_a" "$_b" | sort -V | tail -n 1)"
  if [ "$_hi" = "$_a" ]; then printf '1'; else printf '%s' '-1'; fi
}

detect_arch() {
  _m="$(uname -m)"
  case "$_m" in
    x86_64|amd64)  HOST_ARCH="x86_64" ;;
    aarch64|arm64) HOST_ARCH="aarch64" ;;
    *) die "不支持的架构: ${_m}（仅提供 x86_64 / aarch64 产物）" ;;
  esac
}

# 从 BUILD-INFO.txt 提取字段：bi_get <file> <字段名>
bi_get() {
  [ -f "$1" ] || return 1
  sed -n "s/^[[:space:]]*$2[[:space:]]*:[[:space:]]*//p" "$1" | head -n 1 | sed 's/[[:space:]]*$//'
}

# 从 redis-server --version 提取版本号：Redis server v=7.2.16 sha=... build=...
parse_server_version() {
  printf '%s' "$1" | sed -n 's/.*v=\([0-9][0-9.]*\).*/\1/p' | head -n 1
}
parse_server_build() {
  printf '%s' "$1" | sed -n 's/.*build=\([0-9a-fA-F]*\).*/\1/p' | head -n 1
}

# ── 定位产物包 ──────────────────────────────────────────────────────────────
PKG_TARBALL=""
PKG_DIR=""
PKG_VERSION=""
PKG_ARCH=""
PKG_FULLVER=""
PKG_LABEL=""

# 校验一个已解压目录是否是合法产物目录
# 注意：只要求「非空可执行文件」而不要求可执行位——部分文件系统（tar 跨平台解压、
#       FAT/NTFS 挂载）会丢失 exec 位，安装时统一用 install -m 0755 修正。
is_valid_pkgdir() {
  [ -d "$1" ] && [ -s "$1/redis-server" ] && [ -f "$1/BUILD-INFO.txt" ]
}

load_pkgdir() {
  PKG_DIR="$1"
  PKG_VERSION="$(bi_get "${PKG_DIR}/BUILD-INFO.txt" 'Redis version' || true)"
  PKG_ARCH="$(bi_get "${PKG_DIR}/BUILD-INFO.txt" 'Target arch' || true)"
  if [ -z "$PKG_VERSION" ]; then
    PKG_VERSION="$(parse_server_version "$("${PKG_DIR}/redis-server" --version 2>/dev/null || true)")"
  fi
  PKG_LABEL="${PKG_DIR##*/}"
  c_info "发现产物目录: ${PKG_DIR}"
}

# 1) --dir / --from(目录) / 脚本所在目录 / 当前目录下的解压包
find_dir_package() {
  if [ -n "$DIR_ARG" ]; then
    [ -d "$DIR_ARG" ] || die "--dir 指定的目录不存在: ${DIR_ARG}"
    is_valid_pkgdir "$DIR_ARG" || die "--dir 目录不是合法的产物目录（缺少 redis-server 或 BUILD-INFO.txt）"
    load_pkgdir "$(cd "$DIR_ARG" && pwd)"; return 0
  fi
  if [ -n "$FROM_ARG" ] && [ -d "$FROM_ARG" ]; then
    is_valid_pkgdir "$FROM_ARG" || die "--from 目录不是合法的产物目录"
    load_pkgdir "$(cd "$FROM_ARG" && pwd)"; return 0
  fi
  # 脚本自身所在目录就是解压包（最常见：进包内执行）
  if is_valid_pkgdir "$SCRIPT_DIR"; then load_pkgdir "$SCRIPT_DIR"; return 0; fi
  # 当前目录本身
  _cwd="$(pwd)"
  if is_valid_pkgdir "$_cwd"; then load_pkgdir "$_cwd"; return 0; fi
  # 当前目录下的子目录
  _hit=""
  for _d in "$_cwd"/*/; do
    [ -d "$_d" ] || continue
    if is_valid_pkgdir "${_d%/}"; then _hit="${_d%/}"; break; fi
  done
  [ -n "$_hit" ] && { load_pkgdir "$_hit"; return 0; }
  return 1
}

# 2) 压缩包：--pkg / --from / 脚本目录 / 当前目录下的 redis-*.tar.gz
find_tarball_package() {
  _cand=""
  if [ -n "$PKG_ARG" ]; then
    [ -f "$PKG_ARG" ] || [ -f "${SCRIPT_DIR}/${PKG_ARG}" ] || die "--pkg 指定的包不存在: ${PKG_ARG}"
    [ -f "$PKG_ARG" ] && _cand="$PKG_ARG" || _cand="${SCRIPT_DIR}/${PKG_ARG}"
  elif [ -n "$FROM_ARG" ]; then
    [ -f "$FROM_ARG" ] || die "--from 指定的包不存在: ${FROM_ARG}"
    _cand="$FROM_ARG"
  else
    # 优先匹配本机架构，其次任意 redis-*.tar.gz
    for _base in "$SCRIPT_DIR" "$(pwd)"; do
      _m="$(ls -1 "${_base}"/redis-*-"${HOST_ARCH}".tar.gz 2>/dev/null | head -n 1)"
      [ -z "$_m" ] && _m="$(ls -1 "${_base}"/redis-*.tar.gz 2>/dev/null | grep -v -- '-x86_64\|-aarch64' | head -n 1)"
      [ -z "$_m" ] && _m="$(ls -1 "${_base}"/redis-*.tar.gz 2>/dev/null | head -n 1)"
      if [ -n "$_m" ]; then _cand="$_m"; break; fi
    done
  fi
  [ -n "$_cand" ] || return 1
  PKG_TARBALL="$_cand"
  c_info "发现产物压缩包: ${PKG_TARBALL}"
  return 0
}

extract_pkg_tarball() {
  _ex="$(mktemp -d /tmp/redis-pkg.XXXXXX)"
  tar xzf "$PKG_TARBALL" -C "$_ex" || die "解压失败：包可能不完整（${PKG_TARBALL}）"
  _d="$(find "$_ex" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
  [ -n "$_d" ] || die "压缩包结构异常：未找到顶层目录"
  is_valid_pkgdir "$_d" || die "压缩包结构异常：缺少 redis-server 或 BUILD-INFO.txt"
  load_pkgdir "$_d"
}

# 统一入口：优先解压目录，其次压缩包
locate_package() {
  if find_dir_package; then return 0; fi
  if find_tarball_package; then extract_pkg_tarball; return 0; fi
  return 1
}

# ── 已安装版本 ──────────────────────────────────────────────────────────────
CUR_VERSION=""
CUR_BUILD=""
CUR_SERVER=""

detect_installed() {
  CUR_SERVER=""
  for _p in "${BIN_DIR}/redis-server" /usr/bin/redis-server /usr/local/bin/redis-server; do
    [ -x "$_p" ] && { CUR_SERVER="$_p"; break; }
  done
  if [ -z "$CUR_SERVER" ] && command -v redis-server >/dev/null 2>&1; then
    CUR_SERVER="$(command -v redis-server)"
  fi
  if [ -n "$CUR_SERVER" ]; then
    _v="$("$CUR_SERVER" --version 2>/dev/null || true)"
    CUR_VERSION="$(parse_server_version "$_v")"
    CUR_BUILD="$(parse_server_build "$_v")"
  fi
}

# ── 卸载 ────────────────────────────────────────────────────────────────────
do_uninstall() {
  need_root
  c_step "卸载 Redis"
  if [ -f "${UNIT_DIR}/redis.service" ]; then
    systemctl stop redis 2>/dev/null || true
    systemctl disable redis 2>/dev/null || true
    rm -f "${UNIT_DIR}/redis.service"
    systemctl daemon-reload 2>/dev/null || true
    c_info "已移除 systemd 单元"
  fi
  for b in $BINARIES; do
    if [ -e "${BIN_DIR}/${b}" ] || [ -L "${BIN_DIR}/${b}" ]; then
      rm -f "${BIN_DIR}/${b}"; c_info "已移除 ${BIN_DIR}/${b}"
    fi
  done
  for b in redis-server redis-cli redis-benchmark; do
    if [ -L "/usr/bin/${b}" ]; then rm -f "/usr/bin/${b}"; c_info "已移除软链 /usr/bin/${b}"; fi
  done
  c_warn "已保留配置 ${CONF_DIR}、数据 ${DATA_DIR}、日志 ${LOG_DIR}（彻底清理请手动删除）"
  exit 0
}

# ── 安装动作 ────────────────────────────────────────────────────────────────
backup_binaries() {
  _ts="$(date +%Y%m%d%H%M%S)"
  _found="no"
  for b in $BINARIES; do
    if [ -e "${BIN_DIR}/${b}" ] || [ -L "${BIN_DIR}/${b}" ]; then _found="yes"; fi
  done
  [ "$_found" = "yes" ] || { c_info "未发现已安装的二进制，跳过备份"; return 0; }
  BACKUP_DIR="/var/backups/redis-${_ts}"
  mkdir -p "$BACKUP_DIR"
  for b in $BINARIES; do
    if [ -e "${BIN_DIR}/${b}" ] || [ -L "${BIN_DIR}/${b}" ]; then
      cp -a "${BIN_DIR}/${b}" "${BACKUP_DIR}/" 2>/dev/null || true
    fi
  done
  # 记录旧版本，便于回滚核对
  [ -n "${CUR_SERVER}" ] && "$CUR_SERVER" --version > "${BACKUP_DIR}/OLD-VERSION.txt" 2>/dev/null || true
  c_info "旧二进制已备份到: ${BACKUP_DIR}"
}

install_binaries() {
  mkdir -p "$BIN_DIR"
  _n=0
  # 二进制顺序有意义：redis-server 必须最先落地（其余多个是指向它的软链）
  for b in $BINARIES; do
    if [ -L "${PKG_DIR}/${b}" ]; then
      # 保留软链（如 redis-check-aof -> redis-server），避免被展开成多份大文件
      _target="$(readlink "${PKG_DIR}/${b}")"
      ln -sfn "$_target" "${BIN_DIR}/${b}"
      _n=$(( _n + 1 ))
      c_info "创建软链 ${BIN_DIR}/${b} -> ${_target}"
    elif [ -s "${PKG_DIR}/${b}" ]; then
      install -m 0755 "${PKG_DIR}/${b}" "${BIN_DIR}/${b}.new"
      mv -f "${BIN_DIR}/${b}.new" "${BIN_DIR}/${b}"
      _n=$(( _n + 1 ))
      c_info "安装 ${BIN_DIR}/${b}"
    fi
  done
  [ "$_n" -gt 0 ] || die "产物目录中未找到任何可执行文件"
  # 兜底：若包内自带的软链目标缺失（异常包），用 redis-server 补齐
  for b in redis-sentinel redis-check-rdb redis-check-aof; do
    if [ -L "${BIN_DIR}/${b}" ] && [ ! -e "${BIN_DIR}/${b}" ]; then
      ln -sfn redis-server "${BIN_DIR}/${b}"
      c_warn "软链 ${b} 目标缺失，已重置为 -> redis-server"
    fi
  done
  # 兼容 /usr/bin 优先的 PATH：补软链，保证 redis-cli 可直接调用
  if [ "$BIN_DIR" != "/usr/bin" ] && [ -d /usr/bin ]; then
    for b in redis-server redis-cli redis-benchmark; do
      if [ ! -e "/usr/bin/${b}" ] && [ -e "${BIN_DIR}/${b}" ]; then
        ln -sf "${BIN_DIR}/${b}" "/usr/bin/${b}"
        c_info "创建软链 /usr/bin/${b}"
      fi
    done
  fi
}

install_config() {
  [ "$WITH_CONFIG" = "yes" ] || { c_info "--no-config，跳过配置文件"; return 0; }
  mkdir -p "$CONF_DIR"
  if [ -f "${CONF_DIR}/redis.conf" ]; then
    c_info "配置已存在，保留不覆盖: ${CONF_DIR}/redis.conf"
  elif [ -f "${PKG_DIR}/redis.conf" ]; then
    install -m 0640 "${PKG_DIR}/redis.conf" "${CONF_DIR}/redis.conf"
    c_info "安装配置 ${CONF_DIR}/redis.conf"
  elif [ -f "${PKG_DIR}/redis.conf.default" ]; then
    install -m 0640 "${PKG_DIR}/redis.conf.default" "${CONF_DIR}/redis.conf"
    c_info "安装配置 ${CONF_DIR}/redis.conf（来自 redis.conf.default）"
  else
    c_warn "包内未找到 redis.conf，跳过"
  fi
  # 留存本次安装的构建信息，便于日后核对
  [ -f "${PKG_DIR}/BUILD-INFO.txt" ] && install -m 0644 "${PKG_DIR}/BUILD-INFO.txt" "${CONF_DIR}/BUILD-INFO.txt" || true
}

create_user_and_dirs() {
  mkdir -p "$DATA_DIR" "$LOG_DIR" "$PID_DIR"
  if [ -n "$RUN_USER" ]; then
    if id "$RUN_USER" >/dev/null 2>&1; then
      c_info "运行用户已存在: ${RUN_USER}"
    elif command -v useradd >/dev/null 2>&1; then
      if useradd -r -s /sbin/nologin -d "$DATA_DIR" -c "Redis Server" "$RUN_USER" 2>/dev/null; then
        c_info "已创建系统用户 ${RUN_USER}"
      else
        c_warn "创建用户 ${RUN_USER} 失败，将沿用现有归属"
      fi
    fi
  fi
  if [ -n "$RUN_USER" ] && id "$RUN_USER" >/dev/null 2>&1; then
    chown -R "${RUN_USER}:${RUN_USER}" "$DATA_DIR" "$LOG_DIR" 2>/dev/null || true
    [ -d "$CONF_DIR" ] && chown -R "${RUN_USER}:${RUN_USER}" "$CONF_DIR" 2>/dev/null || true
  fi
}

install_systemd() {
  [ "$WITH_SYSTEMD" = "yes" ] || { c_info "--no-systemd，跳过 systemd 单元"; return 0; }
  command -v systemctl >/dev/null 2>&1 || { c_warn "未检测到 systemctl，跳过 systemd 单元"; return 0; }
  [ -f "${PKG_DIR}/redis.service" ] || { c_warn "包内未找到 redis.service，跳过"; return 0; }
  _was_active="no"
  systemctl is-active redis >/dev/null 2>&1 && _was_active="yes"
  install -m 0644 "${PKG_DIR}/redis.service" "${UNIT_DIR}/redis.service"
  systemctl daemon-reload 2>/dev/null || true
  c_info "安装 systemd 单元 ${UNIT_DIR}/redis.service"
  systemctl enable redis >/dev/null 2>&1 && c_info "已设置开机自启" || c_warn "设置开机自启失败，请手动 systemctl enable redis"
  # 若更新前服务在运行，尝试拉起以完成更新生效
  if [ "$_was_active" = "yes" ]; then
    if systemctl restart redis >/dev/null 2>&1; then
      c_info "服务已重启，更新生效"
    else
      c_warn "服务重启失败，请检查: systemctl status redis"
    fi
  fi
}

smoke_test() {
  c_step "冒烟测试（临时端口 ${SMOKE_PORT}）"
  _log="$(mktemp /tmp/redis-smoke.XXXXXX.log)"
  _start="${BIN_DIR}/redis-server"
  [ -x "$_start" ] || _start="/usr/bin/redis-server"
  # aarch64 + 内核 THP=always 时需忽略 ARM64-COW-BUG（Redis 的防数据损坏自保护）
  if ! "$_start" --port "$SMOKE_PORT" --save '' --appendonly no --daemonize yes \
        --logfile "$_log" --dir /tmp >/dev/null 2>&1; then
    c_warn "首次启动未成功，追加 --ignore-warnings ARM64-COW-BUG 重试"
    "$_start" --port "$SMOKE_PORT" --save '' --appendonly no --daemonize yes \
      --logfile "$_log" --dir /tmp --ignore-warnings ARM64-COW-BUG >/dev/null 2>&1 || true
  fi
  _cli="${BIN_DIR}/redis-cli"; [ -x "$_cli" ] || _cli="/usr/bin/redis-cli"
  _ok="no"; _i=1
  while [ "$_i" -le 8 ]; do
    if _pong="$("$_cli" -p "$SMOKE_PORT" ping 2>/dev/null)" && [ "$_pong" = "PONG" ]; then
      _ok="yes"; break
    fi
    sleep 1; _i=$(( _i + 1 ))
  done
  "$_cli" -p "$SMOKE_PORT" shutdown nosave >/dev/null 2>&1 || true
  if [ "$_ok" = "yes" ]; then
    c_info "冒烟测试通过（PING -> PONG）"
    return 0
  fi
  c_warn "冒烟测试未通过。构建日志片段："
  sed -n '1,20p' "$_log" 2>/dev/null || true
  c_warn "常见原因：内核 THP=always（Redis 对 aarch64 的 ARM64-COW-BUG 保护），详见 README"
  return 1
}

# ── 计划展示 ────────────────────────────────────────────────────────────────
ACTION=""

show_plan() {
  c_step "安装计划"
  printf '  产物包      : %s\n' "${PKG_LABEL}"
  printf '  包内版本    : %s（架构 %s）\n' "${PKG_VERSION:-未知}" "${PKG_ARCH:-未知}"
  printf '  包内构建号  : %s\n' "$(parse_server_build "$("${PKG_DIR}/redis-server" --version 2>/dev/null || true)" || true)"
  if [ -n "$CUR_VERSION" ]; then
    printf '  已安装版本  : %s（%s）\n' "$CUR_VERSION" "${CUR_SERVER}"
    printf '  已安装构建号: %s\n' "${CUR_BUILD:-未知}"
  else
    printf '  已安装版本  : 无（未检测到 redis-server）\n'
  fi
  printf '  安装目录    : %s\n' "$BIN_DIR"
  printf '  运行用户    : %s\n' "${RUN_USER:-（跳过）}"
  printf '  动作        : %s\n' "$ACTION_LABEL"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
main() {
  echo "=============================================================="
  echo " redis-docker-build 一键安装/更新（离线）  v${SCRIPT_VERSION}"
  echo "=============================================================="

  if [ "$DO_UNINSTALL" = "yes" ]; then do_uninstall; fi

  detect_arch
  c_info "本机架构: $(uname -m)  ->  ${HOST_ARCH}"

  c_step "识别产物包"
  if ! locate_package; then
    c_err "当前目录未发现可用的 Redis 产物包。"
    echo
    echo "请确认下列任一条件成立后重试："
    echo "  1) 已解压产物目录（含 redis-server 与 BUILD-INFO.txt），在其内部执行本脚本"
    echo "  2) 当前目录 / 脚本目录下存在 redis-<版本>-<架构>.tar.gz"
    echo "  3) 用 --from <路径> 或 --dir <目录> 显式指定"
    exit 1
  fi
  c_info "包内详细版本: $(sed -n '1p' "${PKG_DIR}/BUILD-INFO.txt" 2>/dev/null || echo '未知')"

  # 架构校验：防止把 x86_64 包装到 aarch64 机器（或反之）
  if [ -n "$PKG_ARCH" ] && [ "$PKG_ARCH" != "$HOST_ARCH" ]; then
    if [ "$FORCE" = "yes" ]; then
      c_warn "包架构 ${PKG_ARCH} 与本机 ${HOST_ARCH} 不一致，但 --force 已指定，继续"
    else
      die "包架构(${PKG_ARCH}) 与本机(${HOST_ARCH}) 不匹配。请使用 ${HOST_ARCH} 产物，或用 --force 强制。"
    fi
  fi

  detect_installed

  # 版本比对，决定动作
  ACTION_VERB="安装"
  if [ -z "$CUR_VERSION" ]; then
    ACTION="install"; ACTION_LABEL="全新安装"
  else
    _c="$(cmp_ver "$PKG_VERSION" "$CUR_VERSION")"
    case "$_c" in
      1)  ACTION="update";  ACTION_LABEL="更新（${CUR_VERSION} -> ${PKG_VERSION}）"; ACTION_VERB="更新" ;;
      0)
        _pb="$(parse_server_build "$("${PKG_DIR}/redis-server" --version 2>/dev/null || true)" || true)"
        if [ -n "$CUR_BUILD" ] && [ -n "$_pb" ] && [ "$CUR_BUILD" != "$_pb" ]; then
          ACTION="same"; ACTION_LABEL="同版本不同构建（build ${CUR_BUILD} -> ${_pb}），未指定 --force 时跳过"
        else
          ACTION="same"; ACTION_LABEL="已是最新版本，无需更新"
        fi
        ;;
      -1) ACTION="downgrade"; ACTION_LABEL="降级（${CUR_VERSION} -> ${PKG_VERSION}），默认拒绝"; ACTION_VERB="降级安装" ;;
    esac
  fi

  if [ "$FORCE" = "yes" ]; then
    case "$ACTION" in
      same)      ACTION_LABEL="强制重装（--force，包内 ${PKG_VERSION}）"; ACTION_VERB="重装" ;;
      downgrade) ACTION_LABEL="降级（${CUR_VERSION} -> ${PKG_VERSION}）（--force 已放行）" ;;
      *)         ACTION_LABEL="${ACTION_LABEL}（--force）" ;;
    esac
  fi

  show_plan

  # --check：到此为止
  if [ "$CHECK_ONLY" = "yes" ]; then
    c_step "仅检测模式（--check），未做任何改动"
    exit 0
  fi

  # 版本门禁
  case "$ACTION" in
    same)
      if [ "$FORCE" != "yes" ]; then
        c_step "无需操作"
        c_info "本机已是 ${CUR_VERSION}，包内也是 ${PKG_VERSION}。"
        c_info "如需强制覆盖，请加 --force。"
        exit 0
      fi
      ;;
    downgrade)
      if [ "$FORCE" != "yes" ]; then
        c_err "包内版本 ${PKG_VERSION} 低于已安装版本 ${CUR_VERSION}，默认拒绝降级。"
        c_err "如确需降级，请加 --force 重跑（务必先备份数据）。"
        exit 1
      fi
      ;;
  esac

  need_root

  c_step "开始${ACTION_VERB}"
  if [ "$WITH_BACKUP" = "yes" ]; then backup_binaries; else c_warn "--no-backup，跳过备份"; fi
  install_binaries
  create_user_and_dirs
  install_config
  install_systemd

  if smoke_test; then
    :
  else
    c_warn "冒烟测试未通过 —— 二进制已完成${ACTION_VERB}，但请先排查原因再投入生产"
    SMOKE_WARN="yes"
  fi

  c_step "完成"
  [ "${SMOKE_WARN:-no}" = "yes" ] && c_warn "注意：冒烟测试未通过，见上方日志"
  "${BIN_DIR}/redis-server" --version
  echo
  printf '  二进制目录 : %s\n' "$BIN_DIR"
  printf '  配置文件   : %s/redis.conf\n' "$CONF_DIR"
  printf '  数据/日志  : %s , %s\n' "$DATA_DIR" "$LOG_DIR"
  [ "$WITH_SYSTEMD" = "yes" ] && printf '  systemd    : systemctl {start|stop|status|restart} redis\n'
  echo
  echo "  下一步："
  if [ "$WITH_SYSTEMD" = "yes" ]; then
    echo "    systemctl start redis && systemctl status redis"
  else
    echo "    redis-server ${CONF_DIR}/redis.conf --daemonize yes"
  fi
  echo "    redis-cli ping      # 期望输出 PONG"
  echo
  echo "  安全提示：${CONF_DIR}/redis.conf 默认仅监听 127.0.0.1；"
  echo "            如需对外服务，请先设置 requirepass 并限制 bind 与防火墙。"
  echo
}

main
