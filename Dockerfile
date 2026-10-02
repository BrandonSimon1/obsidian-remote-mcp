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

# patches/ is copied alongside package.json (not just left to the later
# `COPY . .`) because `npm install`'s postinstall runs
# patches/disable-idle-close.js and patches/fix-edit-note.js immediately -
# without it present here that install step fails outright, it doesn't
# just skip the patches. (Copied as its own COPY, not folded into the one
# above: `COPY <dir> ./` copies a directory's *contents* into the
# destination, not the directory itself, so patches/*.js would otherwise
# land at /app/*.js instead of /app/patches/*.js.)
COPY package.json package-lock.json* ./
COPY patches ./patches
RUN npm install --omit=dev

COPY . .

# Re-run defensively in case COPY order ever changes again and the
# postinstall above ends up skipped.
RUN node patches/disable-idle-close.js && node patches/fix-edit-note.js

RUN chmod +x docker-entrypoint.sh

ENV PORT=8422
ENV UPSTREAM=http://127.0.0.1:8420
ENV CONFIG_DIR=/data/config
ENV VAULT_PATH=/data/vault

# ISSUER, DEFAULT_VAULT are set via `fly secrets`/fly.toml env, not baked in.

EXPOSE 8422

ENTRYPOINT ["./docker-entrypoint.sh"]
