# Deploying the runner with docker compose (local host-bound)

`compose.yml` is the deployment type for **local, host-bound deployments**: one
host, plain `docker compose`, no Swarm. The Swarm contract lives in
[`docker-stack.md`](docker-stack.md) — do not use this file for Swarm.

## What compose.yml gives you

- `gh-runner` service from the proven released image
  `ghcr.io/mantit0985/github-actions-runner:latest-runtime-slim`
- `env_file: .env` — all local configuration lives in your `.env` file
  (`REPO_URL`, `RUNNER_TOKEN`, `RUNNER_NAME`, `RUNNER_LABELS`)
- `${VAR:-default}` interpolation for `RUNNER_MODE`, `RUNNER_TOKEN_SOURCE`,
  `RUNNER_TOKEN_FILE`, `IDLE_EXIT_SECONDS`
- `container_name/hostname: github-actions-runner`
- docker-init as PID 1, `restart: always`, 30s stop grace (drain on SIGTERM)
- persistent `runner-data` volume (registration survives restarts)
- `/var/run/docker.sock` bind — **root-equivalent access**; remove it if your
  workflows never build Docker images

## Steps: up and running

1. Get the repo (clone or copy) locally on the target host.
2. Create your env file and fill in the two required values:

   ```sh
   cp .env.example .env
   # REPO_URL=https://github.com/<owner>/<repo>
   # RUNNER_TOKEN=<fresh registration token>
   ```

   Mint a fresh registration token beforehand (GitHub: repo → Settings →
   Actions → Runners → New self-hosted runner; the token expires in one hour),
   or via the fleet minter if you have it:
   `MINT_RAW=1 .../self-hosted-runner-token-mint <owner>/<repo>`.
3. Bring it up:

   ```sh
   docker compose -f compose.yml up -d
   ```

4. Verify it registered:

   ```sh
   docker logs github-actions-runner
   ```

   Expect "Connected to GitHub" and "Listening for Jobs"; the repo's
   **Settings → Actions → Runners** page shows the runner online.
5. Leave it running — restarts reuse the stored registration; no new token
   is burned on restart.

## Editing compose.yml safely (idiot-proof guide)

Read this whole section before editing anything. Rules first:

1. **Touch only what you understand.** The safe-to-edit fields are:
   - `environment:` interpolation defaults (the `:-default` right-hand sides) —
     changing a default changes local behavior only.
   - `stop_grace_period` / `restart` policy levels.
   - `env_file` list — only if you know what you're adding files.
2. **Never edit without a reason:**
   - `image:` — the tag is the released scheme (`latest-runtime-slim` and the
     12-tag family). Pointing it at something that doesn't exist produces a
     pull-denied crash loop that looks like an auth bug but isn't.
   - `/var/run/docker.sock` bind — removing it silently breaks every workflow
     that builds images. If you remove it, remove docker-building jobs too.
   - `init: true` — docker-init is PID1/zombie handling; jobs spawn many
     short-lived processes.
3. **Env values come from `.env`, not from compose.yml.** `REPO_URL`,
   `RUNNER_TOKEN`, `RUNNER_NAME`, `RUNNER_LABELS` are NOT in the file's
   `environment:` block on purpose (env_file injects them). To change one,
   edit your `.env` — NOT compose.yml (which has no value to change).
4. **Indentation is 2 spaces, YAML strict.** `run.sh` fails at the smallest
   indent slip; validate every save before applying.
5. **Validate BEFORE `up`** (order matters: `.env` must exist first, or the
   validation itself errors):

   ```sh
   cp .env.example .env && nano .env   # fill REPO_URL + RUNNER_TOKEN
   docker compose -f compose.yml config --quiet
   ```

   Empty output + exit 0 = valid. Any message = read it; the file is wrong.
6. **Name collisions:** a service/container name that already exists in the
   swarm (`t0_runner_...` ghosts) makes `up` fail with a name conflict —
   remove the old object first; don't rename around it.

## Teardown / upgrades

- Stop and drop everything: `docker compose -f compose.yml down -v`
- After upgrading the image, recreate the volume (the stored registration
  binds to the old image's runner state): `down -v` then `up -d` with a
  fresh registration token.
