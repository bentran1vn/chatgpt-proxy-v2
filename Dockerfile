# The proxy is two processes that must share a loopback interface: proxy.ts
# (bun) talks to chatgpt-http-helper.py over 127.0.0.1:1436, a hostname the
# helper binds and the provider hardcodes. So they ship in one image, not two.
FROM oven/bun:1-debian AS base
WORKDIR /app
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv ca-certificates curl tzdata && \
    rm -rf /var/lib/apt/lists/*

# curl_cffi carries the TLS fingerprint that lets the helper look like Safari to
# chatgpt.com; installed into a venv because Debian's python3 is PEP 668-marked.
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

FROM base AS deps
# bun.lock is gitignored upstream, so the lockfile may be absent — copy it
# optionally and let bun resolve @types/bun when it is.
COPY package.json bun.loc[k] ./
RUN bun install --frozen-lockfile 2>/dev/null || bun install

FROM base AS final
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=1435 \
    CHATGPT_BRIDGE_PORT=1436 \
    CHATGPT_DATA_DIR=/data \
    TZ=Asia/Bangkok
COPY --from=deps /app/node_modules ./node_modules
COPY package.json proxy.ts chatgpt-provider.ts chatgpt-http-helper.py ./
COPY .docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && mkdir -p /data/.generated_images

EXPOSE 1435
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
