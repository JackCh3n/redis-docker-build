<div align="center">

# redis-docker-build

**在 Docker 模拟的 CentOS 7.6.1810 环境中构建 Redis 二进制，用于生产环境升级**

同时产出 **x86_64**（CentOS 7.6 / 7.9）与 **aarch64**（银河麒麟 V10 SP3 / 鲲鹏 920 等）两套产物

[![GitHub Actions](https://img.shields.io/github/actions/workflow/status/JackCh3n/redis-docker-build/build.yml?label=build&logo=github)](https://github.com/JackCh3n/redis-docker-build/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/JackCh3n/redis-docker-build?label=release&sort=semver)](https://github.com/JackCh3n/redis-docker-build/releases)
[![License](https://img.shields.io/github/license/JackCh3n/redis-docker-build)](LICENSE)
[![CentOS](https://img.shields.io/badge/CentOS-7.6.1810-blue)](https://hub.docker.com/_/centos)
[![Kylin](https://img.shields.io/badge/%E9%93%B6%E6%B2%B3%E9%BA%92%E9%BA%9F-V10%20SP3-red)](https://www.kylinos.cn/)

**语言 / Language：[中文](#中文) | [English](#english)**

</div>

---

# 中文

## 项目简介

生产环境常常需要**脱离发行版自带仓库的 Redis 版本**——CentOS 7 官方仓库的 Redis 停留在 3.x，而信创环境（银河麒麟 V10 SP3 / 鲲鹏 920）往往要求**可控来源、可复现、可审计**的二进制。本项目在 Docker 容器中**复刻生产工具链**，按需构建可直接替换的生产 Redis 二进制。

与 nginx 不同，**Redis 的动态依赖更少，但对编译器要求更高**：

| 项目 | 说明 |
|---|---|
| **CentOS 7 原装 GCC 4.8.5 无法编译 Redis ≥ 6.0** | Redis 6.0 起使用 C11 原子操作（`<stdatomic.h>`），要求 GCC ≥ 4.9（官方建议 ≥ 5.3） |
| 解决方式 | 镜像内安装 **devtoolset-10（GCC 10.2）**，产物仍只依赖 **glibc 2.17** |
| ARM64 大页陷阱 | jemalloc 将构建机页大小写死；64KB 页机器会报 `unsupported system page size`。本项目在 aarch64 上以 `--with-lg-page=16` 构建，**同时兼容 4KB / 64KB 页** |

## 支持矩阵

### 构建环境与产物运行范围

| 目标架构 | 基础镜像 | 工具链 | 产物 glibc 要求 | 可运行于 |
|---|---|---|---|---|
| **x86_64** | `centos:7.6.1810` | devtoolset-10 (GCC 10.2) | ≥ 2.17 | CentOS 7.6 / 7.9 及更高版本 |
| **aarch64** | `arm64v8/centos:7` | devtoolset-10 (GCC 10.2) | ≥ 2.17 | **银河麒麟 V10（SP1/SP2/SP3）**、统信 UOS、openEuler、CentOS/Rocky/Alma 8+、Ubuntu 20.04+、Debian 10+ 等 |

> ✅ **已针对银河麒麟高级服务器操作系统 V10 SP3 2303（aarch64 / Kunpeng-920）做适配**
> 该系统实测环境：内核 `4.19.90` / glibc `2.28-88` / GCC `7.3.0`。
> 本项目产物的 glibc 下限为 **2.17**，低于麒麟的 2.28，因此可直接运行（glibc 向后兼容）。
> 若需与本机 glibc / OpenSSL / systemd **完全一致**的产物（尤其是 TLS 场景），请使用
> [`build-native.sh`](#方式三目标机原生编译麒麟--信创推荐) 在麒麟机器上原生编译。

### Redis 版本支持

| Redis 版本 | 许可协议 | x86_64 (CentOS 7.6) | aarch64 (麒麟 V10 SP3) | 说明 |
|---|---|---|---|---|
| 5.0.14 | BSD-3-Clause | ✅ | ✅ | 系统 GCC 4.8 即可编译，最省事 |
| 6.2.24 | BSD-3-Clause | ✅ | ✅ | 需 GCC ≥ 5.1（devtoolset） |
| 7.0.15 | BSD-3-Clause | ✅ | ✅ | |
| **7.2.16** | **BSD-3-Clause** | **✅ 默认** | **✅ 默认** | **最后一个 BSD 协议版本**，政务/信创场景推荐 |
| 7.4.11 | RSALv2 / SSPLv1 | ✅ | ✅ | 协议变更为源码可用许可 |
| 8.0.6 / 8.2.9 | RSALv2 / SSPLv1 / AGPLv3 | ✅ | ✅ | 需 `BUILD_WITH_MODULES=no`（core-only） |
| 8.4.6 / 8.6.6 / 8.8.2 / 8.10.1 | 三许可 | ⚠️ | ⚠️ | **当前最新版**；Redis 官方测试矩阵已不含 EL7，工具链满足要求但建议先自测 |

说明：

- **✅** = 本项目工具链（GCC 10.2）满足要求，可直接构建；产物运行要求 `glibc ≥ 2.17`
- **⚠️** = 工具链同样满足，但 Redis 官方自 8.x 起已不再测试 CentOS / RHEL 7。社区已验证
  Redis 8.0.0 可在 CentOS 7 + devtoolset 环境下构建成功；8.4 以上版本请先在小范围验证。
  遇到编译报错时，可用 `--build-arg DEVTOOLSET=devtoolset-12`（GCC 12.2）重试。
- **最新版本**：Redis Open Source **8.10.1**（2026-08-17）；主线默认构建 **7.2.16**（BSD 协议、最稳）。
- 构建任意版本：手动触发 CI 或本地 `./build.sh build 8.10.1`。

### Redis 许可说明（重要）

| 版本区间 | 许可 |
|---|---|
| **7.2.x 及更早** | **BSD-3-Clause**（宽松，无商业限制） |
| 7.4.x – 7.8.x | RSALv2 或 SSPLv1（源码可用，**非** OSI 开源） |
| 8.0.x 及以后 | RSALv2 / SSPLv1 / **AGPLv3** 三选一 |

- 自建内网 Redis、把 Redis 作为业务基础设施使用，**均不受上述限制影响**（限制主要针对"把 Redis 作为托管服务对外售卖"）。
- 强 copyleft 或"禁用非 OSI 许可"的合规要求下：选 **7.2.16（BSD-3）**，或对 8.x 选用 AGPLv3 分支并遵守其开源义务。
- Redis 8 起，RediSearch / RedisJSON / RedisTimeSeries / RedisBloom 内置且同许可。

## 目录结构

```
.
├── Dockerfile                     # EL7（x86_64 / aarch64）编译环境，含归档源修复 + devtoolset-10
├── build-redis.sh                 # 容器内/目标机 参数化构建脚本（核心）
├── build.sh                       # 宿主机一键构建入口（本地有 Docker 时）
├── build-native.sh                # 目标机原生编译（麒麟/信创，无需 Docker）
├── .github/workflows/build.yml    # GitHub Actions 流水线（x86_64 + aarch64）
├── .cnb.yml                       # CNB (cnb.cool) 流水线（x86_64）
├── assets/
│   ├── redis.service              # systemd 单元模板
│   └── redis.conf.example         # 生产配置参考（含 ARM / 麒麟调优提示）
└── dist/                          # 构建产物输出目录
```

## 快速开始

### 方式一：云端 CI 构建（推荐，无需本地 Docker）

- **GitHub Actions**：推送到 `main` 自动构建 x86_64 + aarch64 并发布到 `latest` Release；
  也可在 Actions 页面 **Run workflow** 手动指定任意版本 / 分配器 / 架构 / TLS。

  > ⚠️ 二进制**必须**在本仓库 Dockerfile 内编译——直接在 Ubuntu runner 上编译会链接 glibc 2.35+，无法在 CentOS 7.6（glibc 2.17）上运行。
  > aarch64 默认用 QEMU 模拟构建；若仓库为 public，可将 workflow 中 aarch64 的 `runs-on` 改为 `ubuntu-24.04-arm`，用 GitHub 免费原生 ARM runner 提速数倍。

- **CNB (cnb.cool)**：推送到 `main`/`master` 自动构建 x86_64 产物并发布到 `latest`。

### 方式二：本地 Docker 构建

```bash
# 1a. 构建本机架构的编译镜像
./build.sh image

# 1b. 仅构建 aarch64 镜像（x86_64 主机需先注册 QEMU，脚本会自动处理）
./build.sh image aarch64

# 2a. 构建默认版本（7.2.16）本机架构产物
./build.sh build

# 2b. 指定版本 + 架构 + 分配器
./build.sh build 8.10.1 aarch64 auto

# 2c. 一次构建 x86_64 + aarch64 两套
./build.sh all 7.2.16

# 产物输出到 ./dist/redis-<版本>-<架构>/
```

等价的 `docker` 原生命令：

```bash
docker build -t redis-builder:el7 .

docker run --rm -v "$PWD/dist:/opt/dist" redis-builder:el7 \
  --redis-version 7.2.16 --malloc auto --smoke yes --output /opt/dist

# aarch64（需 QEMU 已注册：docker run --privileged --rm tonistiigi/binfmt --install arm64）
docker buildx build --platform linux/arm64 \
  --build-arg BASE_IMAGE=arm64v8/centos:7 -t redis-builder:el7-arm --load .
docker run --rm --platform linux/arm64 -v "$PWD/dist:/opt/dist" redis-builder:el7-arm \
  --redis-version 7.2.16 --output /opt/dist
```

### 方式三：目标机原生编译（麒麟 / 信创推荐）

在麒麟 V10 SP3（或同版本机器）上直接编译，产物与本机 glibc / OpenSSL / systemd 完全一致，
是 **TLS 场景与离线环境**下最稳妥的方式：

```bash
# 1. 上传仓库到目标机（或 git clone 内网镜像）
# 2. 若本机 gcc 版本不足（麒麟 V10 SP3 自带 GCC 7.3，通常够用），脚本会给出升级提示
./build-native.sh

# 指定版本 / 分配器 / 开启 TLS
./build-native.sh 7.2.16 jemalloc yes

# 需要脚本代为安装依赖（yum/dnf/apt）
./build-native.sh --install-deps
```

脚本会自动探测 `OS / glibc / gcc / 页大小` 并给出针对性提示（例如 64KB 页时自动启用
`--with-lg-page=16`）。

## 构建参数

| 命令行参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `--redis-version` | `REDIS_VERSION` | `7.2.16` | Redis 版本号 |
| `--prefix` | `REDIS_PREFIX` | `/usr/local` | `make install PREFIX=` 安装前缀 |
| `--output` | `OUTPUT_DIR` | `/opt/dist` | 产物输出目录 |
| `--malloc` | `REDIS_MALLOC` | `auto` | `auto` \| `jemalloc` \| `libc` |
| `--tls` | `REDIS_TLS` | `no` | 编译 TLS 支持（Redis ≥ 6.0，需 `openssl-devel`） |
| `--systemd` | `REDIS_SYSTEMD` | `no` | 编译 systemd 支持（需 `systemd-devel`） |
| `--modules` | `REDIS_MODULES` | `no` | 编译 8.x 内置模块（需 Rust 与网络） |
| `--lg-page` | `REDIS_LG_PAGE` | aarch64=`16`，x86_64=`12` | jemalloc 最大页大小 log2（Redis ≥ 7.0） |
| `--prog-suffix` | `REDIS_PROG_SUFFIX` | （空） | `PROG_SUFFIX`，程序名后缀 |
| `--jobs` | `REDIS_JOBS` | `nproc` | 编译并行数 |
| `--source-url` | `REDIS_SOURCE_URL` | （空） | 覆盖源码下载地址（内网离线镜像） |
| `--smoke` | `REDIS_SMOKE` | `yes` | 构建后执行 PONG 冒烟测试 |

Docker 镜像层可覆盖参数：`OS_MIRROR`（归档镜像）、`VAULT_PREFIX`、`DEVTOOLSET`、`DEVTOOLSET_MIRROR`、`INSTALL_OPT_DEPS`。

## ARM64 / 银河麒麟专项说明

### 1. 页大小（最容易踩的坑）

ARM64 服务器常见 **64KB 页**，而 jemalloc 会把编译机页大小作为支持上限写死进二进制，
在 64KB 页机器上启动会报：

```
<jemalloc>: Unsupported system page size
zmalloc: Out of memory trying to allocate 48 bytes
```

确认目标机页大小：

```bash
getconf PAGESIZE      # 4096 或 65536
```

本项目的处理：

| 场景 | 处理 |
|---|---|
| Redis ≥ 7.0 + aarch64 | 自动加 `JEMALLOC_CONFIGURE_OPTS="--with-lg-page=16"` → 同时支持 4KB / 64KB 页 |
| Redis < 7.0 + aarch64 | 该变量不存在，自动改用 `libc` 分配器（安全优先） |
| 仍需绝对保险 | 显式 `--malloc libc`，彻底规避页大小问题（内存碎片率略高） |

### 2. TLS 与 aarch64 的注意事项

容器内（EL7）编译 TLS 会链接 **OpenSSL 1.0.2k（`libssl.so.10`）**，
而麒麟 V10 SP3 / UOS 等系统自带 **OpenSSL 1.1.1（`libssl.so.1.1`）**，
libssl 主版本不同 → 产物在目标机上会因缺少 `libssl.so.10` 而无法启动。

因此：

- aarch64 产物**默认关闭 TLS**（`--tls no`），此时不依赖任何 OpenSSL，可在任意 aarch64 系统运行；
- 若必须启用 TLS，**请在目标机上使用 `build-native.sh --tls yes` 原生编译**，让其链接本机 OpenSSL；
- 或参考思路：静态编入 OpenSSL 源码（本项目暂未内置该选项，如需可提 Issue）。

### 3. 鲲鹏 920 编译优化（可选）

鲲鹏 920 具备 `crc32 / aes / sha1 / sha2 / pmull` 硬件加速指令。默认 `-O2` 下编译器会自动
向量化；如需显式启用，可在构建时追加：

```bash
make ... CFLAGS="-march=armv8-a+crc -O2"
```

## 版本语义：主线 vs 稳定版

| 触发方式 | 场景 | 构建内容 | Release |
|---|---|---|---|
| push 到 `main` / `master` | **主线版本** | 默认版本（x86_64 + aarch64） | `latest`（每次推送覆盖更新） |
| git tag `vRedis-x.y.z` | **稳定版** | 仅该版本（x86_64 + aarch64） | tag 同名 Release（固化） |
| GitHub 手动触发 | 任意版本/分配器/架构 | 按输入构建 | `vRedis-{版本}` |

```bash
# 发布稳定版 Redis 7.2.16
git tag vRedis-7.2.16 && git push --tags

# 更新稳定版（同版本重打 tag）
git tag -f vRedis-7.2.16 && git push --force --tags
```

## 升级流程（线上操作参考）

> ⚠️ **与 nginx 不同：Redis 没有 `kill -USR2` 式的二进制热升级**。替换二进制必须重启进程，
> 因此升级方案取决于部署形态。**任何操作前先备份 `dump.rdb` / `appendonlydir/` 与 `redis.conf`。**

### 第 0 步：跨大版本先校验配置兼容性（必做）

Redis 7 把一批 `*-ziplist-*` 参数改名为 `*-listpack-*`，**旧的配置项会导致新进程直接启动失败**：

| Redis 5 / 6 旧配置 | Redis 7+ 新配置 |
|---|---|
| `hash-max-ziplist-entries` | `hash-max-listpack-entries` |
| `hash-max-ziplist-value` | `hash-max-listpack-value` |
| `zset-max-ziplist-entries` | `zset-max-listpack-entries` |
| `zset-max-ziplist-value` | `zset-max-listpack-value` |
| `list-max-ziplist-size` | `list-max-listpack-size` |

用**新二进制 + 临时端口**先验证配置能否被解析（Redis 无 `nginx -t`，用临时实例代替）：

```bash
# 用新二进制以临时端口起一个实例，只验证配置，确认无误后立刻关掉
/opt/redis-new/bin/redis-server /etc/redis/redis.conf \
  --port 16399 --daemonize yes --pidfile /tmp/redis-test.pid --logfile /tmp/redis-test.log
sleep 1
/opt/redis-new/bin/redis-cli -p 16399 -a '<password>' info server | grep redis_version
/opt/redis-new/bin/redis-cli -p 16399 -a '<password>' shutdown nosave
# 若配置有误，/tmp/redis-test.log 会给出具体行号与错误原因
```

同时用新二进制校验数据文件：

```bash
/opt/redis-new/bin/redis-check-rdb /var/lib/redis/dump.rdb
/opt/redis-new/bin/redis-check-aof /var/lib/redis/appendonlydir/appendonly.aof.manifest
```

### 方案 A：单机（可接受秒级中断）

```bash
# 1. 备份
sudo cp -a /usr/local/bin/redis-server /usr/local/bin/redis-server.bak.$(date +%Y%m%d)
sudo cp -a /var/lib/redis/dump.rdb /var/lib/redis/dump.rdb.bak.$(date +%Y%m%d)
redis-cli -a '<password>' bgsave && sleep 2      # 落盘最新数据

# 2. 停服
sudo systemctl stop redis

# 3. 替换二进制（只换可执行文件，配置与数据目录不动）
sudo cp dist/redis-7.2.16-x86_64/redis-server  /usr/local/bin/redis-server
sudo cp dist/redis-7.2.16-x86_64/redis-cli     /usr/local/bin/redis-cli
sudo cp dist/redis-7.2.16-x86_64/redis-sentinel /usr/local/bin/redis-sentinel 2>/dev/null || true

# 4. 启动并验证
sudo systemctl start redis
redis-cli -a '<password>' ping                  # 期望 PONG
redis-cli -a '<password>' info server | grep redis_version
```

### 方案 B：主从 / Sentinel / Cluster（滚动升级，业务基本无感）

```bash
# 1. 逐个升级【从库】：停 -> 换二进制 -> 起 -> 确认 SYNC 正常
redis-cli -h <replica-ip> -a '<password>' info replication | grep master_link_status

# 2. 触发一次主从切换（Sentinel 自动 failover，或手动）
redis-cli -a '<password>' REPLICAOF NO ONE      # 旧主库手动降级
# 或将新升级完成的从库提升为主库后，让旧主库指向新主库

# 3. 升级原主库（此时它是从库角色，可安全重启），完成后恢复原拓扑

# 4. Cluster：逐节点升级，先升级所有从节点，再对主节点执行
#    CLUSTER FAILOVER（手动故障转移），每升一个节点观察 cluster info 状态
```

### 回滚

```bash
# 单机：换回备份二进制后再启动
sudo systemctl stop redis
sudo cp /usr/local/bin/redis-server.bak.20260910 /usr/local/bin/redis-server
sudo systemctl start redis
# 若数据异常，用备份的 dump.rdb 覆盖（务必先停服）
```

> ⚠️ **降级注意**：Redis 7.x 默认使用 **multi-part AOF**（`appendonlydir/` 目录）。从 7.x
> 降级回 6.x 时，旧版本不认识该目录结构，回滚前需先 `CONFIG SET appendonly no` 并用 RDB
> 恢复，或按官方文档转换 AOF。**跨大版本升级前请确认回滚路径可用。**

## 兼容性与已知问题

- **软件源**：CentOS 7 已 EOL，`vault.centos.org` 在部分网络（含国内政务内网）返回 403；
  本项目默认使用国内归档镜像重建源，已实测可用：阿里云（默认）、清华 TUNA、华为云、腾讯云。
  可通过 `--build-arg OS_MIRROR=<镜像根地址>` 切换，内网可指向自建镜像站。
- **devtoolset 源**：`devtoolset-9 / 10 / 12` 在 x86_64 与 aarch64 上均由
  `buildlogs.centos.org` 提供（含 repodata，可直接作为 yum 源）；`devtoolset-11` 无归档，故默认用 `-10`。
- **TLS 默认关闭**：容器内 OpenSSL 为 1.0.2k，产物会链接 `libssl.so.10`，在 glibc/OpenSSL
  较新的系统（如麒麟 V10）上可能缺少该库。需要 TLS 请用 `build-native.sh --tls yes` 原生编译，
  或先确认目标机存在 `libssl.so.10`。
- **Redis 5.0.x** 不支持 `BUILD_TLS`（TLS 自 6.0 引入），脚本会自动忽略该选项。
- **Redis 8.x 内置模块**（RediSearch / RedisJSON 等）默认不编译（core-only）：需要 Rust 工具链
  与网络拉取模块源码，与"离线、可复现"目标冲突。确有需要时用 `--modules yes`。
- **`make` 需要 GNU make ≥ 3.81**：EL7 自带 3.82，满足要求。
- **bash 4.2 陷阱**（CentOS 7）：`set -u` 下避免 `${VAR:-$(cmd)}` 写法与空数组展开，脚本已处理。

## 冒烟测试

每次构建脚本都会自动执行以下检查，结果写入产物目录的 `BUILD-INFO.txt`：

1. `redis-server --version`（确认版本号与 `malloc=` 标识）
2. 二进制 `GLIBC_*` 符号版本上限（`objdump -T`，用于确认目标机 glibc 是否满足）
3. `ldd` 动态依赖清单
4. **真实启动一次实例并执行 `PING`，要求返回 `PONG`**，随后 `SHUTDOWN NOSAVE`

CI 中还会额外校验 tar 包完整性并输出产物清单。

## 贡献指南

欢迎参与贡献！请：

1. Fork 本仓库并创建功能分支。
2. 修改 shell 脚本后执行 `bash -n <脚本>` 做语法检查。
3. 保持 GitHub Actions 与 CNB 两条流水线的默认版本一致。
4. 提交 Pull Request，说明改动内容与验证情况（平台 / 架构 / 版本 / 操作步骤）。

## 开源协议

[MIT](LICENSE) © JackCh3n

> 本项目仅包含构建脚本，**不包含 Redis 源码**。构建产物遵循对应 Redis 版本的许可协议
> （见上文「Redis 许可说明」）。

---

# English

**Build Redis binaries inside a Docker-simulated CentOS 7.6.1810 environment for production upgrades.**

Produces both **x86_64** (CentOS 7.6 / 7.9) and **aarch64** (Kylin V10 SP3 / Kunpeng 920) artifacts.

## Overview

Production often needs a **Redis version the distro repo doesn't ship** (CentOS 7 stuck on Redis 3.x), while domestic/regulated environments (Kylin V10 SP3 on Kunpeng 920) demand **auditable, reproducible** binaries. This project mirrors the production toolchain inside Docker and builds drop-in Redis binaries on demand.

Unlike nginx, Redis has far fewer dynamic dependencies but much stricter compiler requirements:

| Item | Detail |
|---|---|
| **CentOS 7's stock GCC 4.8.5 cannot build Redis ≥ 6.0** | Redis 6.0+ uses C11 atomics (`<stdatomic.h>`), requiring GCC ≥ 4.9 (≥ 5.3 recommended) |
| Fix | Install **devtoolset-10 (GCC 10.2)** in the image; artifacts still only require **glibc 2.17** |
| ARM64 page-size trap | jemalloc bakes the build host's page size into the binary; on 64KB-page hosts it aborts with `unsupported system page size`. On aarch64 we build with `--with-lg-page=16`, supporting **both 4KB and 64KB pages** |

## Support matrix

### Build environment

| Arch | Base image | Toolchain | glibc requirement | Runs on |
|---|---|---|---|---|
| **x86_64** | `centos:7.6.1810` | devtoolset-10 (GCC 10.2) | ≥ 2.17 | CentOS 7.6 / 7.9 and later |
| **aarch64** | `arm64v8/centos:7` | devtoolset-10 (GCC 10.2) | ≥ 2.17 | **Kylin V10 (SP1/SP2/SP3)**, UOS, openEuler, CentOS/Rocky/Alma 8+, Ubuntu 20.04+, Debian 10+ |

> ✅ **Adapted for Kylin Linux Advanced Server V10 (SP3) 2303 on aarch64 / Kunpeng-920**
> (kernel `4.19.90`, glibc `2.28-88`, GCC `7.3.0`). Our artifacts target **glibc ≥ 2.17**, below Kylin's 2.28, so they run as-is.
> For a binary that exactly matches the target's glibc/OpenSSL/systemd (especially with TLS), use `build-native.sh` on the Kylin host.

### Redis versions

| Version | License | x86_64 | aarch64 | Note |
|---|---|---|---|---|
| 5.0.14 | BSD-3-Clause | ✅ | ✅ | Builds even with stock GCC 4.8 |
| 6.2.24 | BSD-3-Clause | ✅ | ✅ | Requires GCC ≥ 5.1 |
| 7.0.15 | BSD-3-Clause | ✅ | ✅ | |
| **7.2.16** | **BSD-3-Clause** | **✅ default** | **✅ default** | **Last BSD release** — recommended |
| 7.4.11 | RSALv2 / SSPLv1 | ✅ | ✅ | Source-available licensing |
| 8.0.6 / 8.2.9 | RSALv2 / SSPLv1 / AGPLv3 | ✅ | ✅ | core-only build |
| 8.4.6 / 8.6.6 / 8.8.2 / 8.10.1 | tri-license | ⚠️ | ⚠️ | **Latest**; Redis no longer tests EL7 — toolchain is sufficient, but validate first |

- **✅** = the toolchain (GCC 10.2) satisfies requirements; artifacts require `glibc ≥ 2.17`.
- **⚠️** = same toolchain applies, but upstream dropped CentOS/RHEL 7 from its test matrix at 8.x. The community has built Redis 8.0.0 on CentOS 7 + devtoolset successfully. For ≥ 8.4, validate in a small scope first; retry with `--build-arg DEVTOOLSET=devtoolset-12` (GCC 12.2) if you hit compiler errors.
- Latest Redis Open Source: **8.10.1** (2026-08-17). Mainline defaults to **7.2.16** (BSD, most conservative).

### Licensing

| Versions | License |
|---|---|
| **7.2.x and earlier** | **BSD-3-Clause** |
| 7.4.x – 7.8.x | RSALv2 or SSPLv1 (source-available) |
| 8.0.x and later | RSALv2 / SSPLv1 / **AGPLv3** (choose one) |

Self-hosted internal use is unaffected by these restrictions. If your policy forbids non-OSI licenses, pick **7.2.16**.

## Quick start

### Option 1: Cloud CI (recommended)

- **GitHub Actions** — pushes to `main` build x86_64 + aarch64 and publish to the `latest` release. **Run workflow** lets you pick version / allocator / arch / TLS.
  > ⚠️ Binaries **must** be built inside this repo's Dockerfile — compiling on a plain Ubuntu runner links glibc 2.35+ and won't run on CentOS 7.6. To speed up aarch64, switch its `runs-on` to `ubuntu-24.04-arm` (free native ARM runners for public repos).
- **CNB (cnb.cool)** — pushes to `main`/`master` build x86_64 and publish to `latest`.

### Option 2: Local Docker build

```bash
./build.sh image                 # build builder image for host arch
./build.sh image aarch64         # build aarch64 builder image (auto-registers QEMU)
./build.sh build                 # build default version (7.2.16)
./build.sh build 8.10.1 aarch64  # version + arch
./build.sh all 7.2.16            # both arches
```

Raw `docker` equivalent:

```bash
docker build -t redis-builder:el7 .
docker run --rm -v "$PWD/dist:/opt/dist" redis-builder:el7 \
  --redis-version 7.2.16 --malloc auto --smoke yes --output /opt/dist
```

### Option 3: Native build on the target host (Kylin / offline)

```bash
./build-native.sh                    # auto-detects OS / glibc / gcc / page size
./build-native.sh 7.2.16 jemalloc yes # version / allocator / TLS
./build-native.sh --install-deps      # let it install build deps via yum/dnf/apt
```

Native builds link the host's own OpenSSL/systemd and are the safest path for TLS.

## Build parameters

| Flag | Env var | Default | Description |
|---|---|---|---|
| `--redis-version` | `REDIS_VERSION` | `7.2.16` | Redis version |
| `--prefix` | `REDIS_PREFIX` | `/usr/local` | `make install PREFIX=` |
| `--output` | `OUTPUT_DIR` | `/opt/dist` | Artifact output dir |
| `--malloc` | `REDIS_MALLOC` | `auto` | `auto` \| `jemalloc` \| `libc` |
| `--tls` | `REDIS_TLS` | `no` | Build TLS support (Redis ≥ 6.0) |
| `--systemd` | `REDIS_SYSTEMD` | `no` | Build systemd support |
| `--modules` | `REDIS_MODULES` | `no` | Build 8.x bundled modules (needs Rust) |
| `--lg-page` | `REDIS_LG_PAGE` | `16` on aarch64, `12` on x86_64 | jemalloc max page size (log2) |
| `--smoke` | `REDIS_SMOKE` | `yes` | Run a PING/PONG smoke test |

## ARM64 / Kylin notes

1. **Page size** — 64KB-page ARM64 kernels break jemalloc built for 4KB. Check with `getconf PAGESIZE`.
   This project passes `JEMALLOC_CONFIGURE_OPTS="--with-lg-page=16"` on aarch64 (Redis ≥ 7.0), which
   supports both 4KB and 64KB. For Redis < 7.0 on aarch64 it falls back to `libc`. Use `--malloc libc` to opt out entirely.
2. **TLS on aarch64** — the EL7 container links OpenSSL 1.0.2k (`libssl.so.10`), while Kylin/UOS ship OpenSSL 1.1.1
   (`libssl.so.1.1`). TLS builds from the container will fail to start on those hosts. TLS is **off by default** for
   aarch64; use `build-native.sh --tls yes` on the target host instead.
3. **Kunpeng 920** — optional `CFLAGS="-march=armv8-a+crc"` if you want explicit hardware-CRC usage.
4. **`ARM64-COW-BUG` on startup** — if `transparent_hugepage/enabled` is `always`, Redis refuses to
   start on aarch64 to avoid data corruption. Set THP to `madvise`/`never`, or add
   `ignore-warnings ARM64-COW-BUG` to `redis.conf`. The smoke test passes that flag automatically
   on aarch64 so builds don't fail on this host-level condition.

## Release semantics

| Trigger | Builds | Release |
|---|---|---|
| push to `main` / `master` | default version (both arches) | `latest` (rolling) |
| tag `vRedis-x.y.z` | that version only | tag-named release (frozen) |
| manual dispatch | any version/allocator/arch | `vRedis-{version}` |

## Upgrade procedure

> ⚠️ **Redis has no `kill -USR2`-style hot binary upgrade.** Replacing the binary requires restarting the
> process. Always back up `dump.rdb` / `appendonlydir/` and `redis.conf` first.

**Step 0 — validate config compatibility across major versions.** Redis 7 renamed the `*-ziplist-*`
directives to `*-listpack-*`; old names make the new process fail to start. Since Redis has no
`nginx -t`, validate by starting a temporary instance on a spare port and reading its log.

Then: **standalone** → stop, swap binaries, start. **Replica/Sentinel/Cluster** → roll replicas first,
then fail over and upgrade the former primaries one node at a time.

**Downgrade caveat:** Redis 7.x uses multi-part AOF (`appendonlydir/`). Rolling back to 6.x requires
disabling AOF / restoring from RDB first.

## Smoke tests

Every build automatically runs: `redis-server --version`, max `GLIBC_*` symbol version (`objdump -T`),
`ldd`, and a **real instance start + `PING` → `PONG`**. Results land in `BUILD-INFO.txt` inside the artifact directory.

## License

[MIT](LICENSE) © JackCh3n

> This repository contains build scripts only — **no Redis source code**. Built artifacts are subject to
> the license of the corresponding Redis version.
