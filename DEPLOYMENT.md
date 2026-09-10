# Deployment

The proxy ships as **one image running two processes**: `proxy.ts` on bun (port
1435) and `chatgpt-http-helper.py` on curl_cffi (port 1436). The provider talks
to the helper over `127.0.0.1:1436`, so the two cannot be split into separate
containers — `.docker/docker-entrypoint.sh` starts the helper, waits for its
`/health`, then runs the proxy in the foreground.

There is no database and no broker. All state — the session cookie jar
(`.cookies.json`) and generated images — lives in `/data`, backed by a named
volume, because losing it forces a full chatgpt.com handshake on every restart.

One branch, one environment: `main` → **prod**. On the deploy host the container
joins `hoatheomua-network-dev` and `hoatheomua-network-prod`, the two networks
owned by hoatheomua-be, so either API environment can call the proxy at
`http://chatgpt-proxy-prod:1435/v1` without going through the published port.

## Prerequisites

1. Docker and Docker Compose
2. An env file with the ChatGPT credentials — copy `.docker/.env.example` to
   `.docker/.env` and fill in `CHATGPT_COOKIES` and `CHATGPT_ACCESS_TOKEN`

## Quick Start (local)

```bash
docker compose -f .docker/docker-compose.yml --env-file .docker/.env up -d --build
curl -s http://127.0.0.1:${HTTP_PORT:-1435}/health | jq
```

`providers.chatgpt.enabled` must be `true`; if it is `false`, `CHATGPT_COOKIES`
never reached the container.

`.docker/docker-compose.yml` builds from source on its own network — use it on a
machine that has no hoatheomua-be stack.

## Profile-Based Compose (the deploy host)

`.docker/compose.yaml` is what CI/CD runs. It pulls the published image and
attaches to the two shared networks, which must already exist:

```bash
docker network create hoatheomua-network-dev   # if hoatheomua-be has not created it
docker network create hoatheomua-network-prod

docker compose -f .docker/compose.yaml --profile prod up -d
```

The deploy workflow creates both networks idempotently before `up`, so a fresh
host does not need this by hand.

### Profiles

| Profile | Contains |
| --- | --- |
| `prod` | the proxy container |
| `api-prod` / `api` | same service, named for symmetry with hoatheomua-be |
| `prod-pull` | what CI pulls before `up -d` |

## Build Images

```bash
docker compose -f .docker/compose.yaml --profile prod build

# Ignore the cache (needed after changing requirements.txt)
docker compose -f .docker/compose.yaml --profile prod build --no-cache
```

## View Logs

```bash
docker compose -f .docker/compose.yaml --profile prod logs -f
docker compose -f .docker/compose.yaml --profile prod logs --tail=100
```

Both processes log to the same stream: helper lines are prefixed
`[http-helper]`, proxy lines `[toolcall-proxy]` / `[chatgpt]`.

## Stop / Restart

```bash
docker compose -f .docker/compose.yaml --profile prod down

# ⚠️ Also drops the cookie jar and every generated image
docker compose -f .docker/compose.yaml --profile prod down -v

docker compose -f .docker/compose.yaml --profile prod restart
```

`down` leaves the two shared networks alone — they are external and belong to
hoatheomua-be.

## Common Workflows

### 1. Fresh start:

```bash
docker compose -f .docker/compose.yaml --profile prod down -v
docker compose -f .docker/compose.yaml --profile prod build
docker compose -f .docker/compose.yaml --profile prod up -d
docker compose -f .docker/compose.yaml --profile prod logs -f
```

### 2. Rotate the ChatGPT access token (~every 10 days):

The token is an RS256 JWT and the helper reports the remaining lifetime at
startup. It is configuration, not code — no rebuild is needed.

```bash
# 1. Update CHATGPT_ACCESS_TOKEN in .docker/.env
# 2. Recreate the container with the new value
docker compose -f .docker/compose.yaml --profile prod up -d --force-recreate
# 3. For the deployed host: push the secret, then re-run the deploy workflow
./.docker/sync-env-secrets.sh
```

### 3. Inspect the persisted state:

```bash
docker exec chatgpt-proxy-prod ls -la /data /data/.generated_images
docker exec chatgpt-proxy-prod cat /data/.cookies.json | jq 'keys'
```

### 4. Check it is reachable from the hoatheomua containers:

```bash
docker exec hoatheomua-api-prod curl -s http://chatgpt-proxy-prod:1435/health
docker exec hoatheomua-api-dev  curl -s http://chatgpt-proxy-prod:1435/health
```

### 5. Clean everything:

```bash
docker compose -f .docker/compose.yaml --profile prod down -v
docker image prune -a
```

## Environment Variables

See `.docker/.env.example`. The ones that matter:

| Variable | Notes |
| --- | --- |
| `HTTP_PORT` | Host port; the container always listens on 1435 |
| `CHATGPT_COOKIES` | From DevTools > Application > Cookies; must include `__Secure-next-auth.session-token` |
| `CHATGPT_ACCESS_TOKEN` | From the `authorization` header on any `/backend-api/` request; ~10-day lifetime |
| `CHATGPT_FILES_BASE` | Public URL used in the `/files/` links returned with generated images — the URL clients actually use, not `127.0.0.1` |
| `CHATGPT_NEVER_STORE` | `1` keeps every chat temporary (nothing stored on the account) and disables image generation |
| `UPSTREAM_URL` / `UPSTREAM_KEY` | Backend for models that are not `chatgpt/*`; optional |
| `REGISTRY` / `TAG` | Computed by CI; set them by hand only when pulling images locally |
| `DISCORD_CI_WEBHOOK_URL` | Repository secret for the CI/CD notification job |

Container-only variables set by the compose files, not by the env file:
`HOST=0.0.0.0` (proxy.ts defaults to `127.0.0.1`, unreachable from outside the
container) and `CHATGPT_DATA_DIR=/data` (moves the cookie jar and image folder
off the source tree onto the volume).

## CI/CD

`.github/workflows/main.yaml` runs on every push to `main`:

1. **Build / Proxy** — bundles the TypeScript, syntax-checks the Python helper,
   then builds and pushes `ghcr.io/<repo>/chatgpt-proxy:prod-latest`.
2. **Deploy / Prod / Proxy** — on the self-hosted runner: ensure the two shared
   networks exist, pull the tag, `up -d` the `prod` profile, poll `/health`
   until the proxy answers, prune old images.
3. **Notify / Discord** — posts the outcome when `DISCORD_CI_WEBHOOK_URL` is set.

The deploy job reads its configuration from the GitHub *environment* `prod` via
`secrets: inherit`. Create it and push the secrets from a local env file with:

```bash
./.docker/sync-env-secrets.sh
```

The script pins `prod` to `main` and skips `REGISTRY` / `TAG`, which CI computes
itself.

## Troubleshooting

### Check if the container is running and healthy:

```bash
docker ps | grep chatgpt-proxy
docker inspect --format '{{.State.Health.Status}}' chatgpt-proxy-prod
```

### `network hoatheomua-network-prod declared as external, but could not be found`

The hoatheomua-be stack has not created it on this host yet:

```bash
docker network create hoatheomua-network-prod
```

### `providers.chatgpt.enabled: false` in /health

`CHATGPT_COOKIES` is empty in the container. Confirm the env file was passed
(`--env-file`) and the value is a single unquoted line:

```bash
docker exec chatgpt-proxy-prod printenv CHATGPT_COOKIES | head -c 80
```

### Requests fail with an auth error

The access token has expired — the helper prints the remaining hours at startup.
Rotate it as in workflow 2 above.

```bash
docker logs chatgpt-proxy-prod 2>&1 | grep -i "access token"
```

### The helper dies and takes the container with it

That is intentional: the entrypoint exits when either process stops so the
restart policy recycles a container rather than leaving a half-dead one.

```bash
docker logs chatgpt-proxy-prod --tail 100 | grep '\[http-helper\]'
```

### Generated image links point at the wrong host

Set `CHATGPT_FILES_BASE` to the URL clients actually use; the helper embeds it
verbatim in the markdown links it returns.
