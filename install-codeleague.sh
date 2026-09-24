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
#   ./install-codeleague.sh                 # interactive menu (install / register / status / uninstall)
#   ./install-codeleague.sh --install       # non-interactive install/update (HTTP on :3000)
#   ./install-codeleague.sh --register      # register for a license (email + country)
#   ./install-codeleague.sh --status        # show status
#   ./install-codeleague.sh --uninstall     # stop & remove (keeps data unless you confirm)
#   ./install-codeleague.sh --version       # print the installer version
#
# Optional environment variables (also used as the defaults in the menu):
#   CODELEAGUE_PORT=8080          # host port (default 3000)
#   CODELEAGUE_DIR=/opt/codeleague# install directory (default: ./codeleague)
#   CODELEAGUE_IMAGE=...          # override image tag
#   CODELEAGUE_REPO_PATHS=/srv/git,/mnt/code
#                                 # Existing git repositories ALREADY on this host that
#                                 # Code League should analyse. Each is mounted at the
#                                 # same path inside the container, read-write (sync
#                                 # writes inside .git). Only these directories are
#                                 # exposed -- never the whole filesystem. Repositories
#                                 # imported from GitHub/GitLab/Azure do NOT need this:
#                                 # they are cloned into <dir>/repos automatically.
#                                 # On an update the previous mounts are reused, so this
#                                 # only needs setting when you want to change them.
# ============================================================================

# Installer-script version (the container image is versioned separately by its
# tag). Bump when you change this script; shown by --version.
INSTALLER_VERSION="1.2.0"

IMAGE="${CODELEAGUE_IMAGE:-ghcr.io/speedbitsinfinitytools/codeleague:latest-release}"
CONTAINER_NAME="${CODELEAGUE_CONTAINER:-codeleague}"
INTERNAL_PORT=3000
HOST_PORT="${CODELEAGUE_PORT:-3000}"
DIR="${CODELEAGUE_DIR:-$(pwd)/codeleague}"
COMPOSE="$DIR/docker-compose.yml"

# --- License registration (optional in-installer sign-up) -------------------
# Users without a license can register from the installer: they get a license
# emailed to them, then activate it in-app. Country list and registration go
# through the public Speedbits License Manager API.
#
# This signs up for Code League COMMUNITY (free) and nothing else. Registration
# is deliberately disabled server-side for codeleague-desktop and
# codeleague-server: this script is public, so the key below must be treated as
# public too, and a PAID product that accepted it would let anyone mint a paid
# license by confirming an email. Desktop/Server licenses come from FastSpring,
# a voucher, or Smart In Venture directly.
#
# The key is a product key, not a secret — it only authorises registration for
# the free product, and the key must match the product (a COCO_ key authorises
# Community alone). It is a dedicated key labelled "installer-selfservice" so
# the release pipeline can never overwrite it: prepare-version replaces the key
# row for a given version string, which would silently break every installer
# already in the wild. Override with CODELEAGUE_API_KEY if it is ever rotated;
# rotate by adding a new key and deactivating the old one, so both work during
# the overlap.
LICENSE_API_BASE="${LICENSE_API_BASE:-https://license.speedbits.io}"
PRODUCT_SHORT_CODE="codeleague-community"
REGISTER_WEB_URL="https://www.speedbits.io"
LICENSE_API_KEY="${CODELEAGUE_API_KEY:-COCO_18mqkJSpVnasbE4rduNf}"
# The published registration form is served by the License Manager, not the
# marketing site, so build the fallback link from LICENSE_API_BASE.
REGISTER_PAGE_URL="$LICENSE_API_BASE/register/$PRODUCT_SHORT_CODE"

msg()  { printf '%s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

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

# ----------------------------------------------------------------------------
# Existing git repositories on this host.
#
# Repositories the user already has on the server are mounted at the SAME path
# inside the container as outside ("identity" mounts, e.g. /srv/git:/srv/git).
# That choice matters: the path shown in Code League, stored in its database and
# printed in logs is then the real host path, so there is nothing to translate
# and nothing to get out of step.
#
# They are mounted READ-WRITE on purpose. Sync runs `git fetch --all --prune`
# and writes retention pins with `git update-ref`, both inside .git, so a
# read-only mount yields a repository that can be analysed exactly once and
# never refreshed.
#
# Only the directories named here are exposed -- never the whole filesystem.
# ----------------------------------------------------------------------------

# Identity mounts already present in the compose file: "- X:Y" where X == Y.
# Everything the installer manages itself (data, repos) maps to a different
# path inside, so this cannot pick those up by mistake.
read_existing_repo_mounts() {
    [ -f "$COMPOSE" ] || return 0
    grep -E "^[[:space:]]*-[[:space:]]*/[^:]+:/[^:]+" "$COMPOSE" 2>/dev/null \
        | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/:ro$//' \
        | awk -F: '$1 == $2 { print $1 }' || true
}

# Fills REPO_PATHS (newline-separated, validated).
resolve_repo_paths() {
    REPO_PATHS=""
    REPO_PATHS_REUSED=0
    local candidates=""

    if [ -n "${CODELEAGUE_REPO_PATHS:-}" ]; then
        candidates="$(printf '%s' "$CODELEAGUE_REPO_PATHS" | tr ',' '\n')"
    else
        # An update must keep what the previous install had, or a routine
        # upgrade would silently drop the user's repositories.
        local existing; existing="$(read_existing_repo_mounts)"
        if [ -n "$existing" ]; then
            candidates="$existing"
            REPO_PATHS_REUSED=1
            msg "[INFO] Keeping existing repository mounts:"
            printf '%s\n' "$existing" | while read -r p; do [ -n "$p" ] && msg "         $p"; done
        elif [ -r /dev/tty ]; then
            msg ""
            msg "  Code League clones repositories it imports from GitHub/GitLab/Azure into"
            msg "  $DIR/repos automatically. You only need this if you ALREADY have git"
            msg "  repositories on this server that Code League should analyse."
            local ans; ans="$(prompt '  Existing git repositories on this server? Parent directory (blank for none)' '')"
            candidates="$(printf '%s' "$ans" | tr ',' '\n')"
        fi
    fi

    local p
    while IFS= read -r p; do
        p="$(printf '%s' "$p" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -n "$p" ] || continue
        case "$p" in
            /) err "Refusing to mount the whole filesystem (/). Name the directory holding your repositories instead."; continue ;;
            /*) : ;;
            *)  err "Skipping '$p': must be an absolute path."; continue ;;
        esac
        if [ ! -d "$p" ]; then
            if [ "${REPO_PATHS_REUSED:-0}" = "1" ]; then
                # An update that quietly dropped a mount would take the user's
                # repositories offline with no clue why, so say it plainly.
                err "WARNING: '$p' was mounted before but no longer exists on this host."
                err "         It will NOT be mounted, and repositories under it will stop syncing."
                err "         Restore the directory and re-run, or ignore this if it was intentional."
            else
                err "Skipping '$p': not a directory on this host."
            fi
            continue
        fi
        REPO_PATHS="${REPO_PATHS}${p}"$'\n'
    done <<EOF
$candidates
EOF
}

# Emits the volume lines for the compose file (empty when none).
repo_mount_lines() {
    local p
    printf '%s' "$REPO_PATHS" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf '      - %s:%s\n' "$p" "$p"
    done
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
# Register for a license from inside the installer.
#
# Flow: collect email + country (+ optional name), get consent, then
# POST /api/register with the baked-in installer api_key. The License Manager
# emails a verification link; after verifying, the customer receives their
# license key by email and activates it in-app (Settings → License).
# ----------------------------------------------------------------------------

# Extract a top-level field from a JSON object (jq preferred, sed fallback).
json_get() {  # <json> <key>
    if have jq; then printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null
    else printf '%s' "$1" | sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"?([^\",}]*)\"?.*/\1/p" | head -1; fi
}

# Let the user pick a country. With curl+jq we fetch GET /api/countries and let
# them search by name or 2-letter code; otherwise we just ask for a value (the
# register API accepts either a country name or its 2-letter code).
# All UI is written to stderr; only the chosen value goes to stdout.
pick_country() {
    if have curl && have jq; then
        local list
        list="$(curl -sS --max-time 15 "$LICENSE_API_BASE/api/countries" 2>/dev/null || true)"
        if [ -n "$list" ] && [ "$(printf '%s' "$list" | jq -r '.success // false' 2>/dev/null)" = "true" ]; then
            while true; do
                local term; term="$(prompt '  Country (type part of the name, or a 2-letter code)' '')"
                [ -z "$term" ] && { printf ''; return; }
                local up; up="$(printf '%s' "$term" | tr '[:lower:]' '[:upper:]')"
                local by_code
                by_code="$(printf '%s' "$list" | jq -r --arg c "$up" '.countries[]|select(.code==$c)|.code' 2>/dev/null | head -1)"
                if [ -n "$by_code" ]; then printf '%s' "$by_code"; return; fi
                local low matches
                low="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
                matches="$(printf '%s' "$list" | jq -r --arg t "$low" '.countries[]|select((.name|ascii_downcase)|contains($t))|.code+"  "+.name' 2>/dev/null)"
                if [ -z "$matches" ]; then msg "    No match for \"$term\" — try again." >&2; continue; fi
                msg "    Matches:" >&2
                printf '%s\n' "$matches" | nl -w4 -s') ' >&2
                local sel; sel="$(prompt '  Pick a number (Enter to search again)' '')"
                [ -z "$sel" ] && continue
                local chosen
                chosen="$(printf '%s\n' "$matches" | sed -n "${sel}p" 2>/dev/null | awk '{print $1}')"
                if [ -n "$chosen" ]; then printf '%s' "$chosen"; return; fi
                msg "    Invalid choice." >&2
            done
        fi
    fi
    prompt '  Country (name or 2-letter code)' ''
}

register_for_license() {
    have curl || { err "curl is required to register from the installer (apt install curl)."; return 1; }

    msg ""
    msg "Register for a CodeLeague license (Speedbits):"
    local email name country
    email="$(prompt '  Your email' '')"
    if [ -z "$email" ] || [[ "$email" != *"@"*"."* ]]; then
        err "A valid email address is required."; return 1
    fi
    name="$(prompt '  Your name (optional)' '')"
    country="$(pick_country)"
    if [ -z "$country" ]; then err "A country is required."; return 1; fi

    # API registration has no web page to carry the checkboxes, so the privacy,
    # terms and license acceptances must be sent — and the user must actually
    # agree. Only proceed on an explicit yes.
    msg ""
    msg "  By registering you accept the Privacy Policy, Terms of Service and"
    msg "  License Agreement (see $REGISTER_WEB_URL)."
    local ok; ok="$(prompt '  Do you accept and want to register? (y/N)' 'N')"
    case "$ok" in [Yy]*) ;; *) msg "  Registration cancelled."; return 1 ;; esac

    local payload
    if have jq; then
        payload="$(jq -nc \
            --arg em "$email" --arg nm "$name" --arg co "$country" \
            --arg sc "$PRODUCT_SHORT_CODE" --arg ak "$LICENSE_API_KEY" \
            '{email:$em, name:$nm, country:$co, short_code:$sc, api_key:$ak,
              accepted_privacy:true, accepted_terms:true, accepted_license:true}')"
    else
        payload="$(printf '{"email":"%s","name":"%s","country":"%s","short_code":"%s","api_key":"%s","accepted_privacy":true,"accepted_terms":true,"accepted_license":true}' \
            "$email" "$name" "$country" "$PRODUCT_SHORT_CODE" "$LICENSE_API_KEY")"
    fi

    msg "  Registering with $LICENSE_API_BASE ..."
    local resp code body success message errcode retry
    resp="$(curl -sS --max-time 20 -w $'\n%{http_code}' \
        -X POST "$LICENSE_API_BASE/api/register" \
        -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"
    code="$(printf '%s' "$resp" | tail -n1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    success="$(json_get "$body" success)"
    message="$(json_get "$body" message)"
    errcode="$(json_get "$body" error_code)"; [ -z "$errcode" ] && errcode="$(json_get "$body" error)"

    if [ "$code" = "200" ] && [ "$success" = "true" ]; then
        msg ""
        # resent:true — this address already holds an active Community license, so
        # the SAME key was emailed again. There is no verification link to click;
        # saying otherwise leaves the user waiting for mail that never arrives.
        if [ "$(json_get "$body" resent)" = "true" ]; then
            msg "✅ $email already has a Code League Community license."
            msg "   We've emailed that key to you again — check your mail."
            msg "   Activate it in CodeLeague → Settings → License (then restart the container)."
        else
            msg "✅ Registration submitted for $email."
            msg "   1) Check your inbox and click the verification link."
            msg "   2) Your license key is then emailed to you."
            msg "   3) Activate it in CodeLeague → Settings → License (then restart the container)."
        fi
        return 0
    fi

    # Anything else: explain and fall back to the website registration form.
    case "$code" in
        401) err "The installer's API key was rejected${message:+ ($message)}." ;;
        403) err "Self-service registration isn't available for this build${message:+ ($message)}." ;;
        404) err "The License Manager doesn't know the product '$PRODUCT_SHORT_CODE'${message:+ ($message)}." ;;
        429) # Five attempts per hour PER IP: one machine won't hit this, but an
             # office or lab behind a single NAT will. Never retry automatically.
             retry="$(json_get "$body" retry_after)"
             if printf '%s' "$retry" | grep -qE '^[0-9]+$'; then
                 err "Too many registration attempts — try again in about $(( (retry + 59) / 60 )) minute(s)."
             else
                 err "Too many registration attempts${message:+ ($message)}. Please try again later."
             fi
             msg "   The limit counts your whole network, so colleagues sharing your"
             msg "   connection count too. Re-running now will not help." ;;
        *)   if [ -n "$message" ]; then err "Registration failed: $message"
             else err "Registration failed (HTTP ${code:-no response})."; fi ;;
    esac
    msg "   You can register on the website instead: $REGISTER_PAGE_URL"
    return 1
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
RESTART_REQ="\$DIR/data/.restart-request"
LOG="\$DIR/update.log"
LOCK="\$DIR/.update.lock"
exec 9>"\$LOCK" 2>/dev/null || exit 0
command -v flock >/dev/null 2>&1 && { flock -n 9 || exit 0; }   # no overlapping runs

# Claim the request BEFORE acting on it: the work below replaces the container
# that asked, so a request left on disk would be replayed for ever.
if [ -f "\$REQ" ]; then
  ACTION=update
  rm -f "\$REQ" "\$RESTART_REQ"    # an update restarts too; drop a pending restart
elif [ -f "\$RESTART_REQ" ]; then
  ACTION=restart
  rm -f "\$RESTART_REQ"
else
  exit 0                            # nothing requested
fi

{
  echo "=== \$(date -Iseconds) CodeLeague \$ACTION start ==="
  cd "\$DIR" || exit 1
  if [ "\$ACTION" = update ]; then
    docker compose pull && docker compose up -d && (docker image prune -f || true)
  else
    # Restart ONLY. Never pull here: activating a licence must not quietly move
    # the install onto a different image.
    docker compose restart
  fi
  echo "=== \$(date -Iseconds) CodeLeague \$ACTION done ==="
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
PathExists=$DIR/data/.restart-request
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
        # `actions` is a capability list the app reads: without it the app assumes
        # update-only, so an older install never offers a restart button that
        # nothing would act on.
        printf 'installed-by=install-codeleague.sh\nwatcher=%s\nactions=update,restart\nat=%s\n' "$installed" "$(date -Iseconds 2>/dev/null || date)" \
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
    rm -f "$DIR/data/.host-update-enabled" "$DIR/data/.restart-request" "$DIR/data/.update-request" 2>/dev/null || true
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
    resolve_repo_paths

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
$(repo_mount_lines)
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

    # CodeLeague installs in Community mode regardless; a license only unlocks
    # premium (activated in-app). Offer to register users who don't have one yet.
    msg ""
    local haslic
    haslic="$(prompt 'Do you already have a CodeLeague license from speedbits.io? (y/N)' 'N')"
    case "$haslic" in
        [Yy]*)
            msg "  Great — after install, activate it: CodeLeague → Settings → License." ;;
        *)
            local wantreg
            wantreg="$(prompt 'Register now to get a license by email? (Y/n)' 'Y')"
            case "$wantreg" in
                [Nn]*) msg "  No problem — you can register later ($0 --register) or in-app." ;;
                *)     register_for_license || true ;;   # never block the install
            esac ;;
    esac

    install
}

main_menu() {
    while true; do
        msg ""
        msg "============================================================"
        msg "  CodeLeague — what would you like to do?"
        msg "============================================================"
        msg "  1) Install / update"
        msg "  2) Register for a license (speedbits.io)"
        msg "  3) Show status"
        msg "  4) Uninstall"
        msg "  5) Quit"
        local choice
        choice="$(prompt '  Select' '1')"
        case "$choice" in
            1) interactive_install; break ;;
            2) register_for_license || true ;;
            3) show_status ;;
            4) uninstall; break ;;
            5|q|Q) msg "Bye."; break ;;
            *) msg "  Please choose 1-5." ;;
        esac
    done
}

case "${1:-}" in
    --status)     HOST_PORT="${CODELEAGUE_PORT:-$HOST_PORT}"; show_status ;;
    --uninstall)  uninstall ;;
    --install)    install ;;                          # non-interactive (env/defaults)
    --register)   register_for_license ;;             # register for a license, then exit
    --version|-V) msg "install-codeleague.sh $INSTALLER_VERSION" ;;
    --help|-h)    awk 'NR>4 && /^# ={10,}/ { exit } NR>4' "$0" | sed 's/^# \{0,1\}//' ;;
    ""|--menu)    main_menu ;;                        # interactive menu + prompts
    *)            err "Unknown option: $1"; msg "Use: $0 [--menu|--install|--register|--status|--uninstall|--version|--help]"; exit 1 ;;
esac
