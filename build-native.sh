#!/usr/bin/env bash
# =============================================================
# build-native.sh — 目标机原生编译（无需 Docker）
#
# 适用场景：
#   * 银河麒麟 V10 SP3 (aarch64 / 鲲鹏 920) 等信创环境——离线、无 Docker、
#     或不希望依赖外部镜像时，直接在目标机（或同版本机器）上编译。
#   * 原生编译的产物与本机 glibc / OpenSSL / systemd 完全一致，
#     是 TLS 场景下最稳妥的方式（容器内链接的 OpenSSL 版本可能不匹配目标机）。
#
# 用法：
#   ./build-native.sh                       # 默认版本，自动探测环境
#   ./build-native.sh 7.2.16                # 指定版本
#   ./build-native.sh 7.2.16 jemalloc yes   # 版本 / 分配器 / 是否带 TLS
#   ./build-native.sh --install-deps        # 先尝试安装编译依赖（yum/dnf/apt）
#
# 参数： [版本] [malloc=auto|jemalloc|libc] [tls=yes|no]
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REDIS_VERSION="7.2.16"
MALLOC_ARG="auto"
TLS_ARG="no"
INSTALL_DEPS=no

args=()
for a in "$@"; do
  case "$a" in
    --install-deps) INSTALL_DEPS=yes ;;
    --*) echo "[ERROR] 未知参数: $a" >&2; exit 1 ;;
    *) args+=("$a") ;;
  esac
done
[ "${#args[@]}" -ge 1 ] && REDIS_VERSION="${args[0]}"
[ "${#args[@]}" -ge 2 ] && MALLOC_ARG="${args[1]}"
[ "${#args[@]}" -ge 3 ] && TLS_ARG="${args[2]}"

# ---------------- 环境探测 ----------------
ARCH_RAW="$(uname -m)"
GLIBC_VER="$( (ldd --version 2>/dev/null || echo 'glibc 0') | head -n 1 | grep -oE '[0-9]+\.[0-9]+$' || echo unknown)"
PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo unknown)"
GCC_RAW="$(gcc -dumpfullversion -dumpversion 2>/dev/null || echo none)"

OS_NAME="unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  OS_NAME="$( (. /etc/os-release && echo "${PRETTY_NAME}") || echo unknown )"
elif [ -r /etc/.productinfo ]; then
  OS_NAME="$(head -n 2 /etc/.productinfo | tr '\n' ' ')"
fi

echo "=============================================="
echo " 环境探测"
echo "  操作系统    : ${OS_NAME}"
echo "  架构        : ${ARCH_RAW}"
echo "  glibc       : ${GLIBC_VER}"
echo "  页大小      : ${PAGE_SIZE}"
echo "  system gcc  : ${GCC_RAW}"
echo "=============================================="

# 1) 判断编译器是否需要升级（Redis >= 6.0 需 GCC >= 4.9 / 建议 >= 5.3）
need_newer_gcc=no
if [ "$GCC_RAW" = "none" ]; then
  need_newer_gcc=yes
else
  GCC_NUM="$(echo "$GCC_RAW" | grep -oE '^[0-9]+\.[0-9]+' || echo 0.0)"
  if [ "$(printf '%s\n%s\n' "5.1" "$GCC_NUM" | sort -V | head -n 1)" != "5.1" ]; then
    need_newer_gcc=yes
  fi
fi

if [ "$need_newer_gcc" = "yes" ]; then
  echo
  echo "[!] 当前 GCC (${GCC_RAW}) 低于 Redis ${REDIS_VERSION} 所需的最低版本（5.1）。"
  echo "    请任选一种方式升级后重新执行："
  echo
  echo "    * 银河麒麟 / 统信 UOS / openEuler（yum）："
  echo "        sudo yum install -y centos-release-scl || true    # 仅兼容 EL7 系"
  echo "        sudo yum install -y devtoolset-10-gcc devtoolset-10-gcc-c++ devtoolset-10-make"
  echo "        source /opt/rh/devtoolset-10/enable"
  echo "    或（EL8/EL9 系、openEuler）："
  echo "        sudo yum install -y gcc-toolset-13-gcc gcc-toolset-13-gcc-c++"
  echo "        source /opt/rh/gcc-toolset-13/enable"
  echo
  echo "    * 若无 SCL，可编译安装新版 GCC 后 export PATH，或用 CC/CXX 指定路径。"
  echo "    * 也可以先降低目标版本：Redis 5.0.x 可直接用 GCC 4.8 编译。"
  echo
  echo "    提示：加 --install-deps 可自动尝试安装依赖（需要 root / 可联网）。"
  if [ "$INSTALL_DEPS" != "yes" ]; then
    exit 1
  fi
fi

# 2) 安装依赖（按需）
if [ "$INSTALL_DEPS" = "yes" ]; then
  echo ">>> 尝试安装编译依赖"
  PKGS_BASE="gcc gcc-c++ make tar gzip which perl diffutils wget"
  PKGS_OPT=""
  [ "$TLS_ARG" = "yes" ] && PKGS_OPT="openssl-devel"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y $PKGS_BASE $PKGS_OPT || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y $PKGS_BASE $PKGS_OPT || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    apt-get install -y gcc g++ make tar gzip perl diffutils wget $([ "$TLS_ARG" = yes ] && echo libssl-dev) || true
  else
    echo "[WARN] 未识别包管理器，请手动确认依赖已安装" >&2
  fi
fi

# 3) 依赖存在性检查
missing=""
for c in gcc make tar; do
  command -v "$c" >/dev/null 2>&1 || missing="${missing} ${c}"
done
if [ -n "$missing" ]; then
  echo "[ERROR] 缺少命令:${missing}" >&2
  exit 1
fi
if [ "$TLS_ARG" = "yes" ]; then
  if [ ! -f /usr/include/openssl/ssl.h ] && [ ! -d /usr/local/include/openssl ]; then
    echo "[WARN] --tls yes 但未找到 openssl 开发头文件，构建可能失败" >&2
  fi
fi

# 4) 大页提示（ARM）
if [ "$PAGE_SIZE" = "65536" ]; then
  echo ">>> 检测到 64KB 页大小（ARM 大页内核）"
  if [ "$MALLOC_ARG" = "auto" ]; then
    echo "    已自动启用 jemalloc --with-lg-page=16（Redis>=7.0）以兼容大页"
  fi
fi

# 5) 调用核心构建脚本
echo
echo ">>> 开始原生编译 Redis ${REDIS_VERSION}（malloc=${MALLOC_ARG}, tls=${TLS_ARG}）"
exec bash "${SCRIPT_DIR}/build-redis.sh" \
  --redis-version "$REDIS_VERSION" \
  --malloc "$MALLOC_ARG" \
  --tls "$TLS_ARG" \
  --output "${SCRIPT_DIR}/dist" \
  --smoke yes
