#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# CodeLeague — standalone Docker installer
# (c) 2025 Smart In Venture / www.speedbits.io
#
# For users who want to run CodeLeague WITHOUT Infinity Tools. It just needs
# Docker. CodeLeague boots in Community mode — activate premium in the app
# afterwards (CodeLeague → Settings → License, or the first-run screen).
#
# Usage:
#   ./install-codeleague.sh                 # interactive menu (install / status / uninstall)
#   ./install-codeleague.sh --install       # non-interactive install/update (HTTP on :3000)
#   ./install-codeleague.sh --status        # show status
#   ./install-codeleague.sh --uninstall     # stop & remove (keeps data unless you confirm)
#
# Optional environment variables (also used as the defaults in the menu):
#   CODELEAGUE_PORT=8080          # host port (default 3000)
#   CODELEAGUE_DIR=/opt/codeleague# install directory (default: ./codeleague)
#   CODELEAGUE_IMAGE=...          # override image tag
# ============================================================================

IMAGE="${CODELEAGUE_IMAGE:-ghcr.io/speedbitsinfinitytools/codeleague:latest-release}"
CONTAINER_NAME="${CODELEAGUE_CONTAINER:-codeleague}"
INTERNAL_PORT=3000
HOST_PORT="${CODELEAGUE_PORT:-3000}"
DIR="${CODELEAGUE_DIR:-$(pwd)/codeleague}"
COMPOSE="$DIR/docker-compose.yml"

msg()  { printf '%s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

server_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="localhost"
    printf '%s' "$ip"
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        err "Docker is not installed. Install Docker Engine first: https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        err "Docker Compose v2 is not available ('docker compose'). Update Docker or install the compose plugin."
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        err "Cannot talk to the Docker daemon. Start Docker, or run this with sudo / as a docker-group user."
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Secrets — generate once, REUSE on every reinstall/update.
#   JWT_SECRET  : rotating it signs everyone out.
#   CF_ENC_KEY  : encrypts stored Git tokens; changing it makes them
#                 undecryptable, so it MUST stay stable.
# ----------------------------------------------------------------------------
read_existing_secret() {  # <key-name>
    [ -f "$COMPOSE" ] || return 0
    grep -E "^[[:space:]]*$1:" "$COMPOSE" 2>/dev/null | head -1 \
        | sed -E "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"]*)\"?.*$/\1/" || true
}

resolve_secrets() {
    JWT_SECRET="$(read_existing_secret JWT_SECRET)"
    if [ -n "$JWT_SECRET" ]; then
        msg "[INFO] Reusing existing JWT_SECRET."
    else
        JWT_SECRET="$(openssl rand -base64 48 2>/dev/null | tr -d '=+/\n' | cut -c1-48)"
        [ ${#JWT_SECRET} -ge 32 ] || { err "Could not generate JWT_SECRET (need openssl)."; exit 1; }
        msg "[INFO] Generated a new JWT_SECRET."
    fi

    CF_ENC_KEY="$(read_existing_secret CF_ENC_KEY)"
    if [ -n "$CF_ENC_KEY" ]; then
        msg "[INFO] Reusing existing CF_ENC_KEY (Git token encryption)."
    else
        CF_ENC_KEY="$(openssl rand -hex 32 2>/dev/null)"
        [ ${#CF_ENC_KEY} -eq 64 ] || { err "Could not generate CF_ENC_KEY (need openssl)."; exit 1; }
        msg "[INFO] Generated a new CF_ENC_KEY — Git token AES encryption enabled."
    fi
}

# Stable machine id (persisted with the data so reinstalls reuse the same
# activation seat instead of claiming a new one).
resolve_machine_id() {
    local f="$DIR/data/.machine_id"
    if [ -f "$f" ]; then
        MACHINE_ID="$(head -1 "$f" | tr -d '[:space:]')"
    elif [ -r /etc/machine-id ]; then
        MACHINE_ID="$(cat /etc/machine-id | tr -d '[:space:]')"
    else
        MACHINE_ID="$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -c1-32)"
    fi
    mkdir -p "$DIR/data"
    printf '%s\n' "$MACHINE_ID" > "$f"
    chmod 600 "$f" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Host-side self-update.
#
# A container can't recreate itself, so we install a tiny HOST updater that the
# app can trigger. The app writes "<DIR>/data/.update-request" (its data volume);
# a watcher on the host runs codeleague-update.sh, which does
# `docker compose pull && up -d`. We mark availability with
# "<DIR>/data/.host-update-enabled" so the app shows an in-app "Update now" button
# (and falls back to the manual command when the marker is absent).
# ----------------------------------------------------------------------------
install_host_updater() {
    local update_script="$DIR/codeleague-update.sh"

    # 1) The updater itself (runs on the host, out-of-band from the container).
    cat > "$update_script" <<EOF
#!/usr/bin/env bash
# Auto-installed by install-codeleague.sh. Triggered when the app writes
# "$DIR/data/.update-request". Pulls the new image and recreates the container.
set -uo pipefail
DIR="$DIR"
REQ="\$DIR/data/.update-request"
LOG="\$DIR/update.log"
LOCK="\$DIR/.update.lock"
exec 9>"\$LOCK" 2>/dev/null || exit 0
command -v flock >/dev/null 2>&1 && { flock -n 9 || exit 0; }   # no overlapping runs
[ -f "\$REQ" ] || exit 0                                        # nothing requested
rm -f "\$REQ"                                                   # claim the request
{
  echo "=== \$(date -Iseconds) CodeLeague update start ==="
  cd "\$DIR" || exit 1
  docker compose pull && docker compose up -d && (docker image prune -f || true)
  echo "=== \$(date -Iseconds) CodeLeague update done ==="
} >>"\$LOG" 2>&1
EOF
    chmod +x "$update_script"

    # 2) A watcher: prefer a systemd path-unit (event-driven) when we're root with
    #    systemd; otherwise a 1-minute cron poll (works without root).
    local installed=""
    if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" = "0" ] && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/codeleague-update.service <<EOF
[Unit]
Description=CodeLeague self-update (pull new image + recreate container)
[Service]
Type=oneshot
ExecStart=$update_script
EOF
        cat > /etc/systemd/system/codeleague-update.path <<EOF
[Unit]
Description=Watch for CodeLeague in-app update requests
[Path]
PathExists=$DIR/data/.update-request
Unit=codeleague-update.service
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now codeleague-update.path >/dev/null 2>&1 && installed="systemd"
    fi
    if [ -z "$installed" ] && command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -vF "$update_script"; echo "* * * * * $update_script" ) \
            | crontab - 2>/dev/null && installed="cron"
    fi

    mkdir -p "$DIR/data"
    if [ -n "$installed" ]; then
        printf 'installed-by=install-codeleague.sh\nwatcher=%s\nat=%s\n' "$installed" "$(date -Iseconds 2>/dev/null || date)" \
            > "$DIR/data/.host-update-enabled"
        msg "[INFO] Host updater installed ($installed) — the in-app \"Update now\" button is enabled."
    else
        rm -f "$DIR/data/.host-update-enabled" 2>/dev/null || true
        msg "[WARN] Could not install a host updater (needs root+systemd or crontab)."
        msg "       In-app updates will show the manual command instead — that still works."
    fi
}

remove_host_updater() {
    if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
        systemctl disable --now codeleague-update.path >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/codeleague-update.path /etc/systemd/system/codeleague-update.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -vF "$DIR/codeleague-update.sh" | crontab - 2>/dev/null || true
    fi
    rm -f "$DIR/data/.host-update-enabled" 2>/dev/null || true
}

show_status() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        msg "✅ CodeLeague is RUNNING"
        msg "   URL:       http://$(server_ip):${HOST_PORT}"
        msg "   Data:      $DIR/data    Repos: $DIR/repos"
        msg "   License:   activate in-app (CodeLeague → Settings → License)"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        msg "🟡 CodeLeague is STOPPED   (start: cd $DIR && docker compose up -d)"
    else
        msg "❌ CodeLeague is NOT INSTALLED   (install: $0)"
    fi
}

uninstall() {
    require_docker
    msg "Stopping and removing CodeLeague..."
    remove_host_updater
    if [ -f "$COMPOSE" ]; then ( cd "$DIR" && docker compose down ) || true; fi
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [ -d "$DIR/data" ]; then
        read -r -p "Also delete the data folder ($DIR/data — your repos & DB)? (y/N): " reply || reply=""
        case "$reply" in
            [Yy]*) rm -rf "$DIR"; msg "Removed $DIR." ;;
            *)     rm -f "$COMPOSE"; msg "Kept your data in $DIR (removed compose only)." ;;
        esac
    fi
    msg "Done."
}

install() {
    require_docker
    command -v openssl >/dev/null 2>&1 || { err "openssl is required (apt install openssl)."; exit 1; }

    mkdir -p "$DIR/data" "$DIR/repos"
    resolve_secrets
    resolve_machine_id

    msg "[INFO] Writing $COMPOSE ..."
    cat > "$COMPOSE" <<EOF
services:
  codeleague:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      NODE_ENV: production
      DATA_DIR: /app/data
      JWT_SECRET: "${JWT_SECRET}"
      CF_ENC_KEY: "${CF_ENC_KEY}"
      MACHINE_ID: "${MACHINE_ID}"
    ports:
      - "${HOST_PORT}:${INTERNAL_PORT}"
    volumes:
      - ${DIR}/data:/app/data
      - ${DIR}/repos:/repos
EOF
    chmod 600 "$COMPOSE" 2>/dev/null || true   # holds JWT_SECRET / CF_ENC_KEY

    msg "[INFO] Pulling image and starting..."
    ( cd "$DIR" && docker compose pull && docker compose up -d )

    sleep 4
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        msg ""
        msg "============================================================"
        msg "✅ CodeLeague is up!"
        msg "   Open:      http://$(server_ip):${HOST_PORT}"
        msg "   Data dir:  $DIR/data     Repos: $DIR/repos"
        msg ""
        msg "🔑 It runs in Community mode. To unlock premium, activate your"
        msg "   license IN-APP: CodeLeague → Settings → License (a first-run"
        msg "   screen also prompts you); premium unlocks after activation."
        msg ""
        msg "   Tip: to expose it over HTTPS, put your own reverse proxy"
        msg "   (nginx/Caddy/Traefik) in front of http://127.0.0.1:${HOST_PORT}."
        msg "============================================================"
    else
        err "Container did not stay up. Check logs:  docker logs ${CONTAINER_NAME}"
        exit 1
    fi

    # Enable in-app one-click updates (host-side; container can't recreate itself).
    install_host_updater
}

# ----------------------------------------------------------------------------
# Interactive helpers. Prompts read from /dev/tty so they work even when the
# script is piped (curl ... | bash); if there's no TTY the default is used, so
# non-interactive/automated runs still succeed.
# ----------------------------------------------------------------------------
prompt() {  # prompt <text> <default> -> echoes the answer
    local text="$1" def="$2" ans=""
    if [ -r /dev/tty ]; then
        read -r -p "$text [$def]: " ans </dev/tty || ans=""
    fi
    printf '%s' "${ans:-$def}"
}

interactive_install() {
    msg ""
    msg "Configure your CodeLeague install (press Enter to accept each default):"
    HOST_PORT="$(prompt '  HTTP port' "$HOST_PORT")"
    DIR="$(prompt '  Install directory' "$DIR")"
    COMPOSE="$DIR/docker-compose.yml"
    # No license is collected — CodeLeague boots in Community mode and you
    # activate premium in-app (Settings → License). See the post-install note.
    install
}

main_menu() {
    while true; do
        msg ""
        msg "============================================================"
        msg "  CodeLeague — what would you like to do?"
        msg "============================================================"
        msg "  1) Install / update"
        msg "  2) Show status"
        msg "  3) Uninstall"
        msg "  4) Quit"
        local choice
        choice="$(prompt '  Select' '1')"
        case "$choice" in
            1) interactive_install; break ;;
            2) show_status ;;
            3) uninstall; break ;;
            4|q|Q) msg "Bye."; break ;;
            *) msg "  Please choose 1-4." ;;
        esac
    done
}

case "${1:-}" in
    --status)     HOST_PORT="${CODELEAGUE_PORT:-$HOST_PORT}"; show_status ;;
    --uninstall)  uninstall ;;
    --install)    install ;;                          # non-interactive (env/defaults)
    --help|-h)    sed -n '4,21p' "$0" | sed 's/^# \{0,1\}//' ;;
    ""|--menu)    main_menu ;;                        # interactive menu + prompts
    *)            err "Unknown option: $1"; msg "Use: $0 [--menu|--install|--status|--uninstall|--help]"; exit 1 ;;
esac
