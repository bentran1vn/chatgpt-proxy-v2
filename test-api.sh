#!/bin/bash
# Smoke tests for the proxy. Assumes ./start.sh is already running.
#
#   ./test-api.sh          run everything
#   ./test-api.sh 3 6      run only tests 3 and 6
#
# Tests that spend real ChatGPT quota are marked [quota]; image generation also
# briefly leaves temporary-chat mode. Nothing here writes to the repo except
# scratch files under /tmp.

cd "$(dirname "$0")"

PROXY=${PROXY:-http://127.0.0.1:1435}
HELPER=${HELPER:-http://127.0.0.1:1436}
PY=${PY:-.venv/bin/python}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "$FILESRV" ] && kill "$FILESRV" 2>/dev/null' EXIT

[ -x "$PY" ] || PY=python3

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
pass=0; fail=0; skip=0
WANT=("$@")

want() {                       # want <n> -> should this test run?
  [ ${#WANT[@]} -eq 0 ] && return 0
  for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

head_() { printf '\n%s%s. %s%s\n' "$DIM" "$1" "$2" "$OFF"; }
ok()    { printf '   %s✓%s %s\n' "$GRN" "$OFF" "$1"; pass=$((pass+1)); }
no()    { printf '   %s✗%s %s\n' "$RED" "$OFF" "$1"; fail=$((fail+1)); }
note()  { printf '   %s%s%s\n' "$DIM" "$1" "$OFF"; }
warn()  { printf '   %s!%s %s\n' "$YEL" "$OFF" "$1"; skip=$((skip+1)); }

# chat <json-body> -> prints assistant content, or "ERR: ..." on failure
chat() {
  printf '%s' "$1" > "$TMP/req.json"
  curl -s --max-time 300 "$PROXY/v1/chat/completions" \
       -H 'Content-Type: application/json' --data-binary @"$TMP/req.json" \
  | $PY -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("ERR: no JSON"); sys.exit()
if "choices" in d: print((d["choices"][0]["message"].get("content") or "").strip())
else: print("ERR:", json.dumps(d)[:300])'
}

# ── test images, built without Pillow ───────────────────────────────────────
$PY - "$TMP" <<'PY'
import sys, zlib, struct, base64, pathlib
out = pathlib.Path(sys.argv[1])
def png(w, h, fn):
    rows = [b'\x00' + b''.join(bytes(fn(x, y)) for x in range(w)) for y in range(h)]
    def c(t, d):
        x = t + d
        return struct.pack('>I', len(d)) + x + struct.pack('>I', zlib.crc32(x))
    return (b'\x89PNG\r\n\x1a\n'
            + c(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + c(b'IDAT', zlib.compress(b''.join(rows))) + c(b'IEND', b''))

halves = png(512, 256, lambda x, y: (255, 0, 0) if x < 256 else (0, 128, 0))
(out / 'halves.png').write_bytes(halves)
(out / 'halves.b64').write_text(base64.b64encode(halves).decode())
PY
B64=$(cat "$TMP/halves.b64")

# ═══════════════════════════════════════════════════════════════════════════
if want 1; then
head_ 1 "Health"
  s=$(curl -s --max-time 10 "$PROXY/health" | $PY -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["providers"]["chatgpt"]["enabled"])' 2>/dev/null)
  [ "$s" = "ok True" ] && ok "proxy up, chatgpt enabled" || no "proxy: ${s:-unreachable}"
  t=$(curl -s --max-time 10 "$HELPER/health" | $PY -c 'import json,sys; d=json.load(sys.stdin); print(d["has_token"], d["session_cookies"])' 2>/dev/null)
  case "$t" in
    True*) ok "helper up, token loaded, ${t#True } cookies" ;;
    *)     no "helper: ${t:-unreachable} — check CHATGPT_ACCESS_TOKEN in .env" ;;
  esac
fi

if want 2; then
head_ 2 "Model list"
  n=$(curl -s --max-time 15 "$PROXY/v1/models" | $PY -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))' 2>/dev/null)
  [ "${n:-0}" -gt 10 ] 2>/dev/null && ok "$n models exposed" || no "got ${n:-nothing}"
fi

if want 3; then
head_ 3 "Chat, non-streaming [quota]"
  r=$(chat '{"model":"chatgpt/gpt-5.6","messages":[{"role":"user","content":"Reply with exactly: PONG"}]}')
  case "$r" in
    ERR:*) no "$r" ;;
    *PONG*) ok "got PONG" ;;
    "") no "empty reply — SSE parser may be broken again" ;;
    *) warn "unexpected: ${r:0:80}" ;;
  esac
fi

if want 4; then
head_ 4 "Chat, streaming [quota]"
  c=$(curl -s --max-time 300 "$PROXY/v1/chat/completions" -H 'Content-Type: application/json' \
      -d '{"model":"chatgpt/gpt-5.6","stream":true,"messages":[{"role":"user","content":"Count 1 to 5"}]}' \
      | grep -c '^data: ')
  [ "${c:-0}" -ge 3 ] && ok "$c SSE chunks" || no "only ${c:-0} chunks"
fi

if want 5; then
head_ 5 "Thinking model [quota]"
  r=$(chat '{"model":"chatgpt/gpt-5.6-thinking","messages":[{"role":"user","content":"17*23=? Digits only."}]}')
  case "$r" in *391*) ok "correct (391)" ;; ERR:*) no "$r" ;; *) warn "got: ${r:0:80}" ;; esac
fi

if want 6; then
head_ 6 "Vision — data URI [quota]"
  r=$(chat "{\"model\":\"chatgpt/gpt-5.6\",\"messages\":[{\"role\":\"user\",\"content\":[
        {\"type\":\"text\",\"text\":\"Left half and right half of this image: what colours? Answer in under 10 words.\"},
        {\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,$B64\"}}]}]}")
  lower=$(printf '%s' "$r" | tr 'A-Z' 'a-z')
  case "$lower" in
    err:*) no "$r" ;;
    *red*green*|*green*red*|*đỏ*xanh*|*xanh*đỏ*) ok "both colours seen: ${r:0:70}" ;;
    *) no "image not understood: ${r:0:100}" ;;
  esac
fi

if want 7; then
head_ 7 "Vision — http URL [quota]"
  # A separate static server: never point this at $PROXY/files/, the helper is
  # single-threaded and fetching from itself deadlocks it.
  ($PY -m http.server 1799 --bind 127.0.0.1 --directory "$TMP" >/dev/null 2>&1) &
  FILESRV=$!
  sleep 2
  if curl -s --max-time 5 -o /dev/null "http://127.0.0.1:1799/halves.png"; then
    r=$(chat '{"model":"chatgpt/gpt-5.6","messages":[{"role":"user","content":[
          {"type":"text","text":"Left half and right half: what colours? Under 10 words."},
          {"type":"image_url","image_url":{"url":"http://127.0.0.1:1799/halves.png"}}]}]}')
    lower=$(printf '%s' "$r" | tr 'A-Z' 'a-z')
    case "$lower" in
      err:*) no "$r" ;;
      *red*green*|*green*red*|*đỏ*xanh*|*xanh*đỏ*) ok "fetched and understood: ${r:0:70}" ;;
      *) no "not understood: ${r:0:100}" ;;
    esac
  else
    warn "could not start local file server on 1799"
  fi
  { kill $FILESRV; wait $FILESRV; } 2>/dev/null; FILESRV=
fi

if want 8; then
head_ 8 "Image generation [quota] — 30-45s, leaves temporary chat"
  r=$(chat '{"model":"chatgpt/gpt-5.6","messages":[{"role":"user","content":"Vẽ một hình tròn màu xanh trên nền trắng."}]}')
  url=$(printf '%s' "$r" | sed -n 's/.*(\(http[^)]*\)).*/\1/p' | head -1)
  if [ -n "$url" ]; then
    ok "markdown link returned"
    code=$(curl -s -o "$TMP/gen.png" -w '%{http_code}' --max-time 60 "$url")
    sz=$(wc -c < "$TMP/gen.png" | tr -d ' ')
    magic=$(head -c 8 "$TMP/gen.png" | od -An -tx1 | tr -d ' \n')
    if [ "$code" = 200 ] && [ "${magic:0:16}" = "89504e470d0a1a0a" ]; then
      ok "downloaded a real PNG ($sz bytes)"
    else
      no "download failed: HTTP $code, $sz bytes"
    fi
  else
    no "no image link: ${r:0:150}"
  fi
fi

if want 9; then
head_ 9 "File serving and path traversal"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$HELPER/files/does-not-exist.png")
  [ "$code" = 404 ] && ok "missing file -> 404" || no "missing file -> $code"
  bad=0
  for p in "%2e%2e%2f%2e%2e%2fetc%2fpasswd" "..%2f..%2fetc%2fpasswd" "....//....//etc/passwd"; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --path-as-is "$HELPER/files/$p")
    [ "$c" = 404 ] || bad=1
  done
  [ $bad -eq 0 ] && ok "traversal attempts all rejected" || no "a traversal attempt was not rejected"
fi

if want 10; then
head_ 10 "No conversations left behind"
  out=$($PY - <<'PY' 2>/dev/null
import io, importlib.util, datetime, contextlib
spec = importlib.util.spec_from_file_location('h', 'chatgpt-http-helper.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
# The helper narrates its startup on stdout; keep it out of the report.
with contextlib.redirect_stdout(io.StringIO()):
    h.init_session(); tok = h.refresh_access_token()
H = {**h.base_headers(), 'Authorization': f'Bearer {tok}'}
r = h.session.get(f'{h.CHATGPT_BASE}/backend-api/conversations?offset=0&limit=20',
                  headers=H, timeout=30)
cut = (datetime.datetime.now(datetime.timezone.utc)
       - datetime.timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M')
recent = [i for i in r.json().get('items', []) if i.get('create_time', '') > cut]
print(len(recent))
for i in recent[:5]:
    print('  -', i.get('title'))
PY
)
  n=$(printf '%s' "$out" | head -1)
  if [ "${n:-x}" = "0" ]; then
    ok "nothing from the last 30 minutes"
  elif [ -n "$n" ]; then
    no "$n recent conversation(s) survived:"; printf '%s\n' "$out" | tail -n +2
  else
    warn "could not check (token expired?)"
  fi
fi

printf '\n%s%d passed%s' "$GRN" "$pass" "$OFF"
[ $fail -gt 0 ] && printf ', %s%d failed%s' "$RED" "$fail" "$OFF"
[ $skip -gt 0 ] && printf ', %s%d skipped%s' "$YEL" "$skip" "$OFF"
printf '\n\n'
exit $((fail > 0))
