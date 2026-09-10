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
   ```
4. **Test the build locally** if you have Docker:
   ```bash
   ./build.sh image
   ./build.sh build 7.2.16
   ```
5. **Commit** with a clear message and open a **Pull Request**.

## Versioning conventions

- **Mainline** (`main`/`master`): rolling changes, published to the `latest` release automatically.
- **Stable** (`vRedis-*` tags): frozen releases for production use.
- When bumping the default Redis version, update **all** of:
  `build.sh`, `.github/workflows/build.yml`, `.cnb.yml`, `README.md`.
- Default version policy: keep the default on the **last BSD-3-Clause release** (currently `7.2.16`)
  unless there is a deliberate reason to move — many regulated environments cannot accept
  RSALv2 / SSPLv1 / AGPLv3 terms.

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

## CI notes

- GitHub Actions and CNB pipelines must stay in sync for the **default version** — change both
  together. CNB builds x86_64 only; aarch64 is produced by GitHub Actions (or `build-native.sh`).
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
