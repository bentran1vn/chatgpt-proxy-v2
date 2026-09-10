#!/usr/bin/env bash
# Container counterpart of start.sh. The host script exists mostly to clear a
# stale helper off port 1436 (pkill/lsof); inside a fresh container nothing is
# ever holding the ports, so this only orders the two processes and makes sure
# the container dies when either of them does.
set -euo pipefail

PORT="${PORT:-1435}"
BRIDGE_PORT="${CHATGPT_BRIDGE_PORT:-1436}"

term() {
  echo "[entrypoint] shutting down..."
  kill "${HELPER_PID:-}" "${PROXY_PID:-}" 2>/dev/null || true
}
trap term TERM INT

echo "[entrypoint] starting ChatGPT HTTP helper on :${BRIDGE_PORT}..."
python3 /app/chatgpt-http-helper.py &
HELPER_PID=$!

# proxy.ts spawns the helper itself if it is missing, but waiting here keeps the
# first request from paying the ~5s warm-up and surfaces credential errors in
# the logs before any traffic arrives.
for _ in $(seq 1 30); do
  if curl -fsS --connect-timeout 2 "http://127.0.0.1:${BRIDGE_PORT}/health" >/dev/null 2>&1; then
    echo "[entrypoint] HTTP helper ready ✓"
    break
  fi
  kill -0 "$HELPER_PID" 2>/dev/null || { echo "[entrypoint] helper exited during startup"; exit 1; }
  sleep 1
done

echo "[entrypoint] starting proxy on ${HOST:-0.0.0.0}:${PORT}..."
bun run /app/proxy.ts &
PROXY_PID=$!

# Exit as soon as either half is gone so the restart policy can recycle the
# container instead of leaving a half-dead one passing as healthy.
while kill -0 "$HELPER_PID" 2>/dev/null && kill -0 "$PROXY_PID" 2>/dev/null; do
  sleep 2
done

echo "[entrypoint] one process exited, stopping the other..."
term
wait || true
exit 1
