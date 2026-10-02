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

WAIT_PIDS=("$SUPERGATEWAY_PID" "$AUTH_PID")

# Headless Sync: keep $VAULT_PATH current from an Obsidian Sync vault via
# obsidian-headless. `ob` reads the OBSIDIAN_AUTH_TOKEN env var directly
# (undocumented but present in its CLI - see TKT-31's Notes), so no
# interactive `ob login` is needed as long as that secret is set. Skipped
# entirely when SYNC_REMOTE_VAULT isn't set, so the sandbox can stand up
# and be read/write-validated against an empty vault before any sync
# source is wired in, per TKT-31's acceptance criteria.
if [ -n "$SYNC_REMOTE_VAULT" ]; then
  if ! node node_modules/.bin/ob sync-status --path "$VAULT_PATH" --json >/dev/null 2>&1; then
    echo "Setting up headless sync for vault: $SYNC_REMOTE_VAULT"
    node node_modules/.bin/ob sync-setup --vault "$SYNC_REMOTE_VAULT" --path "$VAULT_PATH" --json
  fi
  echo "Starting obsidian-headless continuous sync for vault: $SYNC_REMOTE_VAULT"
  node node_modules/.bin/ob sync --path "$VAULT_PATH" --continuous &
  SYNC_PID=$!
  WAIT_PIDS+=("$SYNC_PID")
else
  echo "SYNC_REMOTE_VAULT not set - skipping headless sync, serving \$VAULT_PATH as-is"
fi

# If any process dies, tear the whole Machine down so Fly restarts it
# clean, rather than limping along with only part of the pipeline working.
wait -n "${WAIT_PIDS[@]}"
EXIT_CODE=$?
kill "${WAIT_PIDS[@]}" 2>/dev/null || true
exit "$EXIT_CODE"
