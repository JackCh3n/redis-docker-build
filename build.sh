#!/usr/bin/env bash
# =============================================================
# build.sh — 宿主机一键构建入口（本地已安装 Docker 时使用）
#
# 用法：
#   ./build.sh image [x86_64|aarch64]                     # 只构建编译镜像
#   ./build.sh build [版本] [x86_64|aarch64] [malloc]     # 构建并产出二进制
#   ./build.sh all   [版本]                               # 构建 x86_64 + aarch64
#   ./build.sh native [版本] [malloc]                     # 当前主机原生编译（无需 Docker）
#
# 示例：
#   ./build.sh build                       # 默认版本 7.2.16，本机架构
#   ./build.sh build 8.10.1 aarch64        # 构建 aarch64 的 Redis 8.10.1
#   ./build.sh build 7.2.16 x86_64 libc    # 指定 libc 分配器
#
# 说明：aarch64 镜像在 x86_64 主机上构建需要 QEMU（binutils-qemu-static 或
#       docker run --privileged tonistiigi/binfmt --install arm64）。若主机本身
#       就是 aarch64，则原生构建，速度最快。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_TAG="redis-builder:el7"
DEFAULT_VERSION="7.2.16"
DIST_DIR="${SCRIPT_DIR}/dist"
mkdir -p "$DIST_DIR"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)  HOST_ARCH="x86_64" ;;
  aarch64|arm64) HOST_ARCH="aarch64" ;;
esac

# 架构 -> (平台, 基础镜像)
arch_platform() {
  case "$1" in
    x86_64)  echo "linux/amd64" ;;
    aarch64) echo "linux/arm64" ;;
    *) echo "[ERROR] 不支持的架构: $1" >&2; exit 1 ;;
  esac
}
arch_base_image() {
  case "$1" in
    # EL7 glibc 2.17；arm64 使用 arm64v8/centos:7（CentOS 7 altarch）
    x86_64)  echo "centos:7.6.1810" ;;
    aarch64) echo "arm64v8/centos:7" ;;
  esac
}

# QEMU 是否已注册（构建异架构镜像时需要）
ensure_qemu() {
  local arch="$1"
  [ "$arch" = "$HOST_ARCH" ] && return 0
  if [ "$arch" = "aarch64" ] && [ "$HOST_ARCH" = "x86_64" ]; then
    if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 >/dev/null 2>&1; then
      echo ">>> 注册 QEMU binfmt（用于在 x86_64 主机上构建/运行 aarch64 镜像）"
      docker run --privileged --rm tonistiigi/binfmt --install arm64
    fi
  fi
}

build_image() {
  local arch="${1:-$HOST_ARCH}"
  local platform base
  platform="$(arch_platform "$arch")"
  base="$(arch_base_image "$arch")"
  ensure_qemu "$arch"
  echo ">>> 构建镜像 ${IMAGE_TAG} (${arch} / ${base})"
  docker buildx build --platform "$platform" \
    --build-arg "BASE_IMAGE=${base}" \
    -t "${IMAGE_TAG}-${arch}" --load "$SCRIPT_DIR"
}

build_binary() {
  local ver="${1:-$DEFAULT_VERSION}"
  local arch="${2:-$HOST_ARCH}"
  local malloc="${3:-auto}"
  local platform
  platform="$(arch_platform "$arch")"
  ensure_qemu "$arch"
  build_image "$arch"
  echo ">>> 构建 Redis ${ver} (${arch}, malloc=${malloc})"
  docker run --rm --platform "$platform" \
    -v "${DIST_DIR}:/opt/dist" \
    "${IMAGE_TAG}-${arch}" \
    --redis-version "$ver" --malloc "$malloc" --output /opt/dist --smoke yes
}

case "${1:-image}" in
  image)
    build_image "${2:-$HOST_ARCH}"
    ;;
  build)
    build_binary "${2:-$DEFAULT_VERSION}" "${3:-$HOST_ARCH}" "${4:-auto}"
    ;;
  all)
    VER="${2:-$DEFAULT_VERSION}"
    build_binary "$VER" x86_64 auto
    build_binary "$VER" aarch64 auto
    ;;
  native)
    VER="${2:-$DEFAULT_VERSION}"
    MALLOC_ARG="${3:-auto}"
    echo ">>> 当前主机原生编译 Redis ${VER}（malloc=${MALLOC_ARG}）"
    bash "${SCRIPT_DIR}/build-redis.sh" \
      --redis-version "$VER" --malloc "$MALLOC_ARG" --output "$DIST_DIR" --smoke yes
    ;;
  *)
    echo "用法: $0 {image|build|all|native} [版本] [x86_64|aarch64] [auto|jemalloc|libc]" >&2
    exit 1
    ;;
esac

echo ">>> 产物输出到: ${DIST_DIR}"
ls -la "${DIST_DIR}"
