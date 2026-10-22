# Changelog

## v0.1.0

### Added

- runner image with SHA-verified pinned toolchains (runner, go, node, zig, rust, pnpm, docker, compose), multiarch
- self-registering run.sh and reference compose
- CD wrapper consuming the hub baseline (6-tag GHCR contract, publish-release mint); inline CI gate set: hadolint, shellcheck, buildx image verify (loaded into the local daemon), semgrep, Trivy image scan, runner smoke
- MIT license and README workflow badges (CI, CD, labeler)

### Verify this release

```bash
sha256sum -c SHA256SUMS
```
