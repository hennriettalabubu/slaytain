#!/usr/bin/env bash
# onstart.sh — service orchestration for dhi-aio-studio.
# Modes:
#   serve   (default) start sshd, Caddy portal, Jupyter, optional cloudflared tunnel, then wait
#   shell   drop into zsh as nobbby (useful: docker run ... /onstart.sh shell)
#   oneshot start services, print URLs, exit (CI smoke test)
set -euo pipefail

MODE="${1:-serve}"
LOG_DIR="/var/log/aio"
mkdir -p "$LOG_DIR"
chown -R nobbby:nobbby "$LOG_DIR" || true

: "${JUPYTER_PORT:=8888}"
: "${CADDY_PORT:=8080}"
: "${SSH_PORT:=22}"
: "${TENSORBOARD_PORT:=6006}"
: "${JUPYTER_TOKEN:=}"
: "${JUPYTER_PASSWORD:=}"
: "${WORKSPACE:=/workspace}"
: "${CF_TUNNEL_TOKEN:=}"       # set to run `cloudflared tunnel run --token ...`
: "${CF_TUNNEL_CONFIG:=}"      # or point at a mounted /etc/cloudflared/config.yml
: "${NOBBBY_AUTHORIZED_KEYS:=}" # paste SSH public key(s); newline-separated
: "${NOBBBY_PASSWORD:=}"       # set to enable password SSH login for nobbby
: "${AITOOLKIT_HOME:=/opt/ai-toolkit}"  # baked into image by Dockerfile
: "${AITOOLKIT_PORT:=8675}"    # port the UI binds to (matches ostris docker-compose)
: "${AI_TOOLKIT_AUTH:=}"       # UI auth password; empty disables auth

log()  { printf '[onstart %(%H:%M:%S)T] %s\n' -1 "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

ensure_host_keys() {
  if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    log "Generating sshd host keys"
    ssh-keygen -A
  fi
}

seed_authorized_keys() {
  local ssh_dir="/home/nobbby/.ssh"
  install -d -m 700 -o nobbby -g nobbby "$ssh_dir"
  if [ -n "${NOBBBY_AUTHORIZED_KEYS}" ]; then
    printf '%s\n' "${NOBBBY_AUTHORIZED_KEYS}" > "$ssh_dir/authorized_keys"
  elif [ ! -f "$ssh_dir/authorized_keys" ]; then
    touch "$ssh_dir/authorized_keys"
  fi
  chown nobbby:nobbby "$ssh_dir/authorized_keys"
  chmod 600 "$ssh_dir/authorized_keys"
}

set_nobbby_password() {
  if [ -n "${NOBBBY_PASSWORD}" ]; then
    log "Setting nobbby password from NOBBBY_PASSWORD"
    echo "nobbby:${NOBBBY_PASSWORD}" | chpasswd
  fi
}

start_sshd() {
  ensure_host_keys
  seed_authorized_keys
  set_nobbby_password
  log "Starting sshd on :${SSH_PORT}"
  /usr/sbin/sshd -D -p "${SSH_PORT}" -e >>"$LOG_DIR/sshd.log" 2>&1 &
  echo $! > "$LOG_DIR/sshd.pid"
}

start_caddy() {
  log "Starting Caddy portal on :${CADDY_PORT}"
  CADDY_PORT="${CADDY_PORT}" JUPYTER_PORT="${JUPYTER_PORT}" TENSORBOARD_PORT="${TENSORBOARD_PORT}" \
    caddy run --config /opt/portal-aio/Caddyfile --adapter caddyfile \
    >>"$LOG_DIR/caddy.log" 2>&1 &
  echo $! > "$LOG_DIR/caddy.pid"
}

start_jupyter() {
  log "Starting JupyterLab on :${JUPYTER_PORT} (workspace=${WORKSPACE})"
  local args=(
    --ip=0.0.0.0
    --port="${JUPYTER_PORT}"
    --no-browser
    --ServerApp.root_dir="${WORKSPACE}"
    --ServerApp.allow_origin='*'
    --ServerApp.allow_remote_access=True
  )
  if [ -n "${JUPYTER_PASSWORD}" ]; then
    local hashed
    hashed="$(/opt/venv/bin/python -c "from jupyter_server.auth import passwd; import os; print(passwd(os.environ['JUPYTER_PASSWORD']))")"
    args+=( --ServerApp.password="$hashed" --ServerApp.token='' )
  else
    args+=( --ServerApp.token="${JUPYTER_TOKEN}" )
  fi
  sudo -u nobbby -H -E /opt/venv/bin/jupyter-lab "${args[@]}" \
    >>"$LOG_DIR/jupyter.log" 2>&1 &
  echo $! > "$LOG_DIR/jupyter.pid"
}

start_aitoolkit() {
  if [ ! -d "${AITOOLKIT_HOME}/ui" ]; then
    log "ai-toolkit: ${AITOOLKIT_HOME}/ui not found; skipping (install at ${AITOOLKIT_HOME} to enable)"
    return 0
  fi
  if [ ! -d "${AITOOLKIT_HOME}/ui/dist" ] && [ ! -d "${AITOOLKIT_HOME}/ui/.next" ]; then
    log "ai-toolkit: UI not built; skipping. Build with: cd ${AITOOLKIT_HOME}/ui && npm run build"
    return 0
  fi
  if ! have node; then
    log "ai-toolkit: 'node' not on PATH; skipping"
    return 0
  fi
  log "Starting ai-toolkit UI on :${AITOOLKIT_PORT} (home=${AITOOLKIT_HOME})"
  ( cd "${AITOOLKIT_HOME}/ui" && \
    AI_TOOLKIT_AUTH="${AI_TOOLKIT_AUTH}" NODE_ENV=production \
    npm run start >>"$LOG_DIR/aitoolkit.log" 2>&1 ) &
  echo $! > "$LOG_DIR/aitoolkit.pid"
}

start_cloudflared() {
  if [ -n "${CF_TUNNEL_TOKEN}" ]; then
    log "Starting cloudflared tunnel (token)"
    cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" \
      >>"$LOG_DIR/cloudflared.log" 2>&1 &
    echo $! > "$LOG_DIR/cloudflared.pid"
  elif [ -n "${CF_TUNNEL_CONFIG}" ] && [ -f "${CF_TUNNEL_CONFIG}" ]; then
    log "Starting cloudflared tunnel (config: ${CF_TUNNEL_CONFIG})"
    cloudflared tunnel --no-autoupdate --config "${CF_TUNNEL_CONFIG}" run \
      >>"$LOG_DIR/cloudflared.log" 2>&1 &
    echo $! > "$LOG_DIR/cloudflared.pid"
  else
    log "cloudflared: no CF_TUNNEL_TOKEN or CF_TUNNEL_CONFIG set; skipping"
  fi
}

print_endpoints() {
  log "Endpoints:"
  log "  SSH:         ssh -p ${SSH_PORT} nobbby@<host>"
  log "  Portal:      http://<host>:${CADDY_PORT}/"
  log "  JupyterLab:  http://<host>:${JUPYTER_PORT}/  (via portal: /jupyter/)"
  log "  TensorBoard: http://<host>:${TENSORBOARD_PORT}/ (via portal: /tensorboard/)"
  log "  ai-toolkit:  http://<host>:${AITOOLKIT_PORT}/ (if installed at ${AITOOLKIT_HOME})"
}

reap() {
  log "Shutting down..."
  for p in "$LOG_DIR"/*.pid; do
    [ -f "$p" ] || continue
    kill "$(cat "$p")" 2>/dev/null || true
  done
  wait || true
  exit 0
}
trap reap TERM INT

case "$MODE" in
  shell)
    exec sudo -u nobbby -H /usr/bin/zsh -il
    ;;
  oneshot)
    start_sshd
    start_caddy
    start_jupyter
    start_aitoolkit
    start_cloudflared
    sleep 3
    print_endpoints
    ;;
  serve|*)
    start_sshd
    start_caddy
    start_jupyter
    start_aitoolkit
    start_cloudflared
    print_endpoints
    log "Services started; tailing logs. Ctrl+C to stop."
    tail -F "$LOG_DIR"/*.log &
    wait -n
    ;;
esac
