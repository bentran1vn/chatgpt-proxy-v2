# toolcall-middleware

<a name="tieng-viet"></a>
**Tiếng Việt** · [English below ↓](#english)

Proxy tương thích OpenAI đặt trước ChatGPT web: gọi các model GPT-5.5 / 5.6 / 6
trên tài khoản ChatGPT Plus hoặc Pro của bạn qua đúng dạng
`/v1/chat/completions` quen thuộc, **gửi ảnh lên được** và **nhận ảnh do model
vẽ về được**. Xác thực bằng cookie phiên cộng access token lấy từ trình duyệt
đã đăng nhập.

Dự án gốc còn kèm phần **giả lập tool calling** cho các backend tương thích
OpenAI khác — nhưng xem mục *Giới hạn đã biết*: phần này **không** chạy với
model ChatGPT.

## Kiến trúc

```
                     Ứng dụng / Agent của bạn
                            │
              /v1/chat/completions, /v1/models, /files/
                            ▼
              ┌─────────────────────────────┐
              │  proxy.ts (Bun, cổng 1435)  │  API tương thích OpenAI
              │  định tuyến theo tên model  │
              └──────────┬───────┬──────────┘
                chatgpt/*│       │model khác
                         ▼       ▼
   ┌──────────────────────────┐ ┌──────────────────┐
   │ chatgpt-http-helper.py   │ │    Upstream      │
   │ cổng 1436, curl_cffi     │ │  (backend tương  │
   │  · TLS Safari + cookie   │ │   thích OpenAI)  │
   │  · giải PoW Sentinel     │ └──────────────────┘
   │  · tải ảnh lên / về      │
   │  · GET /files/<tên>      │
   └────────────┬─────────────┘
                │
                ▼
   chatgpt.com/backend-api
     · /conversation          chat + con trỏ ảnh sinh ra
     · /files                 upload (3 bước) và download
     · /sentinel/…            cổng gác proof-of-work
```

## Tính năng

- **ChatGPT web qua API tương thích OpenAI** — họ GPT-5.5 / 5.6 / 6, các biến
  thể thinking và pro, deep research, agent mode. Hỗ trợ streaming.
- **Gửi ảnh lên** — dùng `image_url` chuẩn OpenAI, nhận `data:` URI hoặc
  `http(s)://`, đẩy lên qua chính luồng file của ChatGPT.
- **Nhận ảnh sinh ra** — yêu cầu vẽ và nhận về link tới file PNG.
- **Mặc định dùng temporary chat** — không lưu gì trên tài khoản, trừ request
  vẽ ảnh buộc phải rời chế độ này; những hội thoại đó bị xoá ngay sau khi đọc
  xong câu trả lời.
- **Xử lý Cloudflare** — giả lập TLS Safari, session `curl_cffi` tự giữ cookie
  luôn mới, tự làm mới và thử lại khi gặp 403, lưu cookie vào `.cookies.json`
  để sống sót qua các lần khởi động lại.
- **Giải Proof of Work** — trả lời thử thách PoW của Sentinel, thường dưới 1ms.
- **Giả lập tool calling** — dạng XML `<tool_call>` cho backend sau
  `UPSTREAM_URL`. Không dùng được với model ChatGPT.

## Yêu cầu

- [Bun](https://bun.sh/) (v1.0+)
- Python 3.10+
- Gói Python `curl_cffi`
- Tài khoản ChatGPT Plus hoặc Pro

## Cài đặt

```bash
git clone https://github.com/zhaefremedia/toolcall-middleware.git
cd toolcall-middleware

bun install

# Virtualenv giữ curl_cffi tách khỏi Python hệ thống. Lệnh `python3` lúc chạy
# phải trỏ đúng vào interpreter có curl_cffi — cả start.sh lẫn provider đều
# gọi `python3` trần.
python3 -m venv .venv
.venv/bin/pip install curl_cffi

cp .env.example .env
```

## Cấu hình

`.env` cần hai credential, đều lấy từ phiên chatgpt.com đã đăng nhập. Mỗi cái
phải nằm trên **một dòng duy nhất** và **không bọc dấu nháy** — helper tự đọc
file này và không bóc nháy giúp bạn.

```env
CHATGPT_COOKIES=_puid=user-xxx;__Secure-next-auth.session-token=eyJhbG...
CHATGPT_ACCESS_TOKEN=eyJhbGciOiJSUzI1NiIs...
```

`UPSTREAM_URL` / `UPSTREAM_KEY` chỉ dùng cho model không phải `chatgpt/*`; nếu
bạn chỉ xài ChatGPT thì cứ để nguyên. Xem `.env.example` cho các tuỳ chọn khác.

## Lấy credential

### Bước 1 — Cookie

Mở DevTools ở tab chatgpt.com, vào **Application** → **Cookies** →
`https://chatgpt.com`.

> **Đừng dùng Console.** `document.cookie` không nhìn thấy cookie `HttpOnly`,
> mà cookie quan trọng nhất lại là `HttpOnly` — copy từ Console sẽ cho bạn một
> chuỗi thiếu và không dùng được, mà không báo lỗi gì.

Cookie bắt buộc là `__Secure-next-auth.session-token`. Khi nó vượt giới hạn 4KB
mỗi cookie, trình duyệt tự cắt thành `__Secure-next-auth.session-token.0` và
`.1` — dán cả hai phần. Các cookie nên có thêm: `_puid`, `oai-sc`.

Ghép lại thành một dòng, ngăn nhau bằng `;`, rồi dán vào `CHATGPT_COOKIES=`.

### Bước 2 — Access token

Chỉ cookie thôi là chưa đủ. Trước đây `/api/auth/session` trả về Bearer token;
từ khoảng tháng 9/2026 nó chỉ trả `WARNING_BANNER` và không có gì khác, nên
token phải lấy bằng tay.

1. DevTools → tab **Network**
2. Gửi một tin nhắn bất kỳ trong ChatGPT cho request hiện ra
3. Bấm vào một request tới `/backend-api/...`
4. Trong **Request Headers**, copy toàn bộ giá trị `authorization`
5. Dán vào `.env` ở dòng `CHATGPT_ACCESS_TOKEN=` (chữ `Bearer ` ở đầu có hay
   không đều được, helper tự bỏ)

Đây là JWT RS256 sống khoảng **10 ngày**. Helper in thời gian còn lại lúc khởi
động và báo lỗi rõ ràng khi hết hạn; thay token mới vào file là nó tự nhận,
không cần sửa code, không cần khởi động lại.

### Bước 3 — Kiểm tra

```bash
source .venv/bin/activate
python3 -c "
s=[l for l in open('.env') if l.startswith('CHATGPT_COOKIES=')][0].split('=',1)[1].strip()
ks=[p.strip().split('=')[0] for p in s.split(';') if '=' in p]
print('Số cookie:', len(ks))
print('session-token:', '✅' if any(k.startswith('__Secure-next-auth.session-token') for k in ks) else '❌ THIẾU')"
```

## Chạy

```bash
source .venv/bin/activate   # để `python3` trỏ vào venv có curl_cffi
./start.sh
```

Bỏ qua `activate` là nguyên nhân phổ biến nhất khiến helper chết với
`ModuleNotFoundError: curl_cffi`.

**Đừng dùng `sudo`** — nó reset môi trường, làm mất virtualenv, và để lại
`.cookies.json` thuộc quyền root. Proxy chạy ở cổng 1435/1436 (>1024) nên không
cần quyền root.

Dấu hiệu chạy thành công:

```
[http-helper] Access token from .env ✓ (expires in 239.6h)
[http-helper] CF cookies refreshed ✓
HTTP helper ready ✓
```

Kiểm tra nhanh:

```bash
curl http://127.0.0.1:1435/health   # proxy
curl http://127.0.0.1:1436/health   # helper — has_token phải là true
```

Tắt:

```bash
pkill -9 -f chatgpt-http-helper.py
pkill -f "bun.*proxy.ts"
```

Phải dùng `-9` cho helper: hàm `shutdown()` của nó gọi `server.shutdown()` ngay
trong signal handler trong khi `serve_forever()` đang khoá cùng thread, nên
SIGTERM bị deadlock.

## Chạy bằng Docker

Toàn bộ proxy đóng gói thành **một image chạy hai tiến trình** (bun + helper
Python), vì provider gọi helper qua `127.0.0.1:1436` nên không tách container
được. Cookie và ảnh sinh ra nằm ở volume `/data`, không mất khi rebuild.

```bash
cp .docker/.env.example .docker/.env     # điền CHATGPT_COOKIES, CHATGPT_ACCESS_TOKEN
docker compose -f .docker/docker-compose.yml --env-file .docker/.env up -d --build
curl http://127.0.0.1:1435/health
```

Trên server deploy, container còn nối vào `hoatheomua-network-dev` và
`hoatheomua-network-prod` nên API gọi được qua `http://chatgpt-proxy-prod:1435/v1`.
Chi tiết deploy, xoay access token và CI/CD: xem [DEPLOYMENT.md](DEPLOYMENT.md).

## Model

| Dùng khi | Model |
|---|---|
| Hằng ngày, nhanh (4–7s) | `chatgpt/gpt-5.6` |
| Cần suy luận kỹ | `chatgpt/gpt-5.6-thinking` |
| Việc nhẹ | `chatgpt/gpt-5.6-mini` |
| Nặng nhất | `chatgpt/gpt-6-pro` |

Xem đầy đủ bằng `curl http://127.0.0.1:1435/v1/models`. Các dòng GPT-4o / o1 /
o3 / o4 vẫn còn trong bảng ánh xạ để cấu hình cũ không vỡ, nhưng phần lớn đã
không còn tồn tại trên tài khoản hiện tại.

Các slug đuôi `-wm` (`gpt-5.6-sol-wm`, `gpt-6-astra-wm`, …) có xuất hiện trong
`/backend-api/models` nhưng trả về nội dung rỗng qua đường này nên cố ý không
ánh xạ.

## Gửi ảnh lên

Dùng đúng dạng mảng content chuẩn OpenAI. Chấp nhận cả `data:` URI lẫn URL
`http(s)://`:

```bash
curl http://127.0.0.1:1435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt/gpt-5.6","messages":[{"role":"user","content":[
        {"type":"text","text":"Ảnh này có gì?"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0..."}}
      ]}]}'
```

Nhận PNG, JPEG, GIF, WebP; kích thước đọc thẳng từ header file nên không cần
Pillow. Giới hạn 20MB mỗi ảnh.

Bên dưới, mỗi ảnh đi qua luồng upload ba bước của ChatGPT (đăng ký → PUT lên
blob storage → chốt), rồi lượt chat được gửi dạng `multimodal_text` kèm phần
`image_asset_pointer`. Upload được cache theo SHA-256 nên cùng một ảnh gửi lại
qua nhiều lượt chỉ đăng ký một lần.

Thứ tự bạn viết được giữ nguyên. Prompt dạng
`[text, ảnh, text, ảnh]` tới ChatGPT đúng thứ tự đó, nên văn bản nằm giữa hai
ảnh vẫn ở giữa chứ không bị dồn xuống cuối:

```json
"content": [
  {"type": "text",      "text": "Ảnh MỘT:"},
  {"type": "image_url", "image_url": {"url": "..."}},
  {"type": "text",      "text": "Ảnh HAI:"},
  {"type": "image_url", "image_url": {"url": "..."}},
  {"type": "text",      "text": "MỘT màu gì, HAI màu gì?"}
]
```

Lưu ý:

- Chỉ lượt **user** mới mang được ảnh; ảnh gắn ở role khác bị bỏ qua.
- Ảnh quá nhỏ bị model đọc lướt. Ảnh test 128×64 hai màu bị mô tả thành một
  màu; cùng ảnh đó ở 512×256 thì mô tả đúng.
- **Đừng trỏ URL ảnh vào chính endpoint `/files/` của proxy.** Helper là
  `HTTPServer` đơn luồng, tự gọi lại chính mình trong lúc đang bận sẽ deadlock
  cho tới khi bên gọi timeout.

## Tạo ảnh

Cứ yêu cầu bằng lời bình thường, không cần tham số gì thêm:

```bash
curl http://127.0.0.1:1435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt/gpt-5.6",
       "messages":[{"role":"user","content":"Vẽ một tách cà phê bốc khói"}]}'
```

```
![generated image](http://127.0.0.1:1435/files/file_00000000ff30....png)
```

File nằm trong `.generated_images/`, phục vụ qua `GET /files/<tên>`. Dùng link
thay vì nhúng base64 vì ảnh 2MB sẽ thành ~2.8MB base64 và làm nghẹn hầu hết
client OpenAI. Thư mục này **không tự dọn**, bạn tự xoá định kỳ.

Mất **30–45 giây**, so với 4–7 giây của chat text.

### Đánh đổi quyền riêng tư

ChatGPT tắt công cụ vẽ bên trong temporary chat — chính là chế độ mà
`history_and_training_disabled` tạo ra. Nên chỉ những request trông giống yêu
cầu vẽ ảnh mới rời chế độ tạm thời; hội thoại khi đó **được lưu trên tài
khoản** rồi bị xoá hẳn sau khi đọc xong câu trả lời.

Xoá sau không hoàn tác việc nội dung đã đi qua hệ thống. Nếu bạn bận tâm, tắt
**Settings → Data controls → Improve the model for everyone**.

Ý định vẽ được nhận diện bằng từ khoá trong lượt user mới nhất nên thỉnh
thoảng sẽ trượt. Ép thủ công bằng `"allow_history": true` (hoặc `false`) trong
body request. Muốn cấm hẳn cơ chế này, đặt `CHATGPT_NEVER_STORE=1` — mọi
request giữ chế độ tạm thời và tính năng vẽ tắt hoàn toàn.

## Kiểm thử

`test-api.sh` chạy toàn bộ stack đang bật bằng `./start.sh`:

```bash
./test-api.sh        # cả 10 test
./test-api.sh 1 2 9  # chỉ các test này (1, 2, 9, 10 không tốn quota)
```

| # | Test | Tốn quota |
|---|------|-----------|
| 1 | Health của proxy và helper, token đã nạp | không |
| 2 | `/v1/models` trả về danh sách hợp lý | không |
| 3 | Chat không streaming | có |
| 4 | Chat streaming (đếm SSE chunk) | có |
| 5 | Model thinking trả lời đúng | có |
| 6 | Gửi ảnh qua `data:` URI | có |
| 7 | Gửi ảnh qua URL `http://` | có |
| 8 | Tạo ảnh, link tải được, đúng là file PNG | có |
| 9 | Phục vụ `/files/` và ba kiểu path traversal | không |
| 10 | Không còn hội thoại nào sót lại trong 30 phút gần nhất | không |

Test số 10 hỏi thẳng helper xem nó đã tạo ra hội thoại nào mà chưa xoá được
(trường `undeleted_conversations` trong `/health`), chứ không quét danh sách hội
thoại của tài khoản — quét như vậy sẽ gắn cờ nhầm cả những hội thoại bạn đang tự
tạo trong trình duyệt. Khi request crash hoặc timeout giữa chừng, bước dọn không
chạy và hội thoại sót lại; test này sẽ chỉ đúng ID cần xoá tay.

## Giới hạn đã biết

- **Tool calling không chạy với model ChatGPT.** Phần giả lập `<tool_call>` bị
  model hiện tại phớt lờ, kể cả khi ép `tool_choice: "required"` — chúng trả
  lời thẳng thay vì gọi tool. Tool calling vẫn chạy bình thường với backend
  qua `UPSTREAM_URL`.
- **Mỗi lúc chỉ xử lý một request.** Helper đơn luồng và xếp hàng mọi thứ sau
  một lock toàn cục.

## Dùng với agent

Trỏ provider tương thích OpenAI của agent tới `http://127.0.0.1:1435/v1`.

> **Agent lập trình sẽ không dùng được tốt ở đây.** Chúng vận hành hoàn toàn
> bằng tool call, mà tool calling không chạy với model ChatGPT. Model sẽ trả
> lời bằng văn xuôi thay vì gọi tool của bạn. Dùng cho mục đích chat thì bình
> thường.

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:1435/v1", api_key="not-needed")

r = client.chat.completions.create(
    model="chatgpt/gpt-5.6",
    messages=[{"role": "user", "content": "Xin chào"}],
)
print(r.choices[0].message.content)
```

Cấu hình mẫu cho OpenCode và Hermes xem ở bản tiếng Anh bên dưới.

## Cơ chế tự làm mới cookie

Helper dùng `curl_cffi.Session` (không phải `requests` thô), hành xử như một tab
trình duyệt thật:

1. Mọi response từ chatgpt.com có header `Set-Cookie` đều được bắt lại tự động
2. Cookie Cloudflare (`__cf_bm`, `_cfuvid`, …) xoay vòng liên tục — Session tự
   xử lý, bạn không phải làm gì
3. Khi gặp 403, helper tự vào trang chủ lấy cookie Cloudflare mới rồi thử lại
4. Cookie được lưu xuống `.cookies.json` nên sống sót qua các lần khởi động lại
5. Lúc khởi động, cookie đã lưu được trộn với cookie trong `.env`, ưu tiên cookie
   đã lưu vì chúng mới hơn

Thứ bạn thực sự phải thay bằng tay là `CHATGPT_ACCESS_TOKEN` (~10 ngày) và, hiếm
hơn nhiều, `CHATGPT_COOKIES`.

## Xử lý sự cố

**`CHATGPT_ACCESS_TOKEN expired Nh ago`** — lấy header `authorization` mới từ
DevTools → Network → request `/backend-api/` bất kỳ, dán vào `.env`. Không cần
khởi động lại.

**`no CHATGPT_ACCESS_TOKEN and no session cookie`** — `.env` thiếu cả hai. Kiểm
tra giá trị nằm trên một dòng và không bọc nháy.

**`No accessToken in /api/auth/session response`** — chuyện bình thường,
OpenAI đã gỡ token khỏi endpoint đó. Nghĩa là `CHATGPT_ACCESS_TOKEN` chưa được
đặt và helper rơi vào đường cũ đã chết.

**`ModuleNotFoundError: curl_cffi`** — chưa activate virtualenv.

**Câu trả lời bị cụt còn vài ký tự** — đã sửa. Parser SSE trước đây vứt mọi
delta batch sau batch đầu tiên, vì các batch sau đến dạng `{"v":[...]}` không
kèm khoá `"o":"patch"`. Nếu tái diễn nghĩa là định dạng stream lại đổi.

**`Address already in use`** — helper cũ còn giữ cổng, xem mục *Chạy* ở trên.
Một traceback loại này mỗi lần khởi động là vô hại: `start.sh` bật helper,
`proxy.ts` cũng cố bật một cái nữa, cái sau thua và rồi tìm thấy cái đang chạy.

**403 dai dẳng** — `curl http://127.0.0.1:1436/refresh` để làm mới cookie
Cloudflare thủ công.

## Bảo mật

Cả hai cổng đều bind `127.0.0.1`, nhưng **không có xác thực** và đều trả
`Access-Control-Allow-Origin: *`. Khi proxy đang chạy, **bất kỳ trang web nào
bạn mở trong trình duyệt cũng gọi được vào nó**, tiêu quota ChatGPT của bạn và
đọc được nội dung trả lời. Chỉ bật khi cần.

`.env` và `.cookies.json` chứa credential tương đương một lần đăng nhập đầy đủ
vào tài khoản ChatGPT. Đặt `chmod 600 .env` và đừng đưa vào version control
(cả hai đã nằm trong `.gitignore`).

Route catch-all forward mọi path lạ tới upstream **kèm sẵn `UPSTREAM_KEY`** —
thêm một lý do nữa để không phơi cổng này ra ngoài.

## Giấy phép

MIT

---

<a name="english"></a>

# English

[⬆ Tiếng Việt](#tieng-viet)

An OpenAI-compatible proxy in front of the ChatGPT web app: talk to the GPT-5.5
/ 5.6 / 6 models on your ChatGPT Plus or Pro account through the usual
`/v1/chat/completions` shape, including **sending images** and **getting
generated images back**. It authenticates with a session cookie plus an access
token copied out of a logged-in browser.

It also carries the original project's **tool calling emulation** for other
OpenAI-compatible backends — but see [Known
Limitations](#known-limitations): that part does *not* work against ChatGPT
models.

## Architecture

```
                     Your App / Agent
                            │
              /v1/chat/completions, /v1/models, /files/
                            ▼
              ┌─────────────────────────────┐
              │  proxy.ts (Bun, port 1435)  │  OpenAI-compatible API
              │  routes by model name       │
              └──────────┬───────┬──────────┘
                chatgpt/*│       │other models
                         ▼       ▼
   ┌──────────────────────────┐ ┌──────────────────┐
   │ chatgpt-http-helper.py   │ │    Upstream      │
   │ port 1436, curl_cffi     │ │  (any OpenAI-    │
   │  · Safari TLS + cookies  │ │   compatible)    │
   │  · Sentinel PoW          │ └──────────────────┘
   │  · image up/download     │
   │  · GET /files/<name>     │
   └────────────┬─────────────┘
                │
                ▼
   chatgpt.com/backend-api
     · /conversation          chat + generated-image pointers
     · /files                 upload (3 steps) and download
     · /sentinel/…            proof-of-work gate
```

## Features

- **ChatGPT web via an OpenAI-compatible API** — GPT-5.5 / 5.6 / 6 families,
  thinking and pro variants, deep research, agent mode. Streaming supported.
- **Image input** — standard `image_url` content parts, `data:` URI or
  `http(s)://`, uploaded through ChatGPT's own file flow. See
  [Image Input](#image-input-vision).
- **Image generation** — ask for a picture and get a link to the PNG. See
  [Image Generation](#image-generation).
- **Temporary chat by default** — nothing is stored on the account except for
  image requests, which have to leave that mode; those conversations are
  deleted once the reply is parsed.
- **Cloudflare handling** — Safari TLS impersonation, a `curl_cffi` session
  that keeps rotating cookies fresh, automatic refresh and retry on 403, and
  cookie persistence to `.cookies.json` across restarts.
- **Proof of Work solver** — answers ChatGPT's Sentinel PoW challenge
  (typically in under a millisecond).
- **Tool call emulation** — `<tool_call>` XML emulation for backends behind
  `UPSTREAM_URL`. Does not work against ChatGPT models.

## Requirements

- [Bun](https://bun.sh/) (v1.0+)
- Python 3.10+
- `curl_cffi` Python package
- A ChatGPT Plus or Pro account (for ChatGPT proxy)

## Installation

```bash
git clone https://github.com/zhaefremedia/toolcall-middleware.git
cd toolcall-middleware

bun install

# A virtualenv keeps curl_cffi off the system Python. Whatever `python3`
# resolves to when you launch must be the interpreter that has curl_cffi -
# start.sh and the provider both spawn a bare `python3`.
python3 -m venv .venv
.venv/bin/pip install curl_cffi

cp .env.example .env
```

## Configuration

`.env` needs two credentials, both copied out of a logged-in chatgpt.com
session. Put each on a single line with **no quotes** - the helper parses this
file itself and will not strip them.

```env
CHATGPT_COOKIES=_puid=user-xxx;__Secure-next-auth.session-token=eyJhbG...
CHATGPT_ACCESS_TOKEN=eyJhbGciOiJSUzI1NiIs...
```

`UPSTREAM_URL` / `UPSTREAM_KEY` are only for non-`chatgpt/*` models; leave them
alone if you only use ChatGPT. See `.env.example` for the optional settings.

## How to Get ChatGPT Credentials

The most important step. You need two things out of a logged-in ChatGPT browser
session: the cookies (steps 1-4) and the access token (step 4b).

### Step 1: Open ChatGPT in your browser

Go to [https://chatgpt.com](https://chatgpt.com) and make sure you're **logged in**.

### Step 2: Open DevTools

Press `F12` or `Ctrl+Shift+I` (Windows/Linux) / `Cmd+Option+I` (Mac) to open Developer Tools.

### Step 3: Copy cookies

Use the **Application** tab, not the Console. `document.cookie` cannot see
`HttpOnly` cookies, and the one that matters most is `HttpOnly` - copying from
the Console silently gives you an unusable cookie string.

1. Go to **Application** → **Cookies** → `https://chatgpt.com`
2. You need these cookies (copy name=value pairs, separated by `;`):

| Cookie | Required | Description |
|--------|----------|-------------|
| `__Secure-next-auth.session-token` | ✅ **Critical** | Your auth session (very long JWT) |
| `_puid` | ✅ Recommended | User identifier |
| `oai-sc` | ✅ Recommended | OpenAI session cookie |
| `__cf_bm` | Optional | Cloudflare bot management (auto-refreshed) |
| `_cfuvid` | Optional | Cloudflare visitor ID (auto-refreshed) |
| `__cflb` | Optional | Cloudflare load balancer |
| `__Host-next-auth.csrf-token` | Optional | CSRF token |
| `__Secure-next-auth.callback-url` | Optional | Auth callback URL |

> **Note:** Cloudflare cookies (`__cf_bm`, `_cfuvid`, etc.) expire every ~30 minutes, but the proxy **auto-refreshes them** using the Session object. You only need to provide them once — the proxy handles rotation.

### Step 4: Paste into `.env`

Paste the full cookie string as one line:

```env
CHATGPT_COOKIES=_puid=user-xxx;__Secure-next-auth.session-token=eyJhbG...very_long_token;oai-sc=0gAAAA...;__cf_bm=abc123...;_cfuvid=xyz789...
```

> **Important:** `__Secure-next-auth.session-token` is the critical cookie.
> Once it grows past the 4KB per-cookie limit the browser splits it into
> `__Secure-next-auth.session-token.0` and `.1` - paste both parts.

### Step 4b: Copy the access token

Cookies alone are not enough. `/api/auth/session` used to hand out a Bearer
token; as of Sep 2026 it answers with a `WARNING_BANNER` and nothing else, so
the token has to be supplied out of band.

1. DevTools → **Network** tab
2. Send any message in ChatGPT so requests appear
3. Click any request to `/backend-api/...`
4. Under **Request Headers**, copy the whole `authorization` value
5. Paste into `.env` as `CHATGPT_ACCESS_TOKEN=` (the leading `Bearer ` is
   optional - the helper strips it)

It is an RS256 JWT valid for about **10 days**. The helper prints the remaining
lifetime on startup and fails with a clear message once it lapses; swap in a
fresh one and it is picked up without a code change.

### Step 5: Verify

```bash
# Start the helper and check if token works
python3 chatgpt-http-helper.py
# Should show: "Access token obtained ✓"
```

## Usage

### Start everything

```bash
source .venv/bin/activate   # so a bare `python3` finds curl_cffi
./start.sh
```

Or separately:

```bash
source .venv/bin/activate
python3 chatgpt-http-helper.py &   # helper first (port 1436)
bun run proxy.ts                   # proxy (port 1435)
```

Skipping the `activate` is the usual cause of the helper dying with
`ModuleNotFoundError: curl_cffi`. Do **not** use `sudo`: it resets the
environment, loses the virtualenv, and leaves `.cookies.json` owned by root.

### Test it

```bash
# Health check
curl http://127.0.0.1:1435/health

# List models
curl http://127.0.0.1:1435/v1/models

# Chat
curl -X POST http://127.0.0.1:1435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "chatgpt/gpt-5.6",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Chat with streaming
curl -X POST http://127.0.0.1:1435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "chatgpt/gpt-5.6",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

Or run the whole suite: `./test-api.sh` — see [Testing](#testing).

### Helper endpoints

The HTTP helper (port 1436) has debug endpoints:

```bash
# Serve a generated image (the proxy forwards /files/ here too)
curl http://127.0.0.1:1436/files/<name>.png

# Health + cookie status
curl http://127.0.0.1:1436/health

# List current cookie names
curl http://127.0.0.1:1436/cookies

# Manually refresh Cloudflare cookies
curl http://127.0.0.1:1436/refresh
```

## Running with Docker

The proxy ships as **one image running two processes** (bun + the Python
helper): the provider reaches the helper over `127.0.0.1:1436`, so they cannot
be split. Cookies and generated images live on the `/data` volume and survive
rebuilds.

```bash
cp .docker/.env.example .docker/.env     # fill in CHATGPT_COOKIES, CHATGPT_ACCESS_TOKEN
docker compose -f .docker/docker-compose.yml --env-file .docker/.env up -d --build
curl http://127.0.0.1:1435/health
```

On the deploy host the container also joins `hoatheomua-network-dev` and
`hoatheomua-network-prod`, so the APIs reach it at
`http://chatgpt-proxy-prod:1435/v1`. Deployment, token rotation and CI/CD are
covered in [DEPLOYMENT.md](DEPLOYMENT.md).

## Available ChatGPT Models

Use these as the `model` parameter:

| Model ID | ChatGPT Model |
|----------|---------------|
| `chatgpt/auto` | Auto (default) |
| `chatgpt/gpt-4o` | GPT-4o |
| `chatgpt/gpt-4o-mini` | GPT-4o Mini |
| `chatgpt/gpt-4.1` | GPT-4.1 |
| `chatgpt/o1` | o1 |
| `chatgpt/o1-mini` | o1-mini |
| `chatgpt/o1-pro` | o1-pro |
| `chatgpt/o3` | o3 |
| `chatgpt/o3-mini` | o3-mini |
| `chatgpt/o3-mini-high` | o3-mini (high effort) |
| `chatgpt/o4-mini` | o4-mini |
| `chatgpt/o4-mini-high` | o4-mini (high effort) |
| `chatgpt/gpt-5.5` | GPT-5.5 |
| `chatgpt/gpt-5.5-instant` | GPT-5.5 Instant |
| `chatgpt/gpt-5.5-thinking` | GPT-5.5 Thinking |
| `chatgpt/gpt-5.5-mini` | GPT-5.5 Mini |
| `chatgpt/gpt-5.5-pro` | GPT-5.5 Pro |
| `chatgpt/gpt-5.6` | GPT-5.6 Sol |
| `chatgpt/gpt-5.6-instant` | GPT-5.6 Sol Instant |
| `chatgpt/gpt-5.6-thinking` | GPT-5.6 Sol Thinking |
| `chatgpt/gpt-5.6-mini` | GPT-5.6 Luna |
| `chatgpt/gpt-5.6-pro` | GPT-5.6 Pro |
| `chatgpt/gpt-6-pro` | GPT-6 Pro |
| `chatgpt/deep-research` | Deep Research |
| `chatgpt/agent` | Agent Mode |

The GPT-4o / o1 / o3 / o4 rows above are kept so older configs keep resolving,
but most of them no longer exist on a current account. `GET /v1/models` lists
what this build exposes; `/backend-api/models` is the authority on what your
account actually has.

The `-wm` slugs that appear in `/backend-api/models` (`gpt-5.6-sol-wm`,
`gpt-6-astra-wm`, ...) answer with an empty body over this path and are
deliberately not mapped.

## Image Generation

Ask for a picture in plain language and the reply comes back as a markdown
link:

```bash
curl http://127.0.0.1:1435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt/gpt-5.6",
       "messages":[{"role":"user","content":"Draw a steaming cup of coffee"}]}'
```

```
![generated image](http://127.0.0.1:1435/files/file_00000000ff30....png)
```

Files land in `.generated_images/` and are served from `GET /files/<name>`.
Links are used rather than inline base64 because a 2MB PNG becomes ~2.8MB of
base64 and chokes most OpenAI clients. Nothing prunes that directory; clear it
yourself.

Expect **30-45s** for an image versus 4-7s for text.

### The privacy trade-off

ChatGPT disables its image tool inside a temporary chat, which is what
`history_and_training_disabled` creates. So requests that look like image
requests - and only those - drop out of temporary mode; the conversation is
then stored on your account and hard-deleted once the reply is parsed.

Deleting afterwards does not undo the content having passed through. If that
matters, turn off **Settings → Data controls → Improve the model for everyone**.

Intent is detected from keywords in the newest user turn, so it will
occasionally miss. Force it either way with `"allow_history": true` (or
`false`) in the request body. To forbid the whole mechanism, set
`CHATGPT_NEVER_STORE=1` - every request stays temporary and image generation
is off.

## Image Input (Vision)

Send pictures with the standard OpenAI content-array shape. Both a `data:` URI
and an `http(s)://` URL work:

```bash
curl http://127.0.0.1:1435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt/gpt-5.6","messages":[{"role":"user","content":[
        {"type":"text","text":"What is in this picture?"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0..."}}
      ]}]}'
```

PNG, JPEG, GIF and WebP are recognised; dimensions are read straight from the
file header, so there is no Pillow dependency. The cap is 20MB per image.

Behind the scenes each picture goes through ChatGPT's three-step upload
(register → PUT to blob storage → finalize) and the turn is then sent as
`multimodal_text` with an `image_asset_pointer` part. Uploads are cached by
SHA-256, so the same picture re-sent across turns is only registered once.

Part order is preserved: a prompt written as `[text, image, text, image]`
reaches ChatGPT in that order, so text sitting between two pictures stays
between them rather than being hoisted to the end.

Notes:

- Only **user** turns carry images; parts on other roles are ignored.
- Very small images get skimmed. A 128x64 test image came back described as one
  colour when it was two; the same image at 512x256 was described correctly.
- Do **not** point an image URL at this proxy's own `/files/` endpoint. The
  helper is a single-threaded `HTTPServer`, so fetching from itself while it is
  busy serving your request deadlocks it until the caller times out.

## Testing

`test-api.sh` exercises the whole stack against a running `./start.sh`:

```bash
./test-api.sh        # all 10 tests
./test-api.sh 1 2 9  # only these (1, 2, 9 and 10 cost no quota)
```

| # | Test | Quota |
|---|------|-------|
| 1 | Health of proxy and helper, token loaded | no |
| 2 | `/v1/models` returns a sane list | no |
| 3 | Chat, non-streaming | yes |
| 4 | Chat, streaming (SSE chunk count) | yes |
| 5 | Thinking model returns a correct answer | yes |
| 6 | Vision via `data:` URI | yes |
| 7 | Vision via `http://` URL | yes |
| 8 | Image generation, link works, bytes are a real PNG | yes |
| 9 | `/files/` serving plus three path-traversal attempts | no |
| 10 | No conversation from the last 30 min survived on the account | no |

Test 10 asks the helper which conversations it created and failed to delete
(the `undeleted_conversations` field on `/health`) rather than scanning the
account's conversation list - scanning would flag whatever the user happens to
be doing in their browser at the time. A crash or timeout mid-request skips the
cleanup step, and this test names the exact IDs that need deleting by hand.

## Known Limitations

- **Tool calling does not work against ChatGPT models.** The prompt-based
  `<tool_call>` emulation is ignored by current models even with
  `tool_choice: "required"` - they answer directly instead. Tool calling still
  works against a normal `UPSTREAM_URL` backend.
- **One request at a time.** The helper is single-threaded and serialises
  everything behind a global lock; concurrent callers queue.

## Use with OpenCode / Hermes / Other Agents

Point your agent's OpenAI-compatible provider to `http://127.0.0.1:1435/v1`.

> **Coding agents will not work well here.** They drive everything through tool
> calls, and tool calling does not work against ChatGPT models - see
> [Known Limitations](#known-limitations). Expect the model to answer in prose
> instead of calling your tools. For chat-shaped use this is fine.

**OpenCode** (`opencode.json`):
```json
{
  "provider": {
    "chatgpt-proxy": {
      "name": "ChatGPT Proxy",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://127.0.0.1:1435/v1"
      },
      "models": {
        "chatgpt/gpt-5.6": {
          "name": "GPT-5.6 (ChatGPT)",
          "limit": { "context": 1050000, "output": 128000 },
          "modalities": { "input": ["text", "image"], "output": ["text"] }
        }
      }
    }
  }
}
```

**Hermes** (`config.yaml`):
```yaml
custom_providers:
  - name: chatgpt-proxy
    base_url: http://localhost:1435/v1
    api_key_env: ''
    models:
      chatgpt/gpt-5.6:
        context_length: 1050000
```

**Any OpenAI SDK**:
```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:1435/v1",
    api_key="not-needed"  # no API key required
)

response = client.chat.completions.create(
    model="chatgpt/gpt-5.6",
    messages=[{"role": "user", "content": "Hello!"}]
)
print(response.choices[0].message.content)

# With an image
response = client.chat.completions.create(
    model="chatgpt/gpt-5.6",
    messages=[{"role": "user", "content": [
        {"type": "text", "text": "What is in this picture?"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}},
    ]}],
)
```

## How Cookie Auto-Refresh Works

The proxy uses `curl_cffi.Session` (not raw requests) which acts like a real browser tab:

1. **Every response** from chatgpt.com that contains `Set-Cookie` headers is automatically captured
2. **Cloudflare cookies** (`__cf_bm`, `_cfuvid`, etc.) rotate frequently — the Session handles this transparently
3. **On 403 errors**, the proxy automatically visits the homepage to get fresh Cloudflare cookies, then retries
4. **Cookies are persisted** to `.cookies.json` so they survive restarts
5. **On startup**, persisted cookies are merged with `.env` cookies (persisted takes priority since they're fresher)

Cloudflare cookies rotate on their own. What you do have to refresh by hand is
`CHATGPT_ACCESS_TOKEN` (~10 days) and, much less often, `CHATGPT_COOKIES`.

## Troubleshooting

### "CHATGPT_ACCESS_TOKEN expired Nh ago"
Copy a fresh `authorization` header out of DevTools → Network → any
`/backend-api/` request into `.env`. No restart needed - the helper re-reads
the file shortly before the old token lapses.

### "no CHATGPT_ACCESS_TOKEN and no session cookie"
`.env` has neither credential. Check the value is on one line and unquoted:

```bash
python3 -c "
s=[l for l in open('.env') if l.startswith('CHATGPT_COOKIES=')][0].split('=',1)[1].strip()
ks=[p.strip().split('=')[0] for p in s.split(';') if '=' in p]
print('cookies:', len(ks))
print('session-token:', any(k.startswith('__Secure-next-auth.session-token') for k in ks))"
```

### "No accessToken in /api/auth/session response"
Expected - OpenAI removed the token from that endpoint. It means
`CHATGPT_ACCESS_TOKEN` is unset and the helper fell back to the dead path.

### "ModuleNotFoundError: curl_cffi"
The virtualenv is not active. `source .venv/bin/activate` before `./start.sh`.

### Replies are truncated to a few characters
Fixed - the SSE parser used to drop every delta batch after the first, because
follow-up batches arrive as `{"v":[...]}` without the `"o":"patch"` key. If it
reappears, the stream format moved again.

### "413 message_length_exceeds_limit"
ChatGPT web has a per-message size limit. This happens when agents send very large prompts (system prompt + tool definitions). Consider using ChatGPT models for simpler tasks, or use API-based models for agentic workloads.

### "Address already in use"
A previous helper is still holding the port. Its SIGTERM handler deadlocks
(`server.shutdown()` is called from the signal handler while `serve_forever()`
blocks the same thread), so `pkill` is not enough:

```bash
pkill -9 -f chatgpt-http-helper.py
pkill -f "bun.*proxy.ts"
```

`fuser` is Linux-only; on macOS use `lsof -ti:1435,1436 | xargs kill -9`.

One `Address already in use` traceback per start is harmless: `start.sh`
launches the helper and `proxy.ts` tries to spawn its own, which loses the race
and then finds the healthy one.

## Security Notes

Both ports bind to `127.0.0.1`, but neither requires authentication and both
send `Access-Control-Allow-Origin: *`. While the proxy runs, **any web page
open in your browser can call it** and spend your ChatGPT quota, and read the
replies. Run it only when you need it.

`.env` and `.cookies.json` hold credentials equivalent to a full login to your
ChatGPT account. `chmod 600 .env` and keep both out of version control (they
are already in `.gitignore`).

The catch-all route forwards unknown paths upstream with `UPSTREAM_KEY`
attached - another reason not to expose this port.

### Cookie-related 403 errors
The proxy auto-handles most cookie issues. If you see persistent 403s:
```bash
# Manual refresh
curl http://127.0.0.1:1436/refresh

# Check cookie status
curl http://127.0.0.1:1436/health
```

## License

MIT
