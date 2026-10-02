#!/bin/bash
# Runs the same two processes the two systemd units run, in one container:
#   obsidian-mcp.service      -> supergateway wrapping obsidian-mcp on :8420
#   obsidian-mcp-auth.service -> auth-server.js on :8422 ($PORT)
#
# supergateway has no bind-address flag and listens on every interface
# (see README's "How it works"), so on a real host that's fenced off with
# systemd's IPAddressAllow=localhost. Inside a single Fly Machine there's
# no LAN to leak to, and fly.toml below only exposes $PORT (8422), so the
# same boundary holds without needing that fence here.
set -e

mkdir -p "$CONFIG_DIR" "$VAULT_PATH"

echo "Starting supergateway (obsidian-mcp stdio -> :8420) for vault: $VAULT_PATH"
node node_modules/supergateway/dist/index.js \
  --stdio "node node_modules/obsidian-mcp/build/main.js '$VAULT_PATH'" \
  --outputTransport streamableHttp \
  --port 8420 \
  --stateful \
  --sessionTimeout 3600000 \
  --healthEndpoint /healthz \
  --logLevel info &
SUPERGATEWAY_PID=$!

# auth-server.js proxies to $UPSTREAM and fails fast if it's not up yet on
# its first request, but won't crash-loop waiting — give supergateway a
# moment to bind before starting the process clients actually hit.
sleep 2

echo "Starting auth-server.js on :$PORT (issuer: $ISSUER)"
node auth-server.js &
AUTH_PID=$!

# If either process dies, tear the whole Machine down so Fly restarts it
# clean, rather than limping along with only half the pipeline working.
wait -n "$SUPERGATEWAY_PID" "$AUTH_PID"
EXIT_CODE=$?
kill "$SUPERGATEWAY_PID" "$AUTH_PID" 2>/dev/null || true
exit "$EXIT_CODE"
