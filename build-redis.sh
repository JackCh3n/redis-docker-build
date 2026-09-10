#!/usr/bin/env bash
# =============================================================
# build-redis.sh — 容器内 / 目标机 Redis 参数化构建脚本（核心）
#
# 既可在 Docker 容器内运行（由 Dockerfile ENTRYPOINT 调用），
# 也可在任意具备编译环境的 Linux 上直接运行。
#
# 用法示例：
#   docker run --rm -v /opt/redis-dist:/opt/dist redis-builder:7.6 \
#     --redis-version 8.10.1
#
#   docker run --rm -v /opt/redis-dist:/opt/dist redis-builder:7.6 \
#     --redis-version 8.10.1 --malloc jemalloc --tls yes --smoke yes
#
# 参数（均可换成同名环境变量，命令行优先级更高）：
#   --redis-version  Redis 版本号            (默认 8.10.1)
#   --prefix         安装前缀 make install PREFIX= (默认 /usr/local)
#   --output         产物输出目录            (默认 /opt/dist)
#   --malloc         内存分配器 auto|jemalloc|libc (默认 auto)
#   --tls            是否编译 TLS 支持 yes|no   (默认 no，需 openssl-devel)
#   --systemd        是否编译 systemd 支持 yes|no (默认 no，需 systemd-devel)
#   --modules        是否编译 8.x bundled modules yes|no（默认 no）
#                    仅 8.0~8.8 生效（传 BUILD_WITH_MODULES=yes，需 Rust 与网络）；
#                    Redis >= 8.10 的模块（Query Engine / vector-sets 等）需要
#                    LLVM 21 + Rust 1.94 + CMake 3.25~3.31.6，本工程面向
#                    glibc 2.17（CentOS 7.6 / 麒麟 V10 SP3）无法满足，
#                    因此 >= 8.10 传 yes 会直接报错退出，详见「构建体系判定」。
#   --lg-page        jemalloc 最大页大小 log2，aarch64 默认 16（支持 64KB 页）
#   --prog-suffix    程序名后缀（PROG_SUFFIX），默认空
#   --jobs           编译并行数              (默认 nproc)
#   --source-url     覆盖源码下载地址（内网离线镜像用）
#   --smoke          构建后是否做 PONG 冒烟测试 yes|no (默认 yes)
#
# 关于内存分配器与 ARM 大页（重要）
# ------------------------------------------
# jemalloc 会把「构建机的页大小」作为支持的页大小上限写死进二进制。
# ARM64 服务器常见 64KB 页（getconf PAGESIZE = 65536），若在 4KB 页机器上
# 编译，运行时会报 "<jemalloc>: unsupported system page size" 而启动失败。
# 处理方式：
#   * Redis >= 7.0：传 JEMALLOC_CONFIGURE_OPTS="--with-lg-page=16"（本脚本自动，
#     aarch64 默认 16），jemalloc 即同时支持 4KB / 64KB 页。
#   * Redis < 7.0 ：该变量不存在，aarch64 上默认改用 libc 分配器（安全优先）。
#   * 仍不放心可显式 --malloc libc，彻底规避页大小问题（碎片率略高）。
#
# 关于 Redis >= 8.10 的构建体系（重要）
# ------------------------------------------
# Redis 8.10 起顶层 Makefile 被重写，默认目标 build 会编译 modules/*/src 下
# **所有已存在的模块**；而官方源码包已随附 redisearch(Query Engine) / redisjson /
# redistimeseries / redisbloom / vector-sets 源码，于是「裸跑 make」会连带触发
# 这些模块的编译，需要 LLVM 21 + Rust 1.94 + CMake 3.25~3.31.6。
# 本工程刻意把 ABI 下限压在 glibc 2.17（CentOS 7.6 / 麒麟 V10 SP3），上述工具链
# 在该环境无法满足，因此 >= 8.10 固定「仅编译核心」：`make build redis`。
# 产物 = 完整核心（KV / 持久化 / 主从 / Cluster / Sentinel / TLS / 脚本），
# 不含 JSON / Search / TimeSeries / 概率结构 / vector-sets 等 bundled modules。
#
# 关于许可证（合规提示）
# ------------------------------------------
# Redis 7.2.x 及更早：BSD-3-Clause。
# Redis 7.4.x~7.8.x：RSALv2 或 SSPLv1（二选一，非 OSI 开源）。
# Redis 8.0.x 及以后：RSALv2 / SSPLv1 / AGPLv3（三选一，AGPLv3 为 OSI 认可开源）。
# 分发二进制时**必须随包附带上游许可证全文**，本脚本会自动把源码包内的
# LICENSE.txt（8.x）或 COPYING（7.x）复制为产物目录下的 LICENSE.redis.txt。
# =============================================================
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-8.10.1}"
PREFIX="${REDIS_PREFIX:-/usr/local}"
OUTPUT="${OUTPUT_DIR:-/opt/dist}"
MALLOC="${REDIS_MALLOC:-auto}"
TLS="${REDIS_TLS:-no}"
SYSTEMD="${REDIS_SYSTEMD:-no}"
MODULES="${REDIS_MODULES:-no}"
LG_PAGE="${REDIS_LG_PAGE:-}"
PROG_SUFFIX="${REDIS_PROG_SUFFIX:-}"
SOURCE_URL="${REDIS_SOURCE_URL:-}"
SMOKE="${REDIS_SMOKE:-yes}"

# bash 4.2 (CentOS 7) 在 set -u 下，${VAR:-$(cmd)} 会误报 unbound variable，故拆开
JOBS="${REDIS_JOBS-}"
if [ -z "$JOBS" ]; then
  JOBS="$(nproc 2>/dev/null || echo 1)"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --redis-version) REDIS_VERSION="$2"; shift 2 ;;
    --prefix)        PREFIX="$2";        shift 2 ;;
    --output)        OUTPUT="$2";        shift 2 ;;
    --malloc)        MALLOC="$2";        shift 2 ;;
    --tls)           TLS="$2";           shift 2 ;;
    --systemd)       SYSTEMD="$2";       shift 2 ;;
    --modules)       MODULES="$2";       shift 2 ;;
    --lg-page)       LG_PAGE="$2";       shift 2 ;;
    --prog-suffix)   PROG_SUFFIX="$2";   shift 2 ;;
    --jobs)          JOBS="$2";          shift 2 ;;
    --source-url)    SOURCE_URL="$2";    shift 2 ;;
    --smoke)         SMOKE="$2";         shift 2 ;;
    *) echo "[ERROR] 未知参数: $1" >&2; exit 1 ;;
  esac
done

# ---------- 基础信息探测 ----------
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)   ARCH="x86_64" ;;
  aarch64|arm64)  ARCH="aarch64" ;;
  *)              ARCH="$ARCH_RAW" ;;
esac

# 版本比较：ver_ge A B -> A >= B 时返回 0
ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

LIB_PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo unknown)"
GCC_VER="$( (gcc -dumpfullversion -dumpversion 2>/dev/null || gcc --version 2>/dev/null | head -1) | head -1)"

echo "=============================================="
echo " Redis 构建配置"
echo "  redis 版本    : ${REDIS_VERSION}"
echo "  目标架构      : ${ARCH} (构建机: ${ARCH_RAW})"
echo "  安装前缀      : ${PREFIX}"
echo "  产物目录      : ${OUTPUT}"
echo "  内存分配器    : ${MALLOC}"
echo "  TLS / systemd : ${TLS} / ${SYSTEMD}"
echo "  内置模块      : ${MODULES}"
echo "  编译并行数    : ${JOBS}"
echo "  编译器        : ${GCC_VER}"
echo "  构建机页大小  : ${LIB_PAGE_SIZE}"
echo "=============================================="

# ---------- 编译器版本前置校验 ----------
# Redis >= 6.0 需要 C11 原子操作（stdatomic），GCC 必须 >= 4.9（建议 >= 5.3）
if ver_ge "$REDIS_VERSION" "6.0.0"; then
  GCC_NUM="$(echo "$GCC_VER" | grep -oE '^[0-9]+\.[0-9]+' || echo 0.0)"
  if [ "$(printf '%s\n%s\n' "5.1" "$GCC_NUM" | sort -V | head -n 1)" != "5.1" ]; then
    echo "[ERROR] Redis ${REDIS_VERSION} 需要 C11（stdatomic），GCC 需 >= 5.1，当前为 ${GCC_VER}" >&2
    echo "        提示：CentOS 7 请启用 devtoolset，例如 scl enable devtoolset-10 bash" >&2
    exit 1
  fi
fi

# ---------- 构建体系判定（Redis >= 8.10 顶层 Makefile 重写） ----------
# 见文件头「关于 Redis >= 8.10 的构建体系」。
NEW_BUILD_SYS=no
if ver_ge "$REDIS_VERSION" "8.10.0"; then
  NEW_BUILD_SYS=yes
  if [ "$MODULES" = "yes" ]; then
    echo "[ERROR] 无法构建 Redis ${REDIS_VERSION} 的 bundled modules。" >&2
    echo "        原因：Redis >= 8.10 的模块（RediSearch/Query Engine、vector-sets 等）需要" >&2
    echo "              LLVM 21 + Rust 1.94 + CMake 3.25~3.31.6；而本工程编译环境刻意压在" >&2
    echo "              glibc 2.17（CentOS 7.6 / 银河麒麟 V10 SP3）以保证产物兼容性。" >&2
    echo "        做法：去掉 --modules 即可（构建完整核心：KV/持久化/主从/Cluster/Sentinel/TLS）。" >&2
    echo "              若确需 JSON/Search/TimeSeries 等，请在更高 glibc 基线的系统上自行源码编译。" >&2
    exit 1
  fi
  echo ">>> [策略] Redis >= 8.10：强制仅编译核心（make build redis），跳过 bundled modules"
fi

# ---------- 分配器与页大小推导 ----------
if [ "$MALLOC" = "auto" ]; then
  if [ "$ARCH" = "aarch64" ] && ! ver_ge "$REDIS_VERSION" "7.0.0"; then
    # Redis < 7.0 不支持 JEMALLOC_CONFIGURE_OPTS，ARM 上无法安全适配 64KB 页
    MALLOC="libc"
    echo ">>> [auto] aarch64 + Redis < 7.0：为避免 64KB 大页崩溃，改用 libc 分配器"
  else
    MALLOC="jemalloc"
  fi
fi
case "$MALLOC" in
  jemalloc|libc) ;;
  *) echo "[ERROR] --malloc 只能是 auto / jemalloc / libc" >&2; exit 1 ;;
esac

JEMALLOC_OPTS=""
if [ "$MALLOC" = "jemalloc" ]; then
  if [ -z "$LG_PAGE" ]; then
    if [ "$ARCH" = "aarch64" ]; then LG_PAGE=16; else LG_PAGE=12; fi
  fi
  # JEMALLOC_CONFIGURE_OPTS 自 Redis 7.0 起支持
  if ver_ge "$REDIS_VERSION" "7.0.0"; then
    JEMALLOC_OPTS="--with-lg-page=${LG_PAGE}"
  else
    echo ">>> 注意：Redis ${REDIS_VERSION} 不支持 --with-lg-page，jemalloc 按构建机页大小编译"
  fi
fi

# ---------- 下载源码 ----------
mkdir -p "$OUTPUT" /opt/src 2>/dev/null || true
cd /opt/src
SRC_DIR="redis-${REDIS_VERSION}"

if [ ! -f "${SRC_DIR}.tar.gz" ]; then
  echo ">>> 下载 Redis ${REDIS_VERSION} 源码"
  URLS=()
  [ -n "$SOURCE_URL" ] && URLS+=("$SOURCE_URL")
  URLS+=("https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz")
  URLS+=("https://codeload.github.com/redis/redis/tar.gz/refs/tags/${REDIS_VERSION}")
  ok=0
  for u in "${URLS[@]}"; do
    echo "    - 尝试 ${u}"
    if wget -q -T 300 -O "${SRC_DIR}.tar.gz" "$u"; then ok=1; break; fi
  done
  if [ "$ok" != "1" ]; then
    echo "[ERROR] Redis ${REDIS_VERSION} 源码下载失败，请检查网络或用 --source-url 指定内网镜像" >&2
    exit 1
  fi
fi

rm -rf "$SRC_DIR"
tar xzf "${SRC_DIR}.tar.gz"
# GitHub 归档解压出的目录名可能不同，做一次归一化
if [ ! -d "$SRC_DIR" ]; then
  EXTRACTED="$(find . -maxdepth 1 -type d -name 'redis-*' | head -n 1)"
  [ -n "$EXTRACTED" ] && mv "$EXTRACTED" "$SRC_DIR"
fi
[ -d "$SRC_DIR" ] || { echo "[ERROR] 源码解压目录未找到" >&2; exit 1; }
cd "$SRC_DIR"

# ---------- 组装 make 参数 ----------
MAKE_FLAGS=("MALLOC=${MALLOC}")
if [ "$TLS" = "yes" ]; then
  if ver_ge "$REDIS_VERSION" "6.0.0"; then
    MAKE_FLAGS+=("BUILD_TLS=yes")
  else
    echo ">>> 注意：Redis ${REDIS_VERSION} 不支持 BUILD_TLS（TLS 自 6.0 引入），已忽略"
  fi
fi
[ "$SYSTEMD" = "yes" ] && MAKE_FLAGS+=("USE_SYSTEMD=yes")
[ "$MODULES" = "yes" ] && MAKE_FLAGS+=("BUILD_WITH_MODULES=yes")
[ -n "$PROG_SUFFIX" ]  && MAKE_FLAGS+=("PROG_SUFFIX=${PROG_SUFFIX}")

# Python 防护（Redis 8.x）
# src/Makefile 会在 PYTHON 可用时尝试用 python3 重新生成 commands.def / fmtargs.h。
# CentOS 7 系统 python 是 python2，而生成脚本是 python3 语法；一旦 make 判定这两个
# 文件「需要重建」就会用 python2 运行并失败。源码包已随附预生成的 commands.def 与
# fmtargs.h，因此这里在「没有 python3」时显式置空 PYTHON，让 make 直接使用随包文件。
if [ "$NEW_BUILD_SYS" = "yes" ] && ! command -v python3 >/dev/null 2>&1; then
  MAKE_FLAGS+=("PYTHON=")
  echo ">>> [防护] 未检测到 python3：置 PYTHON= 以使用源码包内预生成的 commands.def"
fi

# Redis >= 8.10 必须显式给出 `build redis` 目标才会「只编译核心」；
# 更早版本裸跑 make 即为核心，无需额外目标。
MAKE_GOALS=""
[ "$NEW_BUILD_SYS" = "yes" ] && MAKE_GOALS="build redis"

# ---------- 编译 ----------
echo ">>> make distclean"
make distclean >/dev/null 2>&1 || true

echo ">>> make -j${JOBS} ${MAKE_GOALS} ${MAKE_FLAGS[*]}"
if [ -n "$JEMALLOC_OPTS" ]; then
  echo ">>> JEMALLOC_CONFIGURE_OPTS=${JEMALLOC_OPTS}"
  # shellcheck disable=SC2086
  env JEMALLOC_CONFIGURE_OPTS="$JEMALLOC_OPTS" make -j"$JOBS" $MAKE_GOALS "${MAKE_FLAGS[@]}"
else
  # shellcheck disable=SC2086
  make -j"$JOBS" $MAKE_GOALS "${MAKE_FLAGS[@]}"
fi

echo ">>> make install PREFIX=${PREFIX}"
make install PREFIX="$PREFIX"

# ---------- 收集产物 ----------
OUTDIR="${OUTPUT}/redis-${REDIS_VERSION}-${ARCH}"
mkdir -p "$OUTDIR"

BIN_DIR="${PREFIX}/bin"
[ -d "$BIN_DIR" ] || BIN_DIR="${PREFIX}/sbin"
[ -d "$BIN_DIR" ] || { echo "[ERROR] 未找到安装后的可执行文件目录（${PREFIX}/bin）" >&2; exit 1; }

for f in redis-server redis-cli redis-benchmark redis-sentinel redis-check-rdb redis-check-aof; do
  if [ -e "${BIN_DIR}/${f}" ]; then
    cp -a "${BIN_DIR}/${f}" "${OUTDIR}/${f}"
  elif [ -e "${SRC_DIR}/src/${f}" ]; then
    cp -a "${SRC_DIR}/src/${f}" "${OUTDIR}/${f}"
  fi
done

# 附带一份默认配置文件，便于对照线上 redis.conf
# 注意：Redis 8.10 起源码包内的 redis.conf 权限是 0600（owner-only，root 所有）。
#       若用 cp -a 原样带入，产物目录会残留一个「仅 owner 可读」的文件；此时非 root 的
#       打包者（如 GitHub Actions 的 runner 用户）或解包用户执行 tar 会直接
#       "Permission denied"（GNU tar 退出码 2，配合 set -e 即整体失败）。
#       这里显式归一化为 0644，保证产物对任意用户可读。
if [ -f "redis.conf" ]; then
  cp -f redis.conf "${OUTDIR}/redis.conf.default"
  chmod 0644 "${OUTDIR}/redis.conf.default"
fi

# ---------- 附带上游许可证（分发必需） ----------
# Redis 8.x 为 RSALv2/SSPLv1/AGPLv3 三选一；7.4~7.8 为 RSALv2/SSPLv1；<=7.2 为 BSD-3-Clause。
# 无论选择哪一种，分发二进制时都必须携带上游许可证原文，否则违反「不得移除许可声明」条款。
LIC_FILE=""
for _lic in LICENSE.txt COPYING LICENSE; do
  if [ -f "$_lic" ]; then
    cp -a "$_lic" "${OUTDIR}/LICENSE.redis.txt"
    LIC_FILE="$_lic"
    break
  fi
done
# 供 BUILD-INFO.txt 使用的许可名称（按版本区间）
if ver_ge "$REDIS_VERSION" "8.0.0"; then
  LIC_NAME="RSALv2 / SSPLv1 / AGPLv3 (tri-license, at your option)"
elif ver_ge "$REDIS_VERSION" "7.4.0"; then
  LIC_NAME="RSALv2 / SSPLv1 (dual-license, at your option)"
else
  LIC_NAME="BSD-3-Clause"
fi
if [ -n "$LIC_FILE" ]; then
  echo ">>> 已附带上游许可证: ${LIC_FILE} -> LICENSE.redis.txt"
else
  echo ">>> 警告：源码包内未找到上游许可证文件，产物将缺少许可证原文" >&2
fi

# ---------- 记录构建信息 ----------
{
  echo "Redis version    : ${REDIS_VERSION}"
  echo "Target arch      : ${ARCH}"
  echo "Built on         : $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}") || echo unknown ) ($(uname -r))"
  echo "Allocator        : ${MALLOC}${JEMALLOC_OPTS:+ (JEMALLOC_CONFIGURE_OPTS=\"${JEMALLOC_OPTS}\")}"
  echo "TLS / systemd    : ${TLS} / ${SYSTEMD}"
  echo "Bundled modules  : ${MODULES}"
  echo "Build system     : $([ "$NEW_BUILD_SYS" = "yes" ] && echo "top-level Makefile (>=8.10, goal: build redis / core-only)" || echo "legacy src/Makefile")"
  echo "License (upstream): ${LIC_NAME}"
  echo "License file     : LICENSE.redis.txt"
  echo "Compiler         : ${GCC_VER}"
  echo "Build host page  : ${LIB_PAGE_SIZE}"
  echo "Built at         : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "--- redis-server --version ---"
  "${OUTDIR}/redis-server" --version 2>&1 || true
  echo
  echo "--- glibc requirement (max GLIBC_ version) ---"
  if command -v objdump >/dev/null 2>&1; then
    objdump -T "${OUTDIR}/redis-server" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -1 || true
  fi
  echo
  echo "--- ldd ---"
  if command -v ldd >/dev/null 2>&1; then
    ldd "${OUTDIR}/redis-server" 2>&1 || true
  fi
} > "${OUTDIR}/BUILD-INFO.txt" 2>&1

# ---------- 冒烟测试（PONG）----------
if [ "$SMOKE" = "yes" ]; then
  echo ">>> 冒烟测试：启动实例并 PING"
  PORT="${SMOKE_PORT:-16399}"
  TMPDIR_S="$(mktemp -d)"
  smoke_ok=no
  smoke_note=""

  # 说明：aarch64 上若构建机内核 THP 为 always，Redis 会因 ARM64 写时复制缺陷检查
  #       而「主动退出」（日志含 ARM64-COW-BUG）。这是构建机内核设置，不是产物缺陷，
  #       因此冒烟测试显式加上 --ignore-warnings ARM64-COW-BUG；
  #       若目标版本不支持该参数（Redis 5.x 无此检查），则回退为不带参数重试。
  try_smoke() {
    local extra="$1" round="$2"
    local log="${TMPDIR_S}/redis-${round}.log"
    rm -f "${TMPDIR_S}/redis.pid"
    # shellcheck disable=SC2086
    "${OUTDIR}/redis-server" --port "$PORT" --save '' --appendonly no \
      --daemonize yes --pidfile "${TMPDIR_S}/redis.pid" \
      --logfile "$log" --dir "$TMPDIR_S" $extra >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8; do
      sleep 1
      if [ "$("${OUTDIR}/redis-cli" -p "$PORT" ping 2>/dev/null || true)" = "PONG" ]; then
        "${OUTDIR}/redis-cli" -p "$PORT" shutdown nosave >/dev/null 2>&1 || true
        return 0
      fi
    done
    [ -f "$log" ] && tail -n 15 "$log" >> "${TMPDIR_S}/fail.log"
    return 1
  }

  if [ "$ARCH" = "aarch64" ]; then
    if try_smoke "--ignore-warnings ARM64-COW-BUG" 1; then
      smoke_ok=yes
      smoke_note="已忽略 ARM64-COW-BUG（构建机 THP=always）"
    fi
  fi
  if [ "$smoke_ok" != "yes" ] && try_smoke "" 2; then
    smoke_ok=yes
  fi

  {
    echo
    echo "--- smoke test (PING => PONG) ---"
    echo "result: ${smoke_ok}"
    [ -n "$smoke_note" ] && echo "note  : ${smoke_note}"
    [ -f "${TMPDIR_S}/redis-1.log" ] && { echo "[log round 1]"; tail -n 20 "${TMPDIR_S}/redis-1.log"; }
    [ -f "${TMPDIR_S}/redis-2.log" ] && { echo "[log round 2]"; tail -n 20 "${TMPDIR_S}/redis-2.log"; }
  } >> "${OUTDIR}/BUILD-INFO.txt"
  if [ "$smoke_ok" != "yes" ]; then
    echo "[ERROR] 冒烟测试失败：redis-server 未能正常响应 PING" >&2
    cat "${TMPDIR_S}/fail.log" 2>/dev/null >&2 || true
    rm -rf "$TMPDIR_S"
    exit 1
  fi
  rm -rf "$TMPDIR_S"
  echo ">>> 冒烟测试通过（PONG${smoke_note:+；${smoke_note}}）"
fi

# ---------- 归一化产物权限（防御源码包内的非常规 mode） ----------
# 产物包必须对「非 root 的打包者 / 解包用户」可读可执行。个别版本源码包内的文件权限
# 并不规整（例：Redis 8.10 的 redis.conf 为 0600），一旦原样带入就会让非 root 打包失败。
# a+rX：目录与原本就带执行位的文件保持可执行（x），普通文件只补读权限（r），
#       不会给二进制额外放开权限。
chmod -R a+rX "$OUTDIR" 2>/dev/null || true

echo "=============================================="
echo " 构建成功"
echo " 产物目录: ${OUTDIR}"
ls -la "${OUTDIR}"
echo "=============================================="

# 便于 CI 直接引用
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "artifact_dir=${OUTDIR}" >> "$GITHUB_OUTPUT"
fi
