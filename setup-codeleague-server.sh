#!/bin/bash
set -e

# ============================================================================
# Code League — Server (Docker) Installer     (c) Smart In Venture / speedbits.io
# ============================================================================
# Self-contained installer for the Code League SERVER edition. Unlike the
# Infinity Tools bundle installer, this script depends on NOTHING but bash +
# docker + curl — so a customer who bought only the Server tier can run it.
#
# It validates your license, pins a stable machine-id (so reinstalls don't burn
# activation seats), writes a docker-compose.yml, pulls the encrypted image and
# starts it. Re-running --install updates in place (pull latest-release + recreate).
#
# Usage:
#   curl -fsSL <this-url> -o setup-codeleague-server.sh
#   sudo bash setup-codeleague-server.sh --install     # install or update
#   sudo bash setup-codeleague-server.sh --status
#   sudo bash setup-codeleague-server.sh --uninstall   # remove container, keep data
#   sudo bash setup-codeleague-server.sh --deleteall    # remove EVERYTHING
#
# Environment (all optional — you'll be prompted otherwise):
#   CODELEAGUE_LICENSE_EMAIL   license email
#   CODELEAGUE_LICENSE_KEY     license key (COLE-...)
#   CODELEAGUE_DIR             install/data dir            (default /opt/codeleague)
#   CODELEAGUE_PORT            host port for standalone     (default 3000)
#   CODELEAGUE_USE_TRAEFIK     true to attach to Traefik    (default false)
#   CODELEAGUE_DOMAIN          FQDN when using Traefik
#   PROXY_NETWORK             external Traefik network      (default infinity)
#   CODELEAGUE_IMAGE          override the image reference
#   CODELEAGUE_EXTRA_CA_CERTS host CA file/dir for TLS-intercepted networks
# ============================================================================

C_OK="\033[38;5;46m"; C_ERR="\033[38;5;196m"; C_INFO="\033[38;5;39m"; C_WARN="\033[38;5;214m"; C_RST="\033[0m"
info()  { echo -e "${C_INFO}[INFO]${C_RST} $*"; }
ok()    { echo -e "${C_OK}$*${C_RST}"; }
warn()  { echo -e "${C_WARN}[WARN]${C_RST} $*"; }
err()   { echo -e "${C_ERR}[ERROR]${C_RST} $*" >&2; }

# ---- constants --------------------------------------------------------------
CODELEAGUE_IMAGE="${CODELEAGUE_IMAGE:-ghcr.io/speedbitsinfinitytools/codeleague:latest-release}"
CONTAINER_PORT=3000
CODELEAGUE_DIR="${CODELEAGUE_DIR:-/opt/codeleague}"
CONTAINER_NAME="${CONTAINER_NAME:-codeleague}"
SSL_PROXY_NAME="${CONTAINER_NAME}-ssl-proxy"
REGISTER_URL="https://www.speedbits.io"
LICENSE_API_ENDPOINT="${CODELEAGUE_LICENSE_URL:-https://license.speedbits.io/api/installer/validate-license}"
# Public installer client-id for the Code League Server product (not a secret;
# unlocks nothing without a valid email+key). Rotate in the License Manager.
CODELEAGUE_INSTALLER_API_KEY="${CODELEAGUE_INSTALLER_API_KEY:-COLE_mdvFEaSgCUuTZhuq8i6C}"
CODELEAGUE_INSTALLER_VERSION="1.0.0"

# ---- machine id (self-contained; mirrors Infinity Tools' algorithm) ---------
# Preference order: an existing Infinity Tools license.conf MACHINE_ID (so hosts
# that ALSO run Infinity Tools report one device), else our own persisted cache,
# else derive from /etc/machine-id → dbus → product_uuid → md5(host-ip-mac).
resolve_machine_id() {
  local cache="$CODELEAGUE_DIR/data/.machine_id"
  local val=""

  # 1) Reuse Infinity Tools' registered id if present.
  local f
  for f in \
    "/opt/speedbits/infinitytools/installed/license.conf" \
    "/opt/speedbits/infinitytools/installed/license-commercial.conf" \
    "/opt/speedbits/infinitytools/installed/license-community.conf"; do
    if [ -r "$f" ]; then
      val=$(grep -E '^[[:space:]]*MACHINE_ID[[:space:]]*=' "$f" 2>/dev/null | head -1 \
            | sed -E 's/^[[:space:]]*MACHINE_ID[[:space:]]*=[[:space:]]*"?([^"#[:space:]]+)"?.*$/\1/' \
            | tr -d ' \t\r\n')
      [ -n "$val" ] && [ ${#val} -ge 16 ] && { printf '%s' "$val"; return 0; }
    fi
  done

  # 2) Our own persisted cache.
  if [ -r "$cache" ]; then
    val=$(tr -d ' \t\r\n' < "$cache" 2>/dev/null || true)
    [ -n "$val" ] && [ ${#val} -ge 16 ] && { printf '%s' "$val"; return 0; }
  fi

  # 3) Derive fresh.
  if [ -f /etc/machine-id ]; then val=$(tr -d ' \t\r\n' < /etc/machine-id 2>/dev/null || true)
  elif [ -f /var/lib/dbus/machine-id ]; then val=$(tr -d ' \t\r\n' < /var/lib/dbus/machine-id 2>/dev/null || true)
  elif [ -f /sys/class/dmi/id/product_uuid ]; then val=$(tr -d ' \t\r\n' < /sys/class/dmi/id/product_uuid 2>/dev/null || true)
  fi
  if [ -z "$val" ]; then
    local hn ip mac
    hn=$(hostname 2>/dev/null || echo unknown)
    ip=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d/ -f1 || echo 0.0.0.0)
    mac=$(ip link show 2>/dev/null | grep -i 'link/ether' | head -1 | awk '{print $2}' || echo 00:00:00:00:00:00)
    command -v md5sum >/dev/null 2>&1 && val=$(echo "${hn}-${ip}-${mac}" | md5sum | cut -d' ' -f1)
  fi
  if [ -z "$val" ] || [ ${#val} -lt 16 ]; then
    err "Could not derive a stable machine_id on this host."
    return 1
  fi

  mkdir -p "$CODELEAGUE_DIR/data" 2>/dev/null || true
  printf '%s\n' "$val" > "$cache" 2>/dev/null || true
  chmod 600 "$cache" 2>/dev/null || true
  printf '%s' "$val"
}

generate_jwt_secret() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -base64 48 | tr -d "=+/\n" | cut -c1-48
  elif [ -r /dev/urandom ]; then head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-48
  else date +%s%N | sha256sum | cut -c1-48; fi
}

# ---- license validation -----------------------------------------------------
validate_license() {
  local email="$1" key="$2" machine_id="$3"
  if [ -z "$email" ] || [[ "$email" != *"@"*"."* ]]; then err "'$email' is not a valid email."; return 1; fi
  if [ -z "$key" ]; then err "License key is empty."; return 1; fi
  if [[ "$key" =~ [\"\'\$\`\\] ]] || [[ "$email" =~ [\"\'\$\`\\] ]]; then
    err "Credentials contain characters not expected in a SpeedBits key."; return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not installed; skipping online check (container will validate on start)."; return 0
  fi

  local payload
  if command -v jq >/dev/null 2>&1; then
    payload=$(jq -n --arg ak "$CODELEAGUE_INSTALLER_API_KEY" --arg lk "$key" --arg em "$email" \
      --arg mi "$machine_id" --arg vr "$CODELEAGUE_INSTALLER_VERSION" --arg pe "codeleague" \
      '{api_key:$ak, license_key:$lk, email:$em, machine_id:$mi, version:$vr, product_edition:$pe}')
  else
    payload=$(printf '{"api_key":"%s","license_key":"%s","email":"%s","machine_id":"%s","version":"%s","product_edition":"codeleague"}' \
      "$CODELEAGUE_INSTALLER_API_KEY" "$key" "$email" "$machine_id" "$CODELEAGUE_INSTALLER_VERSION")
  fi

  info "Validating license with $LICENSE_API_ENDPOINT ..."
  local response rc
  response=$(curl -sS --max-time 15 -X POST "$LICENSE_API_ENDPOINT" -H 'Content-Type: application/json' -d "$payload" 2>&1) || rc=$?
  if [ -n "${rc:-}" ] || [ -z "$response" ]; then
    warn "Could not reach the license server; proceeding (the container will re-validate on startup)."; return 0
  fi

  local success valid message tier expires
  if command -v jq >/dev/null 2>&1 && echo "$response" | jq -e . >/dev/null 2>&1; then
    success=$(echo "$response" | jq -r '.success // empty')
    valid=$(echo "$response" | jq -r '.valid // empty')
    message=$(echo "$response" | jq -r '.message // empty')
    tier=$(echo "$response" | jq -r '.tier_name // empty')
    expires=$(echo "$response" | jq -r '.license_expires // empty')
  else
    success=$(echo "$response" | sed -nE 's/.*"success"[[:space:]]*:[[:space:]]*(true|false).*/\1/p' | head -1)
    valid=$(echo "$response"   | sed -nE 's/.*"valid"[[:space:]]*:[[:space:]]*(true|false).*/\1/p'   | head -1)
    message=$(echo "$response" | sed -nE 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p'     | head -1)
  fi

  if [ "$success" = "true" ] && [ "$valid" = "true" ]; then
    ok "License validated."
    [ -n "$tier" ]    && echo "   • Tier:    $tier"
    [ -n "$expires" ] && echo "   • Expires: $expires"
    return 0
  fi
  err "License validation failed."
  [ -n "$message" ] && echo "   Server says: $message"
  echo "   Manage your license / seats at $REGISTER_URL"
  return 1
}

# ---- read existing creds from a previous install ----------------------------
read_existing_creds() {
  local compose="$CODELEAGUE_DIR/docker-compose.yml"
  EXISTING_EMAIL=""; EXISTING_KEY=""; EXISTING_JWT=""
  [ -f "$compose" ] || return 0
  EXISTING_EMAIL=$(grep -E '^[[:space:]]*LICENSE_EMAIL:' "$compose" 2>/dev/null | head -1 | sed -E 's/.*LICENSE_EMAIL:[[:space:]]*"?([^"]*)"?.*/\1/')
  EXISTING_KEY=$(grep -E '^[[:space:]]*LICENSE_KEY:' "$compose" 2>/dev/null | head -1 | sed -E 's/.*LICENSE_KEY:[[:space:]]*"?([^"]*)"?.*/\1/')
  EXISTING_JWT=$(grep -E '^[[:space:]]*JWT_SECRET:' "$compose" 2>/dev/null | head -1 | sed -E 's/.*JWT_SECRET:[[:space:]]*"?([^"]*)"?.*/\1/')
}

# ---- compose writer ---------------------------------------------------------
write_compose() {
  local email="$1" key="$2" jwt="$3" mid="$4"
  local ca_volume="" ca_env=""
  local host_ca=""
  for c in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
    [ -f "$c" ] && { host_ca="$c"; break; }
  done
  if [ -n "$host_ca" ]; then
    ca_volume="      - ${host_ca}:/etc/ssl/certs/ca-certificates.crt:ro"
    ca_env='      NODE_EXTRA_CA_CERTS: "/etc/ssl/certs/ca-certificates.crt"'
  fi
  local extra_ca_volume="" extra_ca_env=""
  if [ -n "${CODELEAGUE_EXTRA_CA_CERTS:-}" ] && [ -e "${CODELEAGUE_EXTRA_CA_CERTS}" ]; then
    extra_ca_volume="      - ${CODELEAGUE_EXTRA_CA_CERTS}:/opt/codeleague-extra-ca:ro"
    extra_ca_env='      EXTRA_CA_CERTS: "/opt/codeleague-extra-ca"'
  fi

  if [ "${USE_TRAEFIK}" = "true" ]; then
    local network="${PROXY_NETWORK:-infinity}"
    cat > "$CODELEAGUE_DIR/docker-compose.yml" <<EOF
services:
  codeleague:
    image: ${CODELEAGUE_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: on-failure:5
    security_opt:
      - no-new-privileges:true
    volumes:
      - ${CODELEAGUE_DIR}/data:/app/data
      - ${CODELEAGUE_DIR}/repos:/repos
${ca_volume}
${extra_ca_volume}
    environment:
      NODE_ENV: production
      DATA_DIR: /app/data
      LICENSE_EMAIL: "${email}"
      LICENSE_KEY: "${key}"
      JWT_SECRET: "${jwt}"
      MACHINE_ID: "${mid}"
${ca_env}
${extra_ca_env}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${CONTAINER_PORT}/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.codeleague.rule=Host(\`${DOMAIN}\`)"
      - "traefik.http.routers.codeleague.entrypoints=websecure"
      - "traefik.http.routers.codeleague.tls.certresolver=myresolver"
      - "traefik.http.services.codeleague-app.loadbalancer.server.port=${CONTAINER_PORT}"
    networks:
      - ${network}

networks:
  ${network}:
    external: true
EOF
  else
    cat > "$CODELEAGUE_DIR/docker-compose.yml" <<EOF
services:
  codeleague:
    image: ${CODELEAGUE_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: on-failure:5
    security_opt:
      - no-new-privileges:true
    volumes:
      - ${CODELEAGUE_DIR}/data:/app/data
      - ${CODELEAGUE_DIR}/repos:/repos
${ca_volume}
${extra_ca_volume}
    environment:
      NODE_ENV: production
      DATA_DIR: /app/data
      LICENSE_EMAIL: "${email}"
      LICENSE_KEY: "${key}"
      JWT_SECRET: "${jwt}"
      MACHINE_ID: "${mid}"
${ca_env}
${extra_ca_env}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${CONTAINER_PORT}/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    ports:
      - "${HOST_PORT}:${CONTAINER_PORT}"
EOF
  fi
  # Collapse blank lines produced by empty CA blocks, then lock down the file.
  sed -i '/^[[:space:]]*$/d' "$CODELEAGUE_DIR/docker-compose.yml" 2>/dev/null || true
  chmod 600 "$CODELEAGUE_DIR/docker-compose.yml" 2>/dev/null || true
}

# ---- checks -----------------------------------------------------------------
require_root() { [ "$(id -u)" = "0" ] || { err "Please run as root (sudo)."; exit 1; }; }
require_docker() {
  command -v docker >/dev/null 2>&1 || { err "Docker is not installed. Install Docker first: https://docs.docker.com/engine/install/"; exit 1; }
  docker compose version >/dev/null 2>&1 || { err "Docker Compose v2 is required (docker compose)."; exit 1; }
}

server_ip() { hostname -I 2>/dev/null | awk '{print $1}' || echo localhost; }

# ---- actions ----------------------------------------------------------------
do_status() {
  echo "================ Code League (server) status ================"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    ok "Running"
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    warn "Installed but stopped"
  else
    echo "Not installed."
  fi
  if [ -f "$CODELEAGUE_DIR/docker-compose.yml" ]; then
    echo "  • Dir:     $CODELEAGUE_DIR"
    echo "  • Image:   $CODELEAGUE_IMAGE"
    read_existing_creds
    [ -n "$EXISTING_EMAIL" ] && echo "  • License: $EXISTING_EMAIL"
    echo "  • Update:  sudo bash $0 --install"
    echo "  • Logs:    docker logs $CONTAINER_NAME"
  else
    echo "  Install:   sudo bash $0 --install"
  fi
  echo "============================================================="
}

do_help() {
  cat <<EOF

Code League — Server installer

  sudo bash $0 --install     Install, or update an existing install
  sudo bash $0 --status      Show current status
  sudo bash $0 --uninstall   Stop & remove the container (keeps your data)
  sudo bash $0 --deleteall   Remove the container AND all data (irreversible)
  sudo bash $0 --help        This help

A paid Code League Server license is required. Get one at $REGISTER_URL
EOF
}

do_uninstall() {
  require_root
  info "Stopping Code League..."
  ( cd "$CODELEAGUE_DIR" 2>/dev/null && docker compose down ) 2>/dev/null || true
  docker rm -f "$CONTAINER_NAME" "$SSL_PROXY_NAME" 2>/dev/null || true
  ok "Removed the container. Your data remains in $CODELEAGUE_DIR (use --deleteall to wipe)."
}

do_deleteall() {
  require_root
  echo "This PERMANENTLY DELETES the container and everything in $CODELEAGUE_DIR"
  read -r -p "Type 'DELETE' to confirm: " c
  [ "$c" = "DELETE" ] || { echo "Cancelled."; exit 0; }
  ( cd "$CODELEAGUE_DIR" 2>/dev/null && docker compose down ) 2>/dev/null || true
  docker rm -f "$CONTAINER_NAME" "$SSL_PROXY_NAME" 2>/dev/null || true
  rm -rf "$CODELEAGUE_DIR" 2>/dev/null || true
  ok "Deleted."
}

do_install() {
  require_root
  require_docker

  echo ""
  echo "  🏆  Code League — Server edition installer"
  echo "      (c) Smart In Venture / www.speedbits.io"
  echo ""

  local is_update=false
  if [ -f "$CODELEAGUE_DIR/docker-compose.yml" ]; then
    is_update=true
    info "Existing install found in $CODELEAGUE_DIR — updating in place."
    ( cd "$CODELEAGUE_DIR" && docker compose down ) 2>/dev/null || true
  fi

  mkdir -p "$CODELEAGUE_DIR/data" "$CODELEAGUE_DIR/repos"

  local mid; mid=$(resolve_machine_id) || exit 1
  info "Machine id: ${mid:0:8}…${mid: -4}"

  # Credentials: env → existing compose → prompt.
  read_existing_creds
  local email="" key=""
  if [ -n "${CODELEAGUE_LICENSE_EMAIL:-}" ] && [ -n "${CODELEAGUE_LICENSE_KEY:-}" ]; then
    email="$CODELEAGUE_LICENSE_EMAIL"; key="$CODELEAGUE_LICENSE_KEY"
  elif [ -n "$EXISTING_EMAIL" ] && [ -n "$EXISTING_KEY" ]; then
    email="$EXISTING_EMAIL"; key="$EXISTING_KEY"
    info "Reusing stored license ($email)."
  else
    echo "A Code League Server license is required (get one at $REGISTER_URL)."
    while :; do
      read -r -p "License email: " email </dev/tty || true
      read -r -p "License key:   " key </dev/tty || true
      key=$(echo "$key" | xargs | tr '[:lower:]' '[:upper:]')
      [ -n "$email" ] && [ -n "$key" ] && break
      err "Both email and key are required."
    done
  fi
  key=$(echo "$key" | xargs | tr '[:lower:]' '[:upper:]')

  if ! validate_license "$email" "$key" "$mid"; then
    err "Cannot proceed without a valid license."
    exit 1
  fi

  # JWT secret: reuse or generate.
  local jwt="$EXISTING_JWT"
  if [ -z "$jwt" ]; then jwt=$(generate_jwt_secret); fi

  # Networking mode.
  USE_TRAEFIK="${CODELEAGUE_USE_TRAEFIK:-false}"
  DOMAIN="${CODELEAGUE_DOMAIN:-}"
  HOST_PORT="${CODELEAGUE_PORT:-3000}"
  if [ "$USE_TRAEFIK" = "true" ]; then
    if [ -z "$DOMAIN" ]; then err "CODELEAGUE_USE_TRAEFIK=true requires CODELEAGUE_DOMAIN."; exit 1; fi
    if ! docker network ls --format '{{.Name}}' | grep -q "^${PROXY_NETWORK:-infinity}$"; then
      err "Traefik network '${PROXY_NETWORK:-infinity}' not found. Create it or run your reverse proxy first."; exit 1
    fi
  fi

  info "Writing $CODELEAGUE_DIR/docker-compose.yml"
  write_compose "$email" "$key" "$jwt" "$mid"

  info "Pulling image (this can take a minute)..."
  ( cd "$CODELEAGUE_DIR" && docker compose pull )
  info "Starting..."
  ( cd "$CODELEAGUE_DIR" && docker compose up -d )

  echo ""
  if [ "$is_update" = true ]; then ok "Update complete."; else ok "Installation complete."; fi
  if [ "$USE_TRAEFIK" = "true" ]; then
    echo "  Access: https://${DOMAIN}"
  else
    echo "  Access: http://$(server_ip):${HOST_PORT}"
  fi
  echo "  Logs:   docker logs -f ${CONTAINER_NAME}"
  echo ""
}

# ---- dispatch ---------------------------------------------------------------
case "${1:-}" in
  --install|--update) do_install ;;
  --status)           do_status ;;
  --uninstall)        do_uninstall ;;
  --deleteall)        do_deleteall ;;
  --help|-h)          do_help ;;
  "")                 do_status; do_help ;;
  *)                  err "Unknown option: $1"; do_help; exit 1 ;;
esac
