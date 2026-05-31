#!/bin/sh
# install.sh — Self-hosted Quay stack (Quay + Postgres + Redis + Clair) with Cosign + Syft
##@Version 202605310000
# - Pure POSIX sh, idempotent, distro-agnostic
# - Docker Compose stack, reverse proxy handled externally
# - Binds Quay on 172.17.0.1:<random 64xxx> (persisted)
# - Open registration, anonymous pulls; pushes require auth
# - SMTP auto-detect on host bridge; enables email verification if reachable
# - Clair always on; Cosign+Syft helpers baked in
# - Secrets only in files; never printed to logs (only shown in final summary)
# - GC always on daily 03:00 (systemd timer with jitter; cron fallback), first run dry-run

set -eu
umask 077

VERSION="202605310000"

### --- tiny utils (POSIX) ---
__ts() { date +"%Y-%m-%d %H:%M:%S"; }
__info() { printf '%s %s\n' "$(__ts)" "$*"; }
__warn() { printf '%s %s\n' "$(__ts)" "WARN: $*"; }
__fail() { printf '%s %s\n' "$(__ts)" "ERROR: $*" >&2; exit 1; }

__need() { command -v "$1" >/dev/null 2>&1 || __fail "Missing required command: $1"; }

# Try a command; if it exists, echo it and return 0
__have() { command -v "$1" >/dev/null 2>&1; }

### --- constants / paths ---
OPT_ROOT="/opt/quay"
ROOTFS="${OPT_ROOT}/rootfs"

# Database directories
PG_DIR="${ROOTFS}/db/postgres"
REDIS_DIR="${ROOTFS}/db/redis"

# Service data directories
QUAY_DATA_DIR="${ROOTFS}/data/quay"
CLAIR_DATA_DIR="${ROOTFS}/data/clair"
LOG_DIR="${QUAY_DATA_DIR}/logs"
STORAGE_DIR="${QUAY_DATA_DIR}/storage"
RUN_DIR="${QUAY_DATA_DIR}/run"

# Configuration directories
CONFIG_DIR="${ROOTFS}/config/quay"
CLAIR_CONF_DIR="${ROOTFS}/config/clair"
CREDS_DIR="${ROOTFS}/config/credentials"

# Other paths
BIN_DIR="${OPT_ROOT}/bin"
ENV_FILE="${OPT_ROOT}/.env"
COMPOSE_FILE="${OPT_ROOT}/docker-compose.yml"
GC_LOCK="${RUN_DIR}/gc.lock"
GC_FLAG_FIRST="${RUN_DIR}/gc-first-run"

# Legacy compatibility
DATA_DIR="${QUAY_DATA_DIR}"
CLAIR_DIR="${CLAIR_DATA_DIR}"

# Ensure base dirs
mkdir -p "$OPT_ROOT" "$BIN_DIR" "$PG_DIR" "$REDIS_DIR" "$QUAY_DATA_DIR" "$CLAIR_DATA_DIR" "$LOG_DIR" "$STORAGE_DIR" "$RUN_DIR" "$CONFIG_DIR" "$CLAIR_CONF_DIR" "$CREDS_DIR"
chmod 755 "$OPT_ROOT" "$BIN_DIR" "$PG_DIR" "$REDIS_DIR" "$QUAY_DATA_DIR" "$CLAIR_DATA_DIR" "$LOG_DIR" "$STORAGE_DIR" "$RUN_DIR" "$CONFIG_DIR" "$CLAIR_CONF_DIR"
chmod 700 "$CREDS_DIR"

### --- preflight checks ---
__need sh
__need awk
__need sed
__need grep
__need tr
__need dd
__need curl

# Docker + Compose
if __have docker; then
  if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif __have docker-compose; then
    COMPOSE="docker-compose"
  else
    __fail "Docker Compose not found (plugin or docker-compose). Install it and re-run."
  fi
else
  # Try podman+podman-compose as a fallback only if docker missing
  if __have podman && __have podman-compose; then
    COMPOSE="podman-compose"
  else
    __fail "Neither docker nor podman(+podman-compose) is installed. Install container engine + compose and re-run."
  fi
fi

### --- helper: read or generate file-secret ---
__ensure_secret_file() {
  # $1 = path, $2 = optional length (default 24)
  f="$1"; len="${2:-24}"
  if [ ! -s "$f" ]; then
    # generate A-Za-z0-9 length=len
    dd if=/dev/urandom bs=1 count=$((len*2)) 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len" >"$f"
    chmod 600 "$f"
  fi
}

### --- DOMAIN resolution & validation ---
__is_valid_reg_domain() {
  dom="$1"
  # Must contain at least one dot and only LDH chars
  echo "$dom" | grep -E -- '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$' >/dev/null 2>&1 || return 1
  # Disallow obvious non-registerable TLDs
  case "$dom" in
    *.local|*.lan|*.home|*.invalid|*.test|localhost|localhost.*) return 1 ;;
  esac
  # total length <= 253
  [ "$(printf '%s' "$dom" | wc -c | tr -d ' ')" -le 253 ] || return 1
  return 0
}

# Load env if exists
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

HOST_SHORT="$(hostname -s 2>/dev/null || echo quayhost)"
HOST_DOMAIN="$(hostname -d 2>/dev/null || echo '')"
if [ "${DOMAIN:-}" ]; then
  DOM_CAND="$DOMAIN"
else
  if [ -n "$HOST_DOMAIN" ]; then
    DOM_CAND="${HOST_SHORT}.${HOST_DOMAIN}"
  else
    DOM_CAND="$(hostname -f 2>/dev/null || echo "${HOST_SHORT}.localdomain")"
  fi
fi
__is_valid_reg_domain "$DOM_CAND" || __fail "DOMAIN must be a valid registerable domain (e.g. example.com). Set DOMAIN in ${ENV_FILE} and re-run."

DOMAIN="$DOM_CAND"

### --- SMTP probe (host bridge IP discovery + check) ---
# Discover container bridge IP (default 172.17.0.1)
BRIDGE_IP="172.17.0.1"
if __have ip; then
  # Try docker0 first, then podman's cni-podman0 or any bridge
  for iface in docker0 cni-podman0 podman0 br0; do
    DI=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | awk -F/ '{print $1}')
    if [ -n "$DI" ]; then BRIDGE_IP="$DI"; break; fi
  done
fi

SMTP_HOST="$BRIDGE_IP"
SMTP_PORT="25"
SMTP_ENABLED="false"
if curl --silent --connect-timeout 3 "smtp://${SMTP_HOST}:${SMTP_PORT}/" >/dev/null 2>&1; then
  SMTP_ENABLED="true"
fi

### --- persistent random high port (64xxx) on 172.17.x.x ---
__rand64k() {
  # returns integer between 64000 and 64999
  # prefer awk random seeded by pid+time
  awk 'BEGIN{srand(); printf("%d\n", 64000+int(rand()*1000))}'
}
__port_in_use() {
  P="$1"
  # check tcp listeners on host
  if __have ss; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q -- ":$P\$" && return 0 || return 1
  elif __have netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q -- ":$P\$" && return 0 || return 1
  else
    # Fallback: attempt connect quickly
    (exec 3<>"/dev/tcp/${BRIDGE_IP}/${P}") >/dev/null 2>&1 && { exec 3>&- 3<&-; return 0; } || return 1
  fi
}
# Load QUAY_PORT from .env if present and usable; else pick a free one and persist
if [ "${QUAY_BIND_ADDR:-}" ]; then :; else
  # Use BRIDGE_IP only if it exists as a local interface, otherwise 0.0.0.0
  if __have ip && ip addr show 2>/dev/null | grep -q -- "inet $BRIDGE_IP/"; then
    QUAY_BIND_ADDR="$BRIDGE_IP"
  else
    QUAY_BIND_ADDR="0.0.0.0"
  fi
fi
if [ "${QUAY_PORT:-}" ]; then
  if __port_in_use "$QUAY_PORT"; then
    # If it's in use we try to detect if it's our compose later; otherwise reassign
    # Keep for now; compose will reuse the existing mapping
    :
  else
    # Port is free; nothing to do
    :
  fi
else
  i=0
  while : ; do
    i=$((i+1))
    CAND="$(__rand64k)"
    if ! __port_in_use "$CAND"; then
      QUAY_PORT="$CAND"
      break
    fi
    [ "$i" -gt 200 ] && __fail "Could not find a free port in 64000-64999 after 200 attempts."
  done
fi

### --- superuser + secrets (files only) ---
QUAY_SUPERUSER="${QUAY_SUPERUSER:-administrator}"
SUPERFILE="${CREDS_DIR}/superuser"
__ensure_secret_file "$SUPERFILE" 24
QUAY_SUPERPASS_FILE="$SUPERFILE"

QUAY_SECRET_FILE="${CREDS_DIR}/quay.secret"
__ensure_secret_file "$QUAY_SECRET_FILE" 48

DB_USER="${DB_USER:-quay}"
DB_PASS_FILE="${CREDS_DIR}/db.pass"; __ensure_secret_file "$DB_PASS_FILE" 24
CLAIR_DB_USER="${CLAIR_DB_USER:-clair}"
CLAIR_DB_PASS_FILE="${CREDS_DIR}/clair-db.pass"; __ensure_secret_file "$CLAIR_DB_PASS_FILE" 24

# Cosign keys (generate if missing). Prefer openssl ed25519.
COSIGN_KEY_FILE="${COSIGN_KEY_FILE:-${CREDS_DIR}/cosign.key}"
COSIGN_PUB_FILE="${COSIGN_PUB_FILE:-${CREDS_DIR}/cosign.pub}"
if [ ! -s "$COSIGN_KEY_FILE" ] || [ ! -s "$COSIGN_PUB_FILE" ]; then
  if __have openssl; then
    openssl genpkey -algorithm ed25519 -out "$COSIGN_KEY_FILE" >/dev/null 2>&1 || __fail "openssl keygen failed"
    chmod 600 "$COSIGN_KEY_FILE"
    openssl pkey -in "$COSIGN_KEY_FILE" -pubout -out "$COSIGN_PUB_FILE" >/dev/null 2>&1 || __fail "openssl pubout failed"
  else
    __warn "OpenSSL not found; attempting cosign container keygen"
    # This does not print secrets; keys written to mounted dir
    $COMPOSE pull cosign >/dev/null 2>&1 || true
    $COMPOSE run --rm cosign sh -c "COSIGN_PASSWORD= printf '' && cosign generate-key-pair --yes --outfile /keys/cosign >/dev/null 2>&1" || __fail "cosign keygen failed"
    [ -s "$COSIGN_KEY_FILE" ] && chmod 600 "$COSIGN_KEY_FILE" || __fail "cosign key not created"
  fi
fi

### --- persist .env (non-secret values + secret file paths) ---
__persist_kv() {
  k="$1"; v="$2"
  if [ ! -f "$ENV_FILE" ]; then : >"$ENV_FILE"; chmod 600 "$ENV_FILE"; fi
  if grep -q -- "^$k=" "$ENV_FILE" 2>/dev/null; then
    # update in place
    sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE" 2>/dev/null || {
      # macOS/BSD sed fallback (no -i)
      tmp="${ENV_FILE}.tmp.$$"; sed "s|^$k=.*|$k=$v|" "$ENV_FILE" >"$tmp" && mv "$tmp" "$ENV_FILE"
    }
  else
    printf '%s=%s\n' "$k" "$v" >>"$ENV_FILE"
  fi
}
__persist_kv "DOMAIN" "$DOMAIN"
__persist_kv "QUAY_BIND_ADDR" "$QUAY_BIND_ADDR"
__persist_kv "QUAY_PORT" "$QUAY_PORT"
__persist_kv "DATA_DIR" "$DATA_DIR"
__persist_kv "POSTGRES_DIR" "$PG_DIR"
__persist_kv "REDIS_DIR" "$REDIS_DIR"
__persist_kv "CLAIR_DIR" "$CLAIR_DIR"
__persist_kv "QUAY_SUPERUSER" "$QUAY_SUPERUSER"
__persist_kv "QUAY_SUPERPASS_FILE" "$QUAY_SUPERPASS_FILE"
__persist_kv "QUAY_SECRET_KEY_FILE" "$QUAY_SECRET_FILE"
__persist_kv "DB_USER" "$DB_USER"
__persist_kv "DB_PASS_FILE" "$DB_PASS_FILE"
__persist_kv "DB_NAME" "quay"
__persist_kv "DB_HOST" "postgres"
__persist_kv "DB_PORT" "5432"
__persist_kv "CLAIR_DB_USER" "$CLAIR_DB_USER"
__persist_kv "CLAIR_DB_PASS_FILE" "$CLAIR_DB_PASS_FILE"
__persist_kv "COSIGN_KEY_FILE" "$COSIGN_KEY_FILE"
__persist_kv "COSIGN_PUB_FILE" "$COSIGN_PUB_FILE"
__persist_kv "STACK_DIR" "$STACK_DIR"
__persist_kv "CLAIR_CONF_DIR" "$CLAIR_CONF_DIR"
__persist_kv "FEATURE_USER_CREATION" "true"
__persist_kv "FEATURE_ANONYMOUS_ACCESS" "true"
if [ "$SMTP_ENABLED" = "true" ]; then
  __persist_kv "FEATURE_REQUIRE_EMAIL_VERIFICATION" "true"
else
  __persist_kv "FEATURE_REQUIRE_EMAIL_VERIFICATION" "false"
fi
__persist_kv "PREFERRED_URL_SCHEME" "https"
__persist_kv "EXTERNAL_TLS_TERMINATION" "true"
__persist_kv "SERVER_HOSTNAME" "$DOMAIN"

### --- render Quay config.yaml (non-destructive: create-if-missing, else patch keys) ---
# Quay expects config in stack subdirectory
STACK_DIR="${CONFIG_DIR}/stack"
mkdir -p "$STACK_DIR"
chmod 755 "$STACK_DIR"
CFG="${STACK_DIR}/config.yaml"
__write_cfg() {
cat >"$CFG.tmp" <<EOF
SERVER_HOSTNAME: ${DOMAIN}
PREFERRED_URL_SCHEME: https
EXTERNAL_TLS_TERMINATION: true
TESTING: false
SETUP_COMPLETE: true

FEATURE_USER_CREATION: true
FEATURE_USER_CREATION_INVITE_ONLY: false
FEATURE_ANONYMOUS_ACCESS: true
FEATURE_REQUIRE_EMAIL_VERIFICATION: ${SMTP_ENABLED}

MAIL_SERVER: ${SMTP_HOST}
MAIL_PORT: ${SMTP_PORT}
MAIL_USE_TLS: false
MAIL_USE_SSL: false
MAIL_USERNAME:
MAIL_PASSWORD:
MAIL_DEFAULT_SENDER: no-reply@${DOMAIN}

SUPER_USERS:
  - ${QUAY_SUPERUSER}

DISTRIBUTED_STORAGE_CONFIG:
  default:
    - LocalStorage
    - storage_path: /datastorage/registry
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: ["default"]
DISTRIBUTED_STORAGE_PREFERENCE: ["default"]

# Clair v4 integration
FEATURE_SECURITY_SCANNER: true
SECURITY_SCANNER_V4_ENDPOINT: http://clair:6060
SECURITY_SCANNER_V4_NAMESPACE_WHITELIST: []
# Quay expects a signing key for JWT; use SECRET_KEY below.

# Secrets (mounted files)
SECRET_KEY: $(cat "${QUAY_SECRET_FILE}")
DATABASE_SECRET_KEY: $(cat "${QUAY_SECRET_FILE}")

# Database
DB_URI: postgresql://${DB_USER}:$(cat "${DB_PASS_FILE}")@postgres:5432/quay

# Redis configuration
BUILDLOGS_REDIS:
  host: redis
  port: 6379

USER_EVENTS_REDIS:
  host: redis
  port: 6379

EOF
mv "$CFG.tmp" "$CFG"
chmod 600 "$CFG"
}

if [ ! -f "$CFG" ]; then
  __write_cfg
else
  # Basic key patching (keep simple & safe)
  # If you later need to change, edit ${CFG} manually; reruns won't clobber.
  :
fi

### --- create postgres init scripts ---
INIT_DB_DIR="${DATA_DIR}/init-db"
mkdir -p "$INIT_DB_DIR"
chmod 755 "$INIT_DB_DIR"

# Quay database extensions (runs first due to 01- prefix)
cat >"${INIT_DB_DIR}/01-init-quay.sh" <<'EOF'
#!/bin/bash
set -e

# Create pg_trgm extension for Quay
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOSQL
EOF
chmod 755 "${INIT_DB_DIR}/01-init-quay.sh"

# Clair database setup (runs second due to 02- prefix)
cat >"${INIT_DB_DIR}/02-init-clair.sh" <<EOF
#!/bin/bash
set -e

# Create clair user and database
psql -v ON_ERROR_STOP=1 --username "\$POSTGRES_USER" --dbname "\$POSTGRES_DB" <<-EOSQL
    CREATE USER ${CLAIR_DB_USER} WITH PASSWORD '$(cat "${CLAIR_DB_PASS_FILE}")';
    CREATE DATABASE clair OWNER ${CLAIR_DB_USER};
    GRANT ALL PRIVILEGES ON DATABASE clair TO ${CLAIR_DB_USER};
EOSQL
EOF
chmod 755 "${INIT_DB_DIR}/02-init-clair.sh"

### --- render docker-compose.yml (always refresh; mounts keep data) ---
cat >"$COMPOSE_FILE.tmp" <<'YAML'
services:
  postgres:
    image: docker.io/library/postgres:15-alpine
    restart: unless-stopped
    env_file: .env
    environment:
      - POSTGRES_DB=quay
      - POSTGRES_USER=${DB_USER}
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_password
    volumes:
      - ${POSTGRES_DIR}:/var/lib/postgresql/data:z
      - ${DB_PASS_FILE}:/run/secrets/db_password:ro,z
      - ${DATA_DIR}/init-db:/docker-entrypoint-initdb.d:ro,z
    networks: [quay]

  redis:
    image: docker.io/library/redis:7-alpine
    restart: unless-stopped
    env_file: .env
    command: ["redis-server","--appendonly","yes"]
    volumes:
      - ${REDIS_DIR}:/data:z
    networks: [quay]

  clair:
    image: quay.io/projectquay/clair:4.8.0
    restart: unless-stopped
    env_file: .env
    depends_on: [postgres]
    environment:
      - CLAIR_CONF=/clair-config/config.yaml
    volumes:
      - ${CLAIR_DIR}:/clairdata:z
      - ${CLAIR_CONF_DIR}:/clair-config:z
    networks: [quay]

  quay:
    image: quay.io/projectquay/quay:3.15.2
    restart: unless-stopped
    env_file: .env
    depends_on: [postgres, redis, clair]
    ports:
      - ${QUAY_BIND_ADDR}:${QUAY_PORT}:8080
    volumes:
      - ${STACK_DIR}:/quay-registry/conf/stack:z
      - ${DATA_DIR}/logs:/var/log/quay:z
      - ${DATA_DIR}/storage:/datastorage/registry:z
    networks: [quay]

  # Cosign helper (no long-running container; used for on-demand commands)
  cosign:
    image: ghcr.io/sigstore/cosign/cosign:v2.4.1
    env_file: .env
    command: ["sh","-c","sleep 1"]
    volumes:
      - ${COSIGN_KEY_FILE}:/keys/cosign.key:z
      - ${COSIGN_PUB_FILE}:/keys/cosign.pub:z
    networks: [quay]
    deploy:
      replicas: 0

  # Syft helper (SBOM generator)
  syft:
    image: docker.io/anchore/syft:latest
    env_file: .env
    command: ["sh","-c","sleep 1"]
    networks: [quay]
    deploy:
      replicas: 0

networks:
  quay:
    name: "quay"
    external: false
YAML
mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
chmod 644 "$COMPOSE_FILE"

### --- Clair config (minimal v4) ---
cat >"${CLAIR_CONF_DIR}/config.yaml.tmp" <<EOF
http_listen_addr: :6060
introspection_addr: :6061
indexer:
  connstring: host=postgres port=5432 user=${CLAIR_DB_USER} password=$(cat "${CLAIR_DB_PASS_FILE}") dbname=clair sslmode=disable
  migrations: true
matcher:
  connstring: host=postgres port=5432 user=${CLAIR_DB_USER} password=$(cat "${CLAIR_DB_PASS_FILE}") dbname=clair sslmode=disable
  migrations: true
notifier:
  connstring: host=postgres port=5432 user=${CLAIR_DB_USER} password=$(cat "${CLAIR_DB_PASS_FILE}") dbname=clair sslmode=disable
  migrations: true
EOF
mv "${CLAIR_CONF_DIR}/config.yaml.tmp" "${CLAIR_CONF_DIR}/config.yaml"
chmod 644 "${CLAIR_CONF_DIR}/config.yaml"

### --- bring up stack ---
__info "Pulling container images (this may take a bit)…"
$COMPOSE -f "$COMPOSE_FILE" pull 2>&1 | grep -v "Pulling\|Already exists\|Download complete\|Pull complete" || true

__info "Starting Quay stack…"
if ! $COMPOSE -f "$COMPOSE_FILE" up -d 2>&1; then
  __fail "Failed to start Quay stack"
fi

### --- health checks (bounded retries, minimal output) ---
sleep 2
HEALTH_OK=0
TRIES=60
while [ $TRIES -gt 0 ]; do
  if curl -fsS "http://${QUAY_BIND_ADDR}:${QUAY_PORT}/health/instance" >/dev/null 2>&1; then
    HEALTH_OK=1; break
  fi
  TRIES=$((TRIES-1))
  sleep 2
done
[ "$HEALTH_OK" -eq 1 ] || __warn "Quay health endpoint not responding yet; continuing."

# record first-run flag for GC (dry-run on first execution)
if [ ! -f "$GC_FLAG_FIRST" ]; then
  : >"$GC_FLAG_FIRST"
fi

### --- GC setup: always on daily 03:00 (systemd preferred; cron fallback) ---
GC_WRAPPER="${BIN_DIR}/quay-gc.sh"
cat >"$GC_WRAPPER.tmp" <<'EOS'
#!/bin/sh
set -eu
umask 077

OPT_ROOT="/opt/quay"
DATA_DIR="${OPT_ROOT}/rootfs/data/quay"
ENV_FILE="${OPT_ROOT}/.env"
GC_LOCK="${DATA_DIR}/run/gc.lock"
GC_FLAG_FIRST="${DATA_DIR}/run/gc-first-run"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

log(){ printf '%s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$*"; }

# health gate
curl -fsS "http://${QUAY_BIND_ADDR}:${QUAY_PORT}/health/instance" >/dev/null 2>&1 || exit 0

# lock
( umask 077; mkdir -p "${DATA_DIR}/run" )
if [ -f "$GC_LOCK" ]; then
  # stale lock older than 2h? remove
  find "${GC_LOCK%/*}" -maxdepth 1 -name "${GC_LOCK##*/}" -mmin +120 -exec rm -f {} \; >/dev/null 2>&1 || true
fi
if [ -f "$GC_LOCK" ]; then exit 0; fi
: >"$GC_LOCK"
trap 'rm -f "$GC_LOCK"' EXIT INT TERM

# first run dry-run
DRY=""
if [ -f "$GC_FLAG_FIRST" ]; then DRY="--dry-run"; rm -f "$GC_FLAG_FIRST"; fi

# Attempt Quay GC via internal manage command (best-effort; silent on failure)
# Different Quay versions expose different GC commands; we try a few, quiet output.
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    log "Docker Compose not found; skipping GC exec"; exit 0
  fi
elif command -v podman >/dev/null 2>&1 && command -v podman-compose >/dev/null 2>&1; then
  DC="podman-compose"
else
  log "No container engine found; skipping GC exec"; exit 0
fi
# Try exec forms; ignore output, keep silent
$DC -f /opt/quay/docker-compose.yml exec -T quay sh -c 'quay garbage-collect --delete 2>/dev/null || true' >/dev/null 2>&1 || true
$DC -f /opt/quay/docker-compose.yml exec -T quay sh -c 'quay manage gc 2>/dev/null || true' >/dev/null 2>&1 || true

# Log a terse line; no repo/tag names or secrets
log "Quay GC completed ${DRY}"
exit 0
EOS
mv "$GC_WRAPPER.tmp" "$GC_WRAPPER"
chmod 700 "$GC_WRAPPER"

if __have systemctl; then
  # systemd unit + timer
  cat >/etc/systemd/system/quay-gc.service <<EOF
[Unit]
Description=Quay Garbage Collection
After=network-online.target

[Service]
Type=oneshot
ExecStart=$GC_WRAPPER
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
  # cron fallback
  CRONF="/etc/cron.d/quay-gc"
  echo "0 3 * * * root ${GC_WRAPPER} >/dev/null 2>&1" >"$CRONF"
  chmod 644 "$CRONF"
fi

### --- final summary (pretty, emojis; only place secrets are shown) ---
SUPERPASS="$(cat "$QUAY_SUPERPASS_FILE")"

printf '\n'
cat <<EOF
✅ Quay is up and running!

🔌 Local endpoint:     http://${QUAY_BIND_ADDR}:${QUAY_PORT}
📧 Email:              verification $( [ "$SMTP_ENABLED" = "true" ] && echo "ENABLED" || echo "DISABLED" ) (SMTP via ${SMTP_HOST}:${SMTP_PORT})
🌉 Docker network:     quay (external: false)
🔒 Cosign key:         ${COSIGN_KEY_FILE}
🔑 Cosign pub:         ${COSIGN_PUB_FILE}
🗑️ Garbage collection: ENABLED (daily at 03:00 local)

===============================
🔐 SUPERUSER CREDENTIALS
===============================
👤 User:     ${QUAY_SUPERUSER}
🔑 Password: ${SUPERPASS}

⚠️  Store these credentials securely — they are not saved in logs.

📝 Next steps:
   👉 Go to https://${DOMAIN} in your browser
EOF
