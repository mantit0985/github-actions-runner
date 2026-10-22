# GitHub Actions Runner — Service Starter Guide

![CI](https://github.com/mantit0985/github-actions-runner/actions/workflows/CI.yml/badge.svg) ![CD](https://github.com/mantit0985/github-actions-runner/actions/workflows/CD.yml/badge.svg) ![Version](https://img.shields.io/badge/version-0.1.0-blue) ![License](https://img.shields.io/github/license/mantit0985/github-actions-runner)

A production-grade, reusable image for self-hosted GitHub Actions runners. The container registers itself with GitHub on first start, runs as an unprivileged `runner` user, and ships with the build toolchains CI jobs commonly need:

| Component | Version (pinned in `Dockerfile`) |
|-----------|----------------------------------------|
| GitHub Actions Runner | 2.338.0 |
| C/C++ (GCC 13, Make), CMake, Ninja, autotools | Ubuntu 24.04 toolset |
| Rust (rustup, incl. rustfmt + clippy) | 1.99.0 |
| Go | 1.27.2 |
| Zig | 0.17.0 |
| Node.js (LTS) incl. npm + pnpm | 24.21.0 |
| Python incl. dev headers, pip, venv | 3.12 |
| ARM embedded cross-compiler (`arm-none-eabi`, incl. C++ via newlib) | Ubuntu 24.04 toolset |
| Docker CLI (for bind-mounted Docker socket) | Docker CE |

Every download is version-pinned and SHA-256-verified at build time. The image is built for `linux/amd64` and `linux/arm64`; each toolchain is resolved to the correct platform automatically.

## Deployment

One deployment type is documented — its working steps, engine caveats and
pitfalls live in a dedicated document; this README does not duplicate them:

| Type | Scope | Document |
|------|-------|----------|
| `docker compose` | local, host-bound (one host, no Swarm) | [`docs/docker-compose.md`](docs/docker-compose.md) |

Both register the container with GitHub on first start; registration tokens
expire one hour after issue, so generate one immediately beforehand.

## Configuration

| Variable | Description | Required |
|----------|-------------|----------|
| `REPO_URL` | Target GitHub repository or organization URL (`https://...`) | First start only |
| `RUNNER_TOKEN` | Registration token from GitHub Actions settings | First start only |
| `RUNNER_LABELS` | Comma-separated custom labels (default: `self-hosted`) | No |
| `RUNNER_MODE` | Running mode: `ephemeral` or `persistent` | No |
| `RUNNER_TOKEN_SOURCE` | Source of the token: `github-app`, `mint` or `preminted` | No |
| `RUNNER_TOKEN_FILE` | Path to preminted registration token. Default: `/run/secrets/runner-token` | No |
| `RUNNER_PAT_FILE` | Path to fine-grained PAT used when minting. Default: `/run/secrets/runner-pat` | No |
| `APP_ID` | GitHub App ID used when minting via `RUNNER_TOKEN_SOURCE=github-app`. Set at service level | Yes (github-app) |
| `APP_KEY_FILE` | Path to GitHub App private key used when minting via `RUNNER_TOKEN_SOURCE=github-app`. Default: `/run/secrets/github-app-key` | No |
| `IDLE_EXIT_SECONDS` | Seconds runner will keep alive idle before exiting. Default: `900` | No |

## Credential constraints

- Current fast path (RUNNER_TOKEN_SOURCE=preminted): a REGISTRATION token (≈1h validity) minted by operators/agents via the GitHub API and injected as the docker swarm secret `runner-token`; the runner consumes it at start, registers; expiry shows up as a clean failed-rate event and requires a fresh secret.
- Mint path (RUNNER_TOKEN_SOURCE=mint): a fine-grained PAT scoped to ONLY the target repository with the narrowest permission GitHub's registration-token API supports (Administration read/write), short expiry (≤30d), documented rotation; token NEVER persisted in env, volume, image layer, or logs; mint-per-start output is runtime-only.
- Canonical path (RUNNER_TOKEN_SOURCE=github-app): a GitHub App installation — one private key (no expiry), per-repo installation scoping, full audit trail. The App private key arrives as the swarm secret `github-app-key` (read-only file), `APP_ID` comes from env; run.sh signs the App JWT with node crypto, resolves the installation by owner from `REPO_URL`, and mints a fresh registration token at every start. No hourly minter lane.

Labels in this project follow a single standard: base labels mirror Docker platform names (`self-hosted,linux,amd64` on amd64 hosts, `self-hosted,linux,arm64` on arm64 hosts), and toolchain labels use technical toolchain names (e.g. `arm-none-eabi` for the ARM embedded cross-compiler). Note that GitHub separately auto-assigns its own platform labels (`self-hosted`, `linux`, `x64`/`arm64`) — an aligned label set looks like:

```text
self-hosted,linux,amd64,build,cpp,rust,go,zig,nodejs,python,arm-none-eabi
```

Adjust the toolchain labels to what your workflows select on, and drop labels for toolchains you remove in derived images.

## Operations

- **Registration**: handled by `run.sh` on first start with retries; the token is scrubbed from the environment before the runner starts.
- **Graceful shutdown**: `SIGTERM`/`SIGINT` are forwarded to the runner, which finishes in-flight jobs before exiting. The reference deployment allows 30 seconds (`stop_grace_period`) before the container is force-killed.
- **Logs**: `docker logs -f github-actions-runner`.
- **Upgrades**: pull the new image, then `docker compose -f compose.yml down -v` and start again with a fresh registration token. The volume must be recreated so the runner distribution inside it matches the image.
- **CI/CD**: on every push/PR, CI runs the inline gate set (hadolint, shellcheck, image build into the local daemon, semgrep, Trivy scan, runner smoke); CD publishes the image to GHCR after CI succeeds on `main` and on `v*` tags.

## Security Notes

- The runner process and all jobs execute as the unprivileged `runner` user (UID 1000), not as root.
- The image grants the `runner` user passwordless `sudo`, matching GitHub's own runner images so workflow steps can install packages. Remove the `/etc/sudoers.d/runner` rule in a derived image if your workflows must not escalate.
- Mounting `/var/run/docker.sock` gives jobs root-equivalent access to the host. Remove the mount if your workflows do not need to build Docker images.
- Registration tokens are short-lived and repository-scoped; prefer per-repository tokens over org-wide ones.
- Self-hosted runners execute untrusted-by-default workflow code; on public repositories, restrict who can run workflows, or use ephemeral runners.

## Project Structure

- `run.sh` — container entrypoint: validates configuration, registers with retries, scrubs the token, and starts the runner in the foreground.
- `Dockerfile` — two-stage multi-arch image definition; all toolchains version-pinned and checksum-verified.
- `compose.yml` — reference deployment using the published GHCR image.
- `.github/workflows/CI.yml` — inline gate pipeline (lint, build verify, security scan, smoke) on every push and pull request.
- `.github/workflows/CD.yml` — publishes the image to GHCR on merges to `main` and on `v*` tags.
- `.github/workflows/labeler.yml` — PR/issue labeling wrapper on the hub labeler.
- Cloning setup includes `make hooks`, which installs the fleet commit-msg guard (`core.hooksPath .githooks`).

## Building From Source

```bash
docker build -t github-actions-runner:latest -f Dockerfile .
```

Toolchain versions are `ARG` defaults near the top of each stage; override or bump them (and their published SHA-256 checksums) to change what ships in the image.
