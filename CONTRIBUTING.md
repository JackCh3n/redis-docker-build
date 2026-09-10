# Contributing to redis-docker-build

Thanks for taking the time to contribute! 🎉

## Development workflow

1. **Fork** the repository and create a feature branch:
   ```bash
   git checkout -b feat/your-feature
   ```
2. **Make your changes** — keep them focused and well-documented.
3. **Syntax-check** shell scripts:
   ```bash
   bash -n build-redis.sh
   bash -n build.sh
   bash -n build-native.sh
   bash -n install.sh
   ```
4. **Test the build locally** if you have Docker:
   ```bash
   ./build.sh image
   ./build.sh build 8.10.1
   ```
5. **Commit** with a clear message and open a **Pull Request**.

## Branching & versioning conventions

This repo keeps **one branch per Redis major line** (their build systems diverge sharply):

| Branch | Redis line | Default version | License | Rolling release |
|---|---|---|---|---|
| `main` | 8.x | `8.10.1` | RSALv2 / SSPLv1 / AGPLv3 | `latest` |
| `7.x` | 7.x | `7.2.16` | BSD-3-Clause | `latest-7.x` |

- CI triggers are **branch-local**: each branch's `.cnb.yml` / workflow only listens to its own
  branch (`main` listens to `main`/`master`, `7.x` listens to `7.x`), so the two lines never
  trigger each other.
- **Mainline**: rolling changes on the branch, published to that branch's rolling release tag.
- **Stable** (`vRedis-*` tags): frozen releases for production, identical tag naming on both lines.
- When bumping the default Redis version on a branch, update **all** of:
  `build.sh`, `.github/workflows/build.yml`, `.cnb.yml`, `README.md`.
- Default version policy: the **`main` branch deliberately defaults to the latest 8.x** (`8.10.1`);
  the **`7.x` branch stays on the last BSD-3-Clause release** (`7.2.16`) because many regulated
  environments cannot accept RSALv2 / SSPLv1 / AGPLv3 terms.

## Redis 8.10+ build system (important for the 8.x line)

Redis 8.10 rewrote the top-level `Makefile`:

- `make` (default goal) runs `scripts/build.sh`, which builds **every module cloned under
  `modules/*/src`**. The official source tarball (`redis-<ver>.tar.gz` from download.redis.io)
  **ships those module sources**, so a bare `make` would try to build the Query Engine,
  vector-sets, etc.
- Those modules need **LLVM 21 + Rust 1.94 + CMake 3.25–3.31.6** — impossible on the glibc 2.17
  toolchain this project targets.
- Therefore `build-redis.sh` pins **core-only** for `>= 8.10` by invoking `make build redis`
  (and refuses `--modules yes` with an explanatory error).
- The tarball also ships pre-generated `src/commands.def` / `src/fmtargs.h`. Since the generators
  are python3-only while CentOS 7 ships python2, `build-redis.sh` sets `PYTHON=` when `python3`
  is absent, so `make` uses the shipped files instead of trying to regenerate them.

## License compliance (must keep)

Upstream Redis licensing changed over time — **7.2.x and earlier = BSD-3-Clause**,
**7.4–7.8 = RSALv2/SSPLv1**, **8.0+ = RSALv2/SSPLv1/AGPLv3**. All variants forbid removing
license notices, so **every distributed tarball must carry the upstream license text**:

- `build-redis.sh` copies the in-tree `LICENSE.txt` (8.x) / `COPYING` (7.x) to
  `LICENSE.redis.txt` inside the package directory.
- The bundling step (`bundle-installer` in `.cnb.yml`, "装入 install.sh 与 assets" in the
  GitHub workflow, `bundle_and_package` in `build.sh`) adds this project's own `LICENSE`.
- When adding a new build path, keep both files in the tarball.

## Architecture notes

- `Dockerfile` serves **both** architectures via `--build-arg BASE_IMAGE`:
  - x86_64 → `centos:7.6.1810` (vault path `7.6.1810`)
  - aarch64 → `arm64v8/centos:7` (vault path `altarch/7`)
  The `VAULT_PREFIX` build arg is auto-derived when left empty. Keep this in sync if you
  change the base image.
- CentOS 7 is EOL; `vault.centos.org` is unreachable from many networks. Use a domestic
  archive mirror (`OS_MIRROR`) rather than hardcoding vault.centos.org.
- devtoolset is required because Redis ≥ 6.0 needs C11 atomics; `devtoolset-11` has no
  aarch64 archive, so `devtoolset-10` is the default (overridable).
- The devtoolset repo **must** point at the CDN host `buildlogs.cdn.centos.org`, not the
  origin `buildlogs.centos.org`. The origin 302-redirects RPM requests to the CDN, and
  CentOS 7's yum does not follow 302 → `HTTP Error 302 - Found` / `No more mirrors to try`.
  The redirect is intermittent, which makes this a hard-to-reproduce failure. Keep
  `DEVTOOLSET_MIRROR` (CDN) + `DEVTOOLSET_MIRROR_FALLBACK` and the retry loop intact.

## Installer (`install.sh`) notes

- The installer is **strictly offline**: no network calls, no `curl`/`wget` dependency. It works on
  whatever package / tarball is already on disk. Do not add download logic.
- Keep it **bash 4.2** compatible (CentOS 7) — no `mapfile`, no `${var,,}`, no associative arrays.
- Version gating order (must stay this way):
  not installed → install; pkg > installed → update; pkg == installed → skip (call out a differing
  build hash); pkg < installed → **refuse** unless `--force`.
- Preserve **symlinks** when installing — `redis-check-aof` / `redis-check-rdb` / `redis-sentinel`
  are symlinks to `redis-server`; dereferencing them bloats the install ~5×.
- Back up the old binaries (`/var/backups/redis-<timestamp>/`) before overwriting, and never
  overwrite an existing `/etc/redis/redis.conf`.
- Detect the package by **content** (`redis-server` + `BUILD-INFO.txt`), not by the presence of the
  exec bit — some filesystems lose it, and `install -m 0755` fixes it anyway.

## CI notes

- GitHub Actions and CNB pipelines must stay in sync for the **default version** — change both
  together. Both now produce **x86_64 + aarch64**.
- **CNB is a two-pipeline setup.** `runner` (tags/cpus) can only be set at the
  **pipeline** level, so `.cnb.yml` defines two parallel pipelines per trigger
  (`cnb:arch:amd64` + `cnb:arch:arm64:v8`) that **share one stage list** via a YAML anchor.
  aarch64 uses CNB's native ARM nodes — no QEMU.
- **Publishing must stay idempotent and race-safe.** Both arch pipelines publish into the *same*
  release, so `ensure-release` does GET-then-create, tolerates `409/422` (the other pipeline won
  the race) and PATCHes an existing release instead of recreating it. Upload only globs the
  local `dist/`, so the two arches never overwrite each other.
- CNB API calls need `Accept: application/vnd.cnb.api+json` on GET/POST/PATCH (Content-Type alone
  returns 406). Do not introduce raw `\n` inside a JSON body — escape it (see `ensure-release`).
- The GitHub release job requires `contents: write`; CNB needs `CNB_TOKEN` (already in the env).
- The tarballs must stay **self-contained**: the packaging step copies `install.sh`,
  `assets/redis.service` and `assets/redis.conf.example` into each `dist/<pkg>/` before `tar`.
  If you add a new asset file, add it to all three packagers (`.cnb.yml`, `build.yml`, `build.sh`).
- Release titles must be **English**; notes use `--notes-file` (a plain `\n` passed to `--notes`
  is treated literally).
- The in-container smoke test (start instance → `PING` → expect `PONG`) must pass; a failing
  smoke test fails the build on purpose.

## Reporting issues

Open an issue with:
- Target environment (`uname -m`, `cat /etc/os-release` or `cat /etc/.productinfo`, `getconf PAGESIZE`)
- The exact command that failed
- Full error output (log snippet), plus `dist/*/BUILD-INFO.txt` if the artifact was produced

Thank you for helping make this project better!
