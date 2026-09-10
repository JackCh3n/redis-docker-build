# syntax=docker/dockerfile:1
# =============================================================
# redis-docker-build
# 在「Docker 模拟的 CentOS 7.6.1810 环境」中构建 Redis 二进制，
# 用于生产环境原地升级（替换 redis-server/redis-cli 等）。
#
# 同一份 Dockerfile 覆盖两种架构，通过 --build-arg 切换基础镜像：
#
#   x86_64 : docker build --build-arg BASE_IMAGE=centos:7.6.1810      -t redis-builder:7.6 .
#   aarch64: docker buildx build --platform linux/arm64 \
#              --build-arg BASE_IMAGE=arm64v8/centos:7 -t redis-builder:7.6 -f Dockerfile .
#
# 关键设计
# ---------
# 1) 软件源：CentOS 7 已于 2024-06-30 EOL，官方 mirrorlist 失效；vault.centos.org
#    在部分网络（含国内政务/内网）不可达。因此默认使用「国内归档镜像」重建 repo，
#    可用 --build-arg OS_MIRROR= 覆盖（华为/清华/腾讯云均已实测可用）。
# 2) 工具链：Redis >= 6.0 起编译依赖 C11 原子操作（<stdatomic.h>），需要 GCC >= 4.9
#    （官方建议 >= 5.3）。CentOS 7 原装 GCC 4.8.5 无法编译 Redis 6/7/8，故安装
#    devtoolset-10（GCC 10.2）。产物仍然只依赖 glibc 2.17。
# 3) ABI 下限：产物运行需要 glibc >= 2.17，可覆盖 CentOS 7.6/7.9，
#    以及 glibc >= 2.17 的全部 aarch64 发行版（含银河麒麟 V10 SP3 = glibc 2.28）。
# =============================================================

ARG BASE_IMAGE=centos:7.6.1810
FROM ${BASE_IMAGE}

# ---------- 可覆盖构建参数 ----------
# OS_MIRROR        : CentOS 7 归档镜像根地址（不含版本段）
# VAULT_PREFIX     : 归档路径前缀。留空则按架构自动选择：
#                    x86_64  -> 7.6.1810            （与 centos:7.6.1810 基础镜像一致）
#                    aarch64 -> altarch/7           （与 arm64v8/centos:7 基础镜像一致）
# DEVTOOLSET       : 软件集合名，devtoolset-9/10/12 在 x86_64 与 aarch64 上均有提供
# DEVTOOLSET_MIRROR: devtoolset 的 RPM 归档源（CentOS buildlogs）
ARG OS_MIRROR=https://mirrors.aliyun.com/centos-vault
ARG VAULT_PREFIX=
ARG DEVTOOLSET=devtoolset-10
ARG DEVTOOLSET_MIRROR=https://buildlogs.centos.org

ENV DEVTOOLSET_ROOT=/opt/rh/${DEVTOOLSET}/root

# ---------- 1) 重建 yum 源（base / updates / extras） ----------
# 说明：不使用 heredoc（YAML/转义易出错），直接用 printf 生成 repo 文件。
#       $basearch 用单引号保护，保持字面量交给 yum 展开。
RUN set -eux; \
    ARCH="$(uname -m)"; \
    if [ -z "${VAULT_PREFIX}" ]; then \
      if [ "${ARCH}" = "aarch64" ]; then VAULT_PREFIX="altarch/7"; else VAULT_PREFIX="7.6.1810"; fi; \
    fi; \
    echo ">>> 基础镜像架构: ${ARCH} / 归档路径: ${VAULT_PREFIX}"; \
    rm -f /etc/yum.repos.d/*.repo; \
    for r in os updates extras; do \
      printf '[centos7-%s]\nname=CentOS-7 - %s (archived)\nbaseurl=%s/%s/%s/$basearch/\ngpgcheck=0\nenabled=1\n\n' \
        "$r" "$r" "${OS_MIRROR}" "${VAULT_PREFIX}" "$r" >> /etc/yum.repos.d/centos7-vault.repo; \
    done; \
    yum clean all; \
    yum -y makecache fast

# ---------- 2) 安装 devtoolset（GCC 10） ----------
# buildlogs 目录本身就是可用的 yum 仓库（含 repodata）。
# devtoolset 的 RPM 未经签名发布，故 --nogpgcheck。
RUN set -eux; \
    ARCH="$(uname -m)"; \
    printf '[devtoolset]\nname=devtoolset - %s\nbaseurl=%s/c7-%s.%s/\ngpgcheck=0\nenabled=1\n\n' \
      "${DEVTOOLSET}" "${DEVTOOLSET_MIRROR}" "${DEVTOOLSET}" "${ARCH}" > /etc/yum.repos.d/devtoolset.repo; \
    yum -y install --nogpgcheck \
        scl-utils \
        "${DEVTOOLSET}-gcc" \
        "${DEVTOOLSET}-gcc-c++" \
        "${DEVTOOLSET}-make" \
        "${DEVTOOLSET}-binutils"; \
    yum clean all; \
    "${DEVTOOLSET_ROOT}/usr/bin/gcc" --version | head -1

# ---------- 3) 安装 Redis 编译依赖 ----------
# 必需：gcc/make/binutils（上面 devtoolset 提供）、wget、tar、perl（部分脚本用）、
#       diffutils/which、ca-certificates。
# 可选：openssl-devel（--tls yes 时需要）、systemd-devel（--systemd yes 时需要），
#       二者默认不在镜像内，构建时按需传入 INSTALL_OPT_DEPS=yes。
ARG INSTALL_OPT_DEPS=no
RUN set -eux; \
    yum -y install \
        wget tar gzip xz which perl diffutils findutils ca-certificates; \
    if [ "${INSTALL_OPT_DEPS}" = "yes" ]; then \
      yum -y install openssl-devel systemd-devel; \
    fi; \
    yum clean all

# 使用 devtoolset 工具链（PATH 方式，无需 scl enable，脚本/CI 中更省心）
ENV PATH=${DEVTOOLSET_ROOT}/usr/bin:$PATH \
    CC=${DEVTOOLSET_ROOT}/usr/bin/gcc \
    CXX=${DEVTOOLSET_ROOT}/usr/bin/g++ \
    LD_LIBRARY_PATH=${DEVTOOLSET_ROOT}/usr/lib64:${DEVTOOLSET_ROOT}/usr/lib

# ---------- 4) 容器内构建脚本 ----------
COPY build-redis.sh /usr/local/bin/build-redis.sh
RUN chmod +x /usr/local/bin/build-redis.sh

WORKDIR /opt/src
ENTRYPOINT ["/usr/local/bin/build-redis.sh"]
