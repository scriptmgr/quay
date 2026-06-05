#!/usr/bin/env sh
# shellcheck shell=sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202606022117-git
# @@Author           :  Jason Hempstead
# @@Contact          :  git-admin@casjaysdev.pro
# @@License          :  MIT or LICENSE.md
# @@ReadME           :  install.sh --help | README.md
# @@Copyright        :  Copyright: (c) 2026 Jason Hempstead, Casjays Developments
# @@Created          :  Monday, June 01, 2026 00:46 EDT
# @@File             :  install.sh
# @@Description      :  Self-hosted Quay registry stack installer (Quay + Postgres + Redis + Clair)
# @@Changelog        :  Rewrite: volumes/ paths, convention env vars, single .env, full compose conventions
# @@TODO             :  None
# @@Other            :  Distro-agnostic, idempotent, POSIX sh; reverse proxy TLS handled externally
# @@Resource         :  https://quay.io/
# @@Terminal App     :  yes
# @@sudo/root        :  yes
# @@Template         :  shell/sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC2001,SC2003,SC2016,SC2031,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329,SC3043
# - - - - - - - - - - - - - - - - - - - - - - - - -
VERSION="202606022117-git"
APPNAME="${0##*/}"
# - - - - - - - - - - - - - - - - - - - - - - - - -
set -e
umask 077
# - - - - - - - - - - - - - - - - - - - - - - - - -
__ts() { date +"%Y-%m-%d %H:%M:%S"; }
__version() { printf '%s %s\n' "$APPNAME" "$VERSION"; }
__info() { printf '%s %s\n' "$(__ts)" "$*"; }
__warn() { printf '%s WARN: %s\n' "$(__ts)" "$*"; }
__fail() { printf '%s ERROR: %s\n' "$(__ts)" "$*" >&2; exit 1; }
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Check that a required command is present
__need() { command -v "$1" >/dev/null 2>&1 || __fail "Missing required command: $1"; }
# Test whether a command exists without failing
__have() { command -v "$1" >/dev/null 2>&1; }
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Generate a cryptographically random alphanumeric secret of given length
__gen_secret() {
  local len="${1:-32}"
  dd if=/dev/urandom bs=1 count=$((len * 6)) 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len"
}
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Return a random free port in the 62000-64999 range
__random_port() {
  local port
  while :; do
    port=$(awk 'BEGIN{srand(); printf "%d", 62000+int(rand()*3000)}')
    if ! __port_in_use "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
}
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Return 0 if the given TCP port is already bound on the host
__port_in_use() {
  local p="$1"
  if \ss -ltn 2>/dev/null | \awk -v p="$p" '$4 ~ (":" p "$") {found=1} END {exit !found}'; then
    return 0
  fi
  if \netstat -ltn 2>/dev/null | \awk -v p="$p" '$4 ~ (":" p "$") {found=1} END {exit !found}'; then
    return 0
  fi
  return 1
}
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Return 0 if the argument is a valid registerable domain name
__is_valid_domain() {
  local dom="$1"
  printf '%s\n' "$dom" | grep -E -- '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$' >/dev/null 2>&1 || return 1
  case "$dom" in
    *.local|*.lan|*.home|*.invalid|*.test|localhost|localhost.*) return 1 ;;
  esac
  [ "$(printf '%s' "$dom" | wc -c | tr -d ' ')" -le 253 ] || return 1
  return 0
}
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Paths — all runtime data lives under OPT_ROOT/volumes/ mirroring compose ./volumes/ convention
OPT_ROOT="/opt/quay"
VOLUMES_DIR="${OPT_ROOT}/volumes"
BIN_DIR="${OPT_ROOT}/bin"
ENV_FILE="${OPT_ROOT}/.env"
COMPOSE_FILE="${OPT_ROOT}/docker-compose.yml"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Data directories
PG_DATA_DIR="${VOLUMES_DIR}/data/db/postgres/quay"
REDIS_DATA_DIR="${VOLUMES_DIR}/data/db/redis"
QUAY_DATA_DIR="${VOLUMES_DIR}/data/quay"
QUAY_LOG_DIR="${VOLUMES_DIR}/data/quay/logs"
QUAY_STORAGE_DIR="${VOLUMES_DIR}/data/quay/storage"
QUAY_RUN_DIR="${VOLUMES_DIR}/data/quay/run"
CLAIR_DATA_DIR="${VOLUMES_DIR}/data/clair"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Config directories
QUAY_STACK_DIR="${VOLUMES_DIR}/config/quay/stack"
QUAY_INITDB_DIR="${VOLUMES_DIR}/config/quay/init-db"
CLAIR_CONF_DIR="${VOLUMES_DIR}/config/clair"
CREDS_DIR="${VOLUMES_DIR}/config/credentials"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# GC, verify-user helper, and cosign paths
GC_WRAPPER="${BIN_DIR}/quay-gc.sh"
VERIFY_USER_WRAPPER="${BIN_DIR}/quay-verify-user.sh"
COSIGN_KEY_FILE="${CREDS_DIR}/cosign.key"
COSIGN_PUB_FILE="${CREDS_DIR}/cosign.pub"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Usage information
__help() {
  cat <<HELP
Usage: ${APPNAME} [OPTIONS]

Self-hosted Quay registry stack installer.
Sets up Quay, Postgres, Redis, and Clair under /opt/quay.

Options:
  -h, --help      Show this help message and exit
  -v, --version   Show version and exit
  --no-color      Suppress colored output in the final summary

Environment variables (set before running):
  DOMAIN              Registry hostname (e.g. registry.example.com)
  APP_ADMIN_USER      Superuser account created on first run (default: administrator)
  APP_ADMIN_PASS      Superuser password — auto-generated if not set
  REGISTRY_TITLE      Full display name shown in the UI (default: Quay)
  REGISTRY_TITLE_SHORT  Short name shown in the browser tab (default: Quay)
  QUAY_IMAGE          Quay image to deploy (default: quay.io/projectquay/quay:latest)
  CLAIR_IMAGE         Clair image to deploy (default: quay.io/projectquay/clair:latest)
  TZ                  Timezone for all containers (default: America/New_York)

All other values (passwords, secret keys, port) are auto-generated and
persisted to ${ENV_FILE}.
HELP
}
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Parse CLI flags
for _arg in "$@"; do
  case "$_arg" in
    -h|--help)    __help; exit 0 ;;
    -v|--version) __version; exit 0 ;;
    --no-color)   NO_COLOR=1 ;;
    *)            __fail "Unknown option: ${_arg}. Use --help for usage." ;;
  esac
done
unset _arg
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Print version and ensure OPT_ROOT and BIN_DIR exist before sourcing .env
__version
\mkdir -p "$OPT_ROOT" "$BIN_DIR"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Source existing .env to preserve secrets and settings across idempotent re-runs
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  # SMTP_ENABLED is re-probed every run — never loaded from .env
  unset SMTP_ENABLED
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Preflight: required commands
__need sh
__need awk
__need grep
__need tr
__need dd
__need curl
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Detect the compose engine available on this host
if __have docker; then
  if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif __have docker-compose; then
    COMPOSE="docker-compose"
  else
    __fail "Docker is installed but Docker Compose (plugin or standalone) was not found. Install it and re-run."
  fi
elif __have podman && __have podman-compose; then
  COMPOSE="podman-compose"
else
  __fail "Neither docker nor podman (+podman-compose) is installed. Install a container engine with compose support and re-run."
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Resolve BASE_DOMAIN_NAME from env, DOMAIN env var, or hostname
if [ -z "${BASE_DOMAIN_NAME:-}" ]; then
  if [ -n "${DOMAIN:-}" ]; then
    BASE_DOMAIN_NAME="$DOMAIN"
  else
    _host_short="$(hostname -s 2>/dev/null || printf 'quayhost')"
    _host_domain="$(hostname -d 2>/dev/null || printf '')"
    if [ -n "$_host_domain" ]; then
      BASE_DOMAIN_NAME="${_host_short}.${_host_domain}"
    else
      BASE_DOMAIN_NAME="$(hostname -f 2>/dev/null || printf '%s.localdomain' "${_host_short}")"
    fi
  fi
fi
__is_valid_domain "$BASE_DOMAIN_NAME" || __fail "DOMAIN must be a valid registerable domain (e.g. registry.example.com). Set DOMAIN= and re-run."
BASE_HOST_NAME="${BASE_HOST_NAME:-${BASE_DOMAIN_NAME}}"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Discover the Docker bridge IP for host-to-container reachability
if [ -z "${HOST_IP_4:-}" ]; then
  HOST_IP_4="172.17.0.1"
  if __have ip; then
    for _iface in docker0 cni-podman0 podman0 br0; do
      _di=$(ip -4 addr show "$_iface" 2>/dev/null | awk '/inet /{print $2}' | awk -F/ '{print $1}')
      if [ -n "$_di" ]; then
        HOST_IP_4="$_di"
        break
      fi
    done
  fi
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Probe SMTP: check whether a local MTA is listening on port 25.
# ss -ltn is the most reliable check — it reads kernel socket state directly
# without needing a live SMTP handshake. nc is the fallback.
# SMTP_HOST is always set to HOST_IP_4 so containers can reach the host MTA.
SMTP_PORT="${SMTP_PORT:-25}"
if [ -z "${SMTP_ENABLED:-}" ]; then
  if \ss -ltn 2>/dev/null | \awk -v p="${SMTP_PORT}" '$4 ~ (":"p"$"){found=1} END{exit !found}'; then
    SMTP_ENABLED="true"
  elif __have nc && \nc -zw3 127.0.0.1 "${SMTP_PORT}" >/dev/null 2>&1; then
    SMTP_ENABLED="true"
  else
    SMTP_ENABLED="false"
  fi
fi
# Containers always reach the host MTA via HOST_IP_4 regardless of bind address
SMTP_HOST="${SMTP_HOST:-${HOST_IP_4}}"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Determine bind address for Quay's HTTP port
if [ -z "${QUAY_BIND_ADDR:-}" ]; then
  if __have ip && ip addr show 2>/dev/null | grep -q -- "inet ${HOST_IP_4}/"; then
    QUAY_BIND_ADDR="$HOST_IP_4"
  else
    QUAY_BIND_ADDR="0.0.0.0"
  fi
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Pick a random free port in 62000-64999 once; persist it across re-runs via .env
if [ -z "${QUAY_PORT:-}" ]; then
  QUAY_PORT="$(__random_port)"
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Idempotent secret generation — load from .env on re-run, generate only when absent
TZ="${TZ:-America/New_York}"
APP_ADMIN_USER="${APP_ADMIN_USER:-administrator}"
REGISTRY_TITLE="${REGISTRY_TITLE:-Quay}"
REGISTRY_TITLE_SHORT="${REGISTRY_TITLE_SHORT:-${REGISTRY_TITLE}}"
# Resolve Quay and Clair image tags — neither publishes a :latest tag.
# Try to fetch the highest stable x.y.z release from the registry API;
# fall back to a known-good pinned version if the fetch fails or is empty.
if [ -z "${QUAY_IMAGE:-}" ]; then
  _quay_ver=$(curl -fsSL --connect-timeout 5 \
    "https://quay.io/api/v1/repository/projectquay/quay/tag/?onlyActiveTags=true&limit=100" \
    2>/dev/null | tr ',' '\n' | grep '"name"' | \
    sed 's/.*"name":"\([^"]*\)".*/\1/' | \
    awk -F. 'NF==3 && $1+0==$1 && $2+0==$2 && $3+0==$3' | \
    sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  QUAY_IMAGE="quay.io/projectquay/quay:${_quay_ver:-3.17.2}"
  unset _quay_ver
fi
if [ -z "${CLAIR_IMAGE:-}" ]; then
  _clair_ver=$(curl -fsSL --connect-timeout 5 \
    "https://quay.io/api/v1/repository/projectquay/clair/tag/?onlyActiveTags=true&limit=100" \
    2>/dev/null | tr ',' '\n' | grep '"name"' | \
    sed 's/.*"name":"\([^"]*\)".*/\1/' | \
    awk -F. 'NF==3 && $1+0==$1 && $2+0==$2 && $3+0==$3' | \
    sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  CLAIR_IMAGE="quay.io/projectquay/clair:${_clair_ver:-4.9.0}"
  unset _clair_ver
fi
# Generate all secrets and internal identifiers on first run only.
# DB usernames and the database name are randomized lowercase identifiers —
# internal implementation details not exposed as user-configurable options.
if [ -z "${DB_USER_NAME:-}" ]; then
  DB_USER_NAME="q$(dd if=/dev/urandom bs=1 count=96 2>/dev/null | tr -dc 'a-z0-9' | head -c 11)"
fi
# Database name always matches the Quay DB username (Postgres convention)
DB_CREATE_DATABASE_NAME="${DB_USER_NAME}"
if [ -z "${CLAIR_DB_USER_NAME:-}" ]; then
  CLAIR_DB_USER_NAME="c$(dd if=/dev/urandom bs=1 count=96 2>/dev/null | tr -dc 'a-z0-9' | head -c 11)"
fi
if [ -z "${DB_USER_PASS:-}" ]; then DB_USER_PASS="$(__gen_secret 24)"; fi
if [ -z "${CLAIR_DB_USER_PASS:-}" ]; then CLAIR_DB_USER_PASS="$(__gen_secret 24)"; fi
if [ -z "${QUAY_SECRET_KEY:-}" ]; then QUAY_SECRET_KEY="$(__gen_secret 48)"; fi
if [ -z "${APP_ADMIN_PASS:-}" ]; then APP_ADMIN_PASS="$(__gen_secret 24)"; fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Generate cosign keypair — openssl preferred; cosign binary fallback; warn and skip if neither available
if [ ! -s "$COSIGN_KEY_FILE" ] || [ ! -s "$COSIGN_PUB_FILE" ]; then
  \mkdir -p "$CREDS_DIR"
  \chmod 700 "$CREDS_DIR"
  if __have openssl; then
    \openssl genpkey -algorithm ed25519 -out "$COSIGN_KEY_FILE" >/dev/null 2>&1 || __fail "openssl ed25519 keygen failed"
    \chmod 600 "$COSIGN_KEY_FILE"
    \openssl pkey -in "$COSIGN_KEY_FILE" -pubout -out "$COSIGN_PUB_FILE" >/dev/null 2>&1 || __fail "openssl pubout failed"
  elif __have cosign; then
    COSIGN_PASSWORD="" \cosign generate-key-pair --output-key-prefix "${CREDS_DIR}/cosign" >/dev/null 2>&1 || __fail "cosign keygen failed"
    \chmod 600 "$COSIGN_KEY_FILE"
  else
    __warn "openssl and cosign not found — skipping cosign key generation. Add keys manually to ${CREDS_DIR} if needed."
  fi
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Verify OPT_ROOT is writable before proceeding
[ -w "$OPT_ROOT" ] || __fail "${OPT_ROOT} is not writable — run as root or fix permissions"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Write the single .env file — complete overwrite, mode 600, never committed
__info "Writing ${ENV_FILE}"
_env_tmp="${ENV_FILE}.tmp.$$"
{
  printf 'TZ="%s"\n' "$TZ"
  printf 'BASE_DOMAIN_NAME="%s"\n' "$BASE_DOMAIN_NAME"
  printf 'BASE_HOST_NAME="%s"\n' "$BASE_HOST_NAME"
  printf 'APP_ADMIN_USER="%s"\n' "$APP_ADMIN_USER"
  printf 'APP_ADMIN_PASS="%s"\n' "$APP_ADMIN_PASS"
  printf 'REGISTRY_TITLE="%s"\n' "$REGISTRY_TITLE"
  printf 'REGISTRY_TITLE_SHORT="%s"\n' "$REGISTRY_TITLE_SHORT"
  printf 'QUAY_IMAGE="%s"\n' "$QUAY_IMAGE"
  printf 'CLAIR_IMAGE="%s"\n' "$CLAIR_IMAGE"
  printf 'SMTP_HOST="%s"\n' "$SMTP_HOST"
  printf 'SMTP_PORT="%s"\n' "$SMTP_PORT"
  printf 'HOST_IP_4="%s"\n' "$HOST_IP_4"
  printf 'QUAY_BIND_ADDR="%s"\n' "$QUAY_BIND_ADDR"
  printf 'QUAY_PORT="%s"\n' "$QUAY_PORT"
  printf 'QUAY_SECRET_KEY="%s"\n' "$QUAY_SECRET_KEY"
  printf 'DB_USER_NAME="%s"\n' "$DB_USER_NAME"
  printf 'DB_CREATE_DATABASE_NAME="%s"\n' "$DB_CREATE_DATABASE_NAME"
  printf 'DB_USER_PASS="%s"\n' "$DB_USER_PASS"
  printf 'CLAIR_DB_USER_NAME="%s"\n' "$CLAIR_DB_USER_NAME"
  printf 'CLAIR_DB_USER_PASS="%s"\n' "$CLAIR_DB_USER_PASS"
  printf 'COSIGN_KEY_FILE="%s"\n' "$COSIGN_KEY_FILE"
  printf 'COSIGN_PUB_FILE="%s"\n' "$COSIGN_PUB_FILE"
} >"$_env_tmp"
\chmod 600 "$_env_tmp"
\mv "$_env_tmp" "$ENV_FILE"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Create all required directories under volumes/
\mkdir -p \
  "$PG_DATA_DIR" \
  "$REDIS_DATA_DIR" \
  "$QUAY_DATA_DIR" \
  "$QUAY_LOG_DIR" \
  "$QUAY_STORAGE_DIR" \
  "$QUAY_RUN_DIR" \
  "$CLAIR_DATA_DIR" \
  "$QUAY_STACK_DIR" \
  "$QUAY_INITDB_DIR" \
  "$CLAIR_CONF_DIR" \
  "$CREDS_DIR"
# chmod intermediate dirs too — umask 077 leaves them 700 without explicit fix
\chmod 755 \
  "$VOLUMES_DIR" \
  "${VOLUMES_DIR}/data" \
  "${VOLUMES_DIR}/data/db" \
  "${VOLUMES_DIR}/config" \
  "${VOLUMES_DIR}/config/quay" \
  "$PG_DATA_DIR" \
  "$REDIS_DATA_DIR" \
  "$QUAY_DATA_DIR" \
  "$QUAY_LOG_DIR" \
  "$QUAY_STORAGE_DIR" \
  "$QUAY_RUN_DIR" \
  "$CLAIR_DATA_DIR" \
  "$QUAY_STACK_DIR" \
  "$QUAY_INITDB_DIR" \
  "$CLAIR_CONF_DIR"
\chmod 700 "$CREDS_DIR"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Write Quay config.yaml — create only on first run to preserve manual edits
CFG="${QUAY_STACK_DIR}/config.yaml"
if [ ! -f "$CFG" ]; then
  __info "Writing ${CFG}"
  cat >"${CFG}.tmp" <<EOF
SERVER_HOSTNAME: ${BASE_DOMAIN_NAME}
PREFERRED_URL_SCHEME: https
EXTERNAL_TLS_TERMINATION: true
TESTING: false
SETUP_COMPLETE: true

REGISTRY_TITLE: ${REGISTRY_TITLE}
REGISTRY_TITLE_SHORT: ${REGISTRY_TITLE_SHORT}

FEATURE_USER_CREATION: true
FEATURE_USER_CREATION_INVITE_ONLY: false
FEATURE_ANONYMOUS_ACCESS: true
FEATURE_PUBLIC_CATALOG: true
CREATE_PRIVATE_REPO_ON_PUSH: false
FEATURE_REQUIRE_EMAIL_VERIFICATION: ${SMTP_ENABLED}
FEATURE_GRAVATAR: true
FEATURE_CHANGE_TAG_EXPIRATION: true
FEATURE_REPO_MIRROR: true
FEATURE_REQUIRE_TEAM_INVITE: true
FEATURE_MAILING: ${SMTP_ENABLED}
FEATURE_DIRECT_LOGIN: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
FEATURE_PARTIAL_IMAGES: true
FEATURE_SECURITY_NOTIFICATIONS: true

MAIL_SERVER: ${SMTP_HOST}
MAIL_PORT: ${SMTP_PORT}
MAIL_USE_TLS: false
MAIL_USE_SSL: false
MAIL_USERNAME:
MAIL_PASSWORD:
MAIL_DEFAULT_SENDER: no-reply@${BASE_DOMAIN_NAME}

SUPER_USERS:
  - ${APP_ADMIN_USER}

DISTRIBUTED_STORAGE_CONFIG:
  default:
    - LocalStorage
    - storage_path: /datastorage/registry
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: ["default"]
DISTRIBUTED_STORAGE_PREFERENCE: ["default"]

FEATURE_SECURITY_SCANNER: true
SECURITY_SCANNER_V4_ENDPOINT: http://quay-clair:6060
SECURITY_SCANNER_V4_NAMESPACE_WHITELIST: []

SECRET_KEY: ${QUAY_SECRET_KEY}
DATABASE_SECRET_KEY: ${QUAY_SECRET_KEY}

DB_URI: postgresql://${DB_USER_NAME}:${DB_USER_PASS}@quay-db:5432/${DB_CREATE_DATABASE_NAME}

BUILDLOGS_REDIS:
  host: quay-redis
  port: 6379

USER_EVENTS_REDIS:
  host: quay-redis
  port: 6379
EOF
  \mv "${CFG}.tmp" "$CFG"
  # 640: Quay runs as GID 0 (root group) so group-read is sufficient; not world-readable
  \chmod 640 "$CFG"
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Write postgres init scripts — run by postgres only on first-boot (empty data dir)
cat >"${QUAY_INITDB_DIR}/01-init-quay.sh" <<'EOF'
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOSQL
EOF
\chmod 755 "${QUAY_INITDB_DIR}/01-init-quay.sh"

cat >"${QUAY_INITDB_DIR}/02-init-clair.sh" <<EOF
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "\$POSTGRES_USER" --dbname "\$POSTGRES_DB" <<-EOSQL
    CREATE USER ${CLAIR_DB_USER_NAME} WITH PASSWORD '${CLAIR_DB_USER_PASS}';
    CREATE DATABASE clair OWNER ${CLAIR_DB_USER_NAME};
    GRANT ALL PRIVILEGES ON DATABASE clair TO ${CLAIR_DB_USER_NAME};
EOSQL
EOF
\chmod 755 "${QUAY_INITDB_DIR}/02-init-clair.sh"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Write docker-compose.yml — always refreshed; bind mounts preserve data across restarts
__info "Writing ${COMPOSE_FILE}"
printf '# nginx proxy address - http://%s:%s\n' "$QUAY_BIND_ADDR" "$QUAY_PORT" >"${COMPOSE_FILE}.tmp"
cat >>"${COMPOSE_FILE}.tmp" <<'YAML'

name: quay

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "5m"
    max-file: "1"

services:
  quay-db:
    image: docker.io/library/postgres:15-alpine
    pull_policy: missing
    container_name: quay-db
    restart: always
    logging: *default-logging
    networks:
      - quay
    environment:
      TZ: ${TZ:-America/New_York}
      CONTAINER_NAME: quay-db
      POSTGRES_DB: ${DB_CREATE_DATABASE_NAME}
      POSTGRES_USER: ${DB_USER_NAME}
      POSTGRES_PASSWORD: ${DB_USER_PASS:-changeme_db_password}
      CLAIR_DB_USER_NAME: ${CLAIR_DB_USER_NAME}
      CLAIR_DB_USER_PASS: ${CLAIR_DB_USER_PASS}
    volumes:
      - ./volumes/data/db/postgres/quay:/var/lib/postgresql/data:z
      - ./volumes/config/quay/init-db:/docker-entrypoint-initdb.d:ro,z
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 30s
      timeout: 10s
      retries: 3

  quay-redis:
    image: docker.io/library/redis:7-alpine
    pull_policy: missing
    container_name: quay-redis
    restart: always
    logging: *default-logging
    networks:
      - quay
    environment:
      TZ: ${TZ:-America/New_York}
      CONTAINER_NAME: quay-redis
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - ./volumes/data/db/redis:/data:z

  quay-clair:
    image: ${CLAIR_IMAGE}
    pull_policy: missing
    container_name: quay-clair
    restart: always
    logging: *default-logging
    networks:
      - quay
    environment:
      TZ: ${TZ:-America/New_York}
      CONTAINER_NAME: quay-clair
      CLAIR_CONF: /clair-config/config.yaml
    volumes:
      - ./volumes/data/clair:/clairdata:z
      - ./volumes/config/clair:/clair-config:z
    depends_on:
      quay-db:
        condition: service_healthy

  quay-app:
    image: ${QUAY_IMAGE}
    pull_policy: missing
    container_name: quay-app
    restart: always
    logging: *default-logging
    networks:
      - quay
    environment:
      TZ: ${TZ:-America/New_York}
      CONTAINER_NAME: quay-app
      HOSTNAME: ${BASE_HOST_NAME:-$HOSTNAME}
    ports:
      - "${QUAY_BIND_ADDR:-172.17.0.1}:${QUAY_PORT:-62080}:8080"
    volumes:
      - ./volumes/config/quay/stack:/quay-registry/conf/stack:z
      - ./volumes/data/quay/logs:/var/log/quay:z
      - ./volumes/data/quay/storage:/datastorage/registry:z
    depends_on:
      quay-db:
        condition: service_healthy
      quay-redis:
        condition: service_started

networks:
  quay:
    name: quay
    external: false
YAML
\mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
\chmod 644 "$COMPOSE_FILE"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Write Clair v4 config — always refreshed (contains db credentials)
__info "Writing ${CLAIR_CONF_DIR}/config.yaml"
cat >"${CLAIR_CONF_DIR}/config.yaml.tmp" <<EOF
http_listen_addr: :6060
introspection_addr: :6061
indexer:
  connstring: host=quay-db port=5432 user=${CLAIR_DB_USER_NAME} password=${CLAIR_DB_USER_PASS} dbname=clair sslmode=disable
  migrations: true
matcher:
  connstring: host=quay-db port=5432 user=${CLAIR_DB_USER_NAME} password=${CLAIR_DB_USER_PASS} dbname=clair sslmode=disable
  migrations: true
notifier:
  connstring: host=quay-db port=5432 user=${CLAIR_DB_USER_NAME} password=${CLAIR_DB_USER_PASS} dbname=clair sslmode=disable
  migrations: true
EOF
\mv "${CLAIR_CONF_DIR}/config.yaml.tmp" "${CLAIR_CONF_DIR}/config.yaml"
# Clair runs as UID/GID 65534 (nobody); chown so group-read is sufficient
\chown 65534:65534 "${CLAIR_CONF_DIR}/config.yaml"
\chmod 640 "${CLAIR_CONF_DIR}/config.yaml"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Write GC wrapper script — sources .env at runtime for QUAY_BIND_ADDR and QUAY_PORT
__info "Writing ${GC_WRAPPER}"
cat >"${GC_WRAPPER}.tmp" <<'EOS'
#!/usr/bin/env sh
# shellcheck shell=sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202606022117-git
# @@Author           :  Jason Hempstead
# @@Contact          :  git-admin@casjaysdev.pro
# @@License          :  MIT or LICENSE.md
# @@ReadME           :  README.md
# @@Copyright        :  Copyright: (c) 2026 Jason Hempstead, Casjays Developments
# @@Created          :  Monday, June 01, 2026 00:46 EDT
# @@File             :  quay-gc.sh
# @@Description      :  Quay daily garbage collection wrapper (generated by install.sh)
# @@Changelog        :  New file
# @@TODO             :  None
# @@Other            :  Run via systemd timer or cron — never call directly
# @@Resource         :
# @@Terminal App     :  no
# @@sudo/root        :  yes
# @@Template         :  shell/sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC2001,SC2003,SC2016,SC2031,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329,SC3043
# - - - - - - - - - - - - - - - - - - - - - - - - -
VERSION="202606022117-git"
APPNAME="${0##*/}"
# - - - - - - - - - - - - - - - - - - - - - - - - -
set -e
umask 077
# - - - - - - - - - - - - - - - - - - - - - - - - -
OPT_ROOT="/opt/quay"
ENV_FILE="${OPT_ROOT}/.env"
VOLUMES_DIR="${OPT_ROOT}/volumes"
GC_LOCK="${VOLUMES_DIR}/data/quay/run/gc.lock"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Load runtime values (QUAY_BIND_ADDR, QUAY_PORT, etc.)
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
# - - - - - - - - - - - - - - - - - - - - - - - - -
__gc_log() { printf '%s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$*"; }
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Exit if Quay is not healthy — log the skip so operators can distinguish it from a successful run
if ! curl -fsS "http://${QUAY_BIND_ADDR:-172.17.0.1}:${QUAY_PORT:-62080}/health/instance" >/dev/null 2>&1; then
  __gc_log "Quay not healthy — skipping GC"
  exit 0
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Acquire exclusive lock; stale locks older than 2h are removed
mkdir -p "${GC_LOCK%/*}"
if [ -f "$GC_LOCK" ]; then
  find "${GC_LOCK%/*}" -maxdepth 1 -name "${GC_LOCK##*/}" -mmin +120 -exec rm -f {} \; >/dev/null 2>&1 || true
fi
if [ -f "$GC_LOCK" ]; then exit 0; fi
: >"$GC_LOCK"
trap 'rm -f "$GC_LOCK"' EXIT INT TERM
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Detect container engine
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    __gc_log "Docker Compose not found; skipping GC"
    exit 0
  fi
elif command -v podman >/dev/null 2>&1 && command -v podman-compose >/dev/null 2>&1; then
  DC="podman-compose"
else
  __gc_log "No container engine found; skipping GC"
  exit 0
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Attempt Quay GC via internal manage commands (best-effort; silent on failure)
$DC -f /opt/quay/docker-compose.yml exec -T quay-app sh -c 'quay garbage-collect --delete 2>/dev/null || true' >/dev/null 2>&1 || true
$DC -f /opt/quay/docker-compose.yml exec -T quay-app sh -c 'quay manage gc 2>/dev/null || true' >/dev/null 2>&1 || true
__gc_log "Quay GC completed"
exit 0
# ex: ts=2 sw=2 et filetype=sh
EOS
\mv "${GC_WRAPPER}.tmp" "$GC_WRAPPER"
\chmod 700 "$GC_WRAPPER"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Write verify-user helper — marks a Quay account verified in the DB.
# Needed when SMTP is disabled: Quay blocks login until verified=true even
# with FEATURE_REQUIRE_EMAIL_VERIFICATION: false.
__info "Writing ${VERIFY_USER_WRAPPER}"
cat >"${VERIFY_USER_WRAPPER}.tmp" <<'EOS'
#!/usr/bin/env sh
# shellcheck shell=sh
# Usage: quay-verify-user.sh <username>
# Marks the named Quay account as email-verified directly in postgres.
# Required when SMTP is disabled and a user is stuck on the activation screen.
set -e
OPT_ROOT="/opt/quay"
ENV_FILE="${OPT_ROOT}/.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
_username="${1:-}"
if [ -z "$_username" ]; then
  printf 'Usage: %s <username>\n' "${0##*/}" >&2
  exit 1
fi
if command -v docker >/dev/null 2>&1; then
  _cexec="docker exec"
elif command -v podman >/dev/null 2>&1; then
  _cexec="podman exec"
else
  printf 'Error: docker or podman required\n' >&2
  exit 1
fi
$_cexec quay-db psql -U "${DB_USER_NAME}" -d "${DB_CREATE_DATABASE_NAME}" \
  -c "UPDATE \"user\" SET verified=true WHERE username='${_username}';"
printf 'User "%s" marked as verified.\n' "$_username"
EOS
\mv "${VERIFY_USER_WRAPPER}.tmp" "$VERIFY_USER_WRAPPER"
\chmod 700 "$VERIFY_USER_WRAPPER"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Schedule GC daily at 03:00 — systemd timer preferred; cron fallback
if __have systemctl; then
  cat >/etc/systemd/system/quay-gc.service <<EOF
[Unit]
Description=Quay Garbage Collection
After=network-online.target

[Service]
Type=oneshot
ExecStart=${GC_WRAPPER}
Nice=10

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/quay-gc.timer <<'EOF'
[Unit]
Description=Daily Quay Garbage Collection

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now quay-gc.timer >/dev/null 2>&1 || true
else
  printf '0 3 * * * root %s >/dev/null 2>&1\n' "$GC_WRAPPER" >/etc/cron.d/quay-gc
  \chmod 644 /etc/cron.d/quay-gc
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Pull images and bring up the stack
__info "Pulling container images (this may take several minutes)…"
__info "  quay-app : ${QUAY_IMAGE}"
__info "  quay-clair: ${CLAIR_IMAGE}"
$COMPOSE --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull 2>&1 || \
  __fail "Image pull failed. Check that QUAY_IMAGE=${QUAY_IMAGE} and CLAIR_IMAGE=${CLAIR_IMAGE} exist and are reachable."

__info "Starting Quay stack…"
$COMPOSE --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d 2>&1 || \
  __fail "Failed to start Quay stack — check logs: $COMPOSE --env-file $ENV_FILE -f $COMPOSE_FILE logs"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Wait for Quay to become healthy (up to 300 s; first boot takes longer due to DB migrations)
sleep 2
HEALTH_OK=0
_tries=150
while [ "$_tries" -gt 0 ]; do
  if \curl -fsS "http://${QUAY_BIND_ADDR}:${QUAY_PORT}/health/instance" >/dev/null 2>&1; then
    HEALTH_OK=1
    break
  fi
  _tries=$((_tries - 1))
  sleep 2
done
[ "$HEALTH_OK" -eq 1 ] || __fail "Quay did not become healthy within 300 s. Check logs: $COMPOSE --env-file $ENV_FILE -f $COMPOSE_FILE logs quay-app"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Auto-create and verify the superuser account.
# Uses Quay's registration API; then marks the account verified directly in
# the database so email verification never blocks login regardless of SMTP config.
if __have docker; then
  _cexec="docker exec"
elif __have podman; then
  _cexec="podman exec"
else
  __fail "Neither docker nor podman found — cannot exec into quay-db to verify account"
fi
__info "Creating superuser account: ${APP_ADMIN_USER}"
_acct_new=0
_acct_http=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://${QUAY_BIND_ADDR}:${QUAY_PORT}/api/v1/user/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${APP_ADMIN_USER}\",\"password\":\"${APP_ADMIN_PASS}\",\"email\":\"${APP_ADMIN_USER}@${BASE_DOMAIN_NAME}\"}" 2>/dev/null || printf '000')
case "$_acct_http" in
  2*) _acct_new=1 ;;
  # 400/409 = account already exists — treat as success
  400|409) _acct_new=0 ;;
  *) __warn "Account creation returned HTTP ${_acct_http} — account may not have been created; check Quay logs" ;;
esac
unset _acct_http
# Mark verified in the DB — covers both first run and idempotent re-runs
$_cexec quay-db psql -U "${DB_USER_NAME}" -d "${DB_CREATE_DATABASE_NAME}" \
  -c "UPDATE \"user\" SET verified=true WHERE username='${APP_ADMIN_USER}';" >/dev/null 2>&1 || \
  __warn "Could not mark ${APP_ADMIN_USER} as verified in the DB — log in and verify via email if prompted"
if [ "$_acct_new" -eq 1 ]; then
  __info "Superuser account created and verified"
else
  __info "Superuser account already exists — credentials unchanged"
fi
unset _acct_new
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Final summary — only place credentials are printed; never logged
printf '\n'
if [ -z "${NO_COLOR:-}" ]; then
  cat <<EOF
✅ Quay is up and running!

🔌 Local endpoint:     http://${QUAY_BIND_ADDR}:${QUAY_PORT}
🌐 Registry domain:    https://${BASE_DOMAIN_NAME}
📧 Email:              verification $( [ "$SMTP_ENABLED" = "true" ] && printf "ENABLED" || printf "DISABLED" ) (SMTP via ${SMTP_HOST}:${SMTP_PORT})
🌉 Docker network:     quay
🔒 Cosign key:         ${COSIGN_KEY_FILE}
🔑 Cosign pub:         ${COSIGN_PUB_FILE}
🗑️  Garbage collection: ENABLED (daily at 03:00 local)

===============================
🔐 SUPERUSER ACCOUNT
===============================
👤 Username: ${APP_ADMIN_USER}
🔑 Password: ${APP_ADMIN_PASS}

✅ Account created and verified — log in at https://${BASE_DOMAIN_NAME}

⚠️  Store these credentials securely — they are not saved in logs.

$( [ "$SMTP_ENABLED" != "true" ] && printf '⚠️  SMTP is disabled. New users who register via the web UI will see an\n    activation email prompt and cannot log in until verified. Run:\n      %s <username>\n' "$VERIFY_USER_WRAPPER" )
⚠️  A reverse proxy terminating TLS at https://${BASE_DOMAIN_NAME} is required
    before docker login / push / pull will work. Quay's bearer auth challenge
    redirects clients to the HTTPS domain — direct IP:port access is for
    health checks and the web UI only.

⚠️  After a manual restart (docker compose down/up) allow 2–4 minutes for
    Quay to become available before assuming something is wrong.

📝 Next steps:
   👉 Configure your reverse proxy → https://${BASE_DOMAIN_NAME}
   👉 Log in with the superuser account at https://${BASE_DOMAIN_NAME}
   👉 Set DOMAIN=${BASE_DOMAIN_NAME} sh ${APPNAME} to update configuration
EOF
else
  cat <<EOF
Quay is up and running!

Local endpoint:     http://${QUAY_BIND_ADDR}:${QUAY_PORT}
Registry domain:    https://${BASE_DOMAIN_NAME}
Email:              verification $( [ "$SMTP_ENABLED" = "true" ] && printf "ENABLED" || printf "DISABLED" ) (SMTP via ${SMTP_HOST}:${SMTP_PORT})
Docker network:     quay
Cosign key:         ${COSIGN_KEY_FILE}
Cosign pub:         ${COSIGN_PUB_FILE}
Garbage collection: ENABLED (daily at 03:00 local)

===============================
SUPERUSER ACCOUNT
===============================
Username: ${APP_ADMIN_USER}
Password: ${APP_ADMIN_PASS}

Account created and verified -- log in at https://${BASE_DOMAIN_NAME}

Store these credentials securely -- they are not saved in logs.

$( [ "$SMTP_ENABLED" != "true" ] && printf 'SMTP is disabled. New users who register via the web UI will see an\nactivation email prompt and cannot log in until verified. Run:\n  %s <username>\n' "$VERIFY_USER_WRAPPER" )
IMPORTANT: A reverse proxy terminating TLS at https://${BASE_DOMAIN_NAME}
is required before docker login / push / pull will work. Quay's bearer
auth challenge redirects clients to the HTTPS domain -- direct IP:port
access is for health checks and the web UI only.

After a manual restart (docker compose down/up) allow 2-4 minutes for
Quay to become available before assuming something is wrong.

Next steps:
   Configure your reverse proxy -> https://${BASE_DOMAIN_NAME}
   Log in with the superuser account at https://${BASE_DOMAIN_NAME}
   Set DOMAIN=${BASE_DOMAIN_NAME} sh ${APPNAME} to update configuration
EOF
fi

# ex: ts=2 sw=2 et filetype=sh
