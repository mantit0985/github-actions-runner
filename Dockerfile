# Thin-layer runner image (consume-first ruling, 2026-10-22): GitHub ships the
# official runner image `ghcr.io/actions/actions-runner` — the runner artifact,
# the pinned toolchains and the vendored npm tree are upstream content now, and
# the entire pinned-toolchain fetch stage is retired. This layer adds only the
# fleet's own entrypoint: the github-app per-start registration script.
FROM ghcr.io/actions/actions-runner:latest AS runtime-slim

LABEL org.opencontainers.image.title="github-actions-runner" \
      org.opencontainers.image.description="Self-hosted GitHub Actions runner with the github-app per-start registration entrypoint" \
      org.opencontainers.image.source="https://github.com/mantit0985/github-actions-runner" \
      org.opencontainers.image.licenses="MIT"

# Fleet entrypoint: validates, mints the registration token via the installed
# repo-admin GitHub App (RUNNER_TOKEN_SOURCE=github-app, APP_ID env +
# /run/secrets/github-app-key), registers and runs the runner in the
# foreground. Upstream base provides config.sh, node20, bash, curl, jq.
COPY --chown=runner:runner --chmod=0750 run.sh /home/runner/run.sh

# The upstream base keeps the runner's bundled node off PATH; run.sh's
# github-app JWT mint invokes `node` bare, so expose the bundled node20.
ENV PATH="/home/runner/externals/node20/bin:${PATH}"

# The hub CI gate installs its SCA/SAST tooling with pip inside the runner
# environment, but the upstream base ships python3 without pip (run 39732376825:
# "pip: command not found", exit 127). Add the pinned pip package to our thin
# layer so the gate tooling installs as before.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-pip=24.0+dfsg-1ubuntu1.3 \
 && rm -rf /var/lib/apt/lists/*
USER runner

# Deploy contract (hub CD matrix): the three target tags are aliases of the
# same thin layer — the upstream base defines the whole runtime surface, so
# alpine/distroless have no separate content here; they exist so
# `--target <name>` resolves for each leg of the 6-tag deploy contract.
FROM runtime-slim AS runtime-alpine
FROM runtime-slim AS runtime-distroless

ENTRYPOINT ["/home/runner/run.sh"]