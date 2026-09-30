# fly.io deployment for obsidian-remote-mcp.
#
# Upstream ships systemd units + nginx + a Cloudflare Tunnel for a
# self-hosted Linux box (see systemd/*.service and nginx/obsidian-mcp.conf).
# fly.io Machines don't run systemd, and Fly's own edge already terminates
# TLS and reverse-proxies to the app, so nginx and the tunnel are redundant
# here. This Dockerfile instead runs both node processes (supergateway
# wrapping obsidian-mcp on 8420, auth-server.js on 8422/$PORT) under one
# entrypoint script, matching the two systemd ExecStart lines exactly, and
# lets fly.toml expose only the auth server — the same "only the auth
# server is reachable from outside" boundary the systemd+nginx setup
# enforces, just drawn by Fly's proxy instead of nginx.
FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY . .

# postinstall patches (patches/disable-idle-close.js, patches/fix-edit-note.js)
# already ran during npm install above; re-run defensively in case COPY
# order ever changes and they get skipped.
RUN node patches/disable-idle-close.js && node patches/fix-edit-note.js

RUN chmod +x docker-entrypoint.sh

ENV PORT=8422
ENV UPSTREAM=http://127.0.0.1:8420
ENV CONFIG_DIR=/data/config
ENV VAULT_PATH=/data/vault

# ISSUER, DEFAULT_VAULT are set via `fly secrets`/fly.toml env, not baked in.

EXPOSE 8422

ENTRYPOINT ["./docker-entrypoint.sh"]
