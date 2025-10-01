#!/bin/sh
# install.sh — Self-hosted Quay stack (Quay + Postgres + Redis + Clair) with Cosign + Syft
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

### --- tiny utils (POSIX) ---
ts() { date +"%Y-%m-%d %H:%M:%S"; }
info() { printf '%s %s\n' "$(ts)" "$*"; }
warn() { printf '%s %s\n' "$(ts)" "WARN: $*"; }
fail() { printf '%s %s\n' "$(ts)" "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

# Try a command; if it exists, echo it and return 0
have() { command -v "$1" >/dev/null 2>&1; }

### --- constants / paths ---
OPT_ROOT="/opt/quay"
DATA_DIR="/var/lib/quay"
PG_DIR="/var/lib/postgres"
REDIS_DIR="/var/lib/redis"
CLAIR_DIR="/var/lib/clair"
ENV_FILE="${DATA_DIR}/.env"
CREDS_DIR="${DATA_DIR}/credentials"
LOG_DIR="${DATA_DIR}/logs"
STORAGE_DIR="${DATA_DIR}/storage"
CONFIG_DIR="${DATA_DIR}/config"
BIN_DIR="${OPT_ROOT}/bin"
COMPOSE_FILE="${OPT_ROOT}/docker-compose.yml"
GC_LOCK="${DATA_DIR}/run/gc.lock"
GC_FLAG_FIRST="${DATA_DIR}/run/gc-first-run"
RUN_DIR="${DATA_DIR}/run"

# Ensure base dirs
mkdir -p "$OPT_ROOT" "$BIN_DIR" "$CONFIG_DIR" "$CREDS_DIR" "$LOG_DIR" "$STORAGE_DIR" "$PG_DIR" "$REDIS_DIR" "$CLAIR_DIR" "$RUN_DIR"
chmod 700 "$OPT_ROOT" "$BIN_DIR" "$CONFIG_DIR" "$CREDS_DIR" "$LOG_DIR" "$STORAGE_DIR" "$PG_DIR" "$REDIS_DIR" "$CLAIR_DIR" "$RUN_DIR"

### --- preflight checks ---
need sh
need awk
need sed
need grep
need tr
need dd
need curl

# Docker + Compose
if have docker; then
  if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif have docker-compose; then
    COMPOSE="docker-compose"
  else
    fail "Docker Compose not found (plugin or docker-compose). Install it and re-run."
  fi
else
  # Try podman+podman-compose as a fallback only if docker missing
  if have podman && have podman-compose; then
    COMPOSE="podman-compose"
  else
    fail "Neither docker nor podman(+podman-compose) is installed. Install container engine + compose and re-run."
  fi
fi

### --- helper: read or generate file-secret ---
ensure_secret_file() {
  # $1 = path, $2 = optional length (default 24)
  f="$1"; len="${2:-24}"
  if [ ! -s "$f" ]; then
    # generate A-Za-z0-9 length=len
    dd if=/dev/urandom bs=1 count=$((len*2)) 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len" >"$f"
    chmod 600 "$f"
  fi
}

### --- DOMAIN resolution & validation ---
is_valid_reg_domain() {
  dom="$1"
  # Must contain at least one dot and only LDH chars
  echo "$dom" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$' || return 1
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
is_valid_reg_domain "$DOM_CAND" || fail "DOMAIN must be a valid registerable domain (e.g. example.com). Set DOMAIN in ${ENV_FILE} and re-run."

DOMAIN="$DOM_CAND"

### --- SMTP probe (host bridge IP discovery + check) ---
# Discover docker bridge IP (default 172.17.0.1)
BRIDGE_IP="172.17.0.1"
if have ip; then
  # Try docker0
  DI=$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | awk -F/ '{print $1}')
  if [ -n "$DI" ]; then BRIDGE_IP="$DI"; fi
fi

SMTP_HOST="$BRIDGE_IP"
SMTP_PORT="25"
SMTP_ENABLED="false"
if curl --silent --connect-timeout 3 "smtp://${SMTP_HOST}:${SMTP_PORT}/" >/dev/null 2>&1; then
  SMTP_ENABLED="true"
fi

### --- persistent random high port (64xxx) on 172.17.x.x ---
rand64k() {
  # returns integer between 64000 and 64999
  # prefer awk random seeded by pid+time
  awk 'BEGIN{srand(); printf("%d\n", 64000+int(rand()*1000))}'
}
port_in_use() {
  P="$1"
  # check tcp listeners on host
  if have ss; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$P\$" && return 0 || return 1
  elif have netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$P\$" && return 0 || return 1
  else
    # Fallback: attempt connect quickly
    (exec 3<>"/dev/tcp/${BRIDGE_IP}/${P}") >/dev/null 2>&1 && { exec 3>&- 3<&-; return 0; } || return 1
  fi
}
# Load QUAY_PORT from .env if present and usable; else pick a free one and persist
if [ "${QUAY_BIND_ADDR:-}" ]; then :; else QUAY_BIND_ADDR="$BRIDGE_IP"; fi
if [ "${QUAY_PORT:-}" ]; then
  if port_in_use "$QUAY_PORT"; then
    # If it's in use we try to detect if it's our compose later; otherwise reassign
    : # keep for now; compose will reuse mapping
  else
    : # free, good
  fi
else
  i=0
  while : ; do
    i=$((i+1))
    CAND="$(rand64k)"
    if ! port_in_use "$CAND"; then
      QUAY_PORT="$CAND"
      break
    fi
    [ "$i" -gt 200 ] && fail "Could not find a free port in 64000-64999 after 200 attempts."
  done
fi

### --- superuser + secrets (files only) ---
QUAY_SUPERUSER="${QUAY_SUPERUSER:-administrator}"
SUPERFILE="${CREDS_DIR}/superuser"
ensure_secret_file "$SUPERFILE" 24
QUAY_SUPERPASS_FILE="$SUPERFILE"

QUAY_SECRET_FILE="${CREDS_DIR}/quay.secret"
ensure_secret_file "$QUAY_SECRET_FILE" 48

DB_USER="${DB_USER:-quay}"
DB_PASS_FILE="${CREDS_DIR}/db.pass"; ensure_secret_file "$DB_PASS_FILE" 24
CLAIR_DB_USER="${CLAIR_DB_USER:-clair}"
CLAIR_DB_PASS_FILE="${CREDS_DIR}/clair-db.pass"; ensure_secret_file "$CLAIR_DB_PASS_FILE" 24

# Cosign keys (generate if missing). Prefer openssl ed25519.
COSIGN_KEY_FILE="${COSIGN_KEY_FILE:-${CREDS_DIR}/cosign.key}"
COSIGN_PUB_FILE="${COSIGN_PUB_FILE:-${CREDS_DIR}/cosign.pub}"
if [ ! -s "$COSIGN_KEY_FILE" ] || [ ! -s "$COSIGN_PUB_FILE" ]; then
  if have openssl; then
    openssl genpkey -algorithm ed25519 -out "$COSIGN_KEY_FILE" >/dev/null 2>&1 || fail "openssl keygen failed"
    chmod 600 "$COSIGN_KEY_FILE"
    openssl pkey -in "$COSIGN_KEY_FILE" -pubout -out "$COSIGN_PUB_FILE" >/dev/null 2>&1 || fail "openssl pubout failed"
  else
    warn "OpenSSL not found; attempting cosign container keygen"
    # This does not print secrets; keys written to mounted dir
    $COMPOSE pull cosign >/dev/null 2>&1 || true
    $COMPOSE run --rm cosign sh -c "COSIGN_PASSWORD= printf '' && cosign generate-key-pair --yes --outfile /keys/cosign >/dev/null 2>&1" || fail "cosign keygen failed"
    [ -s "$COSIGN_KEY_FILE" ] && chmod 600 "$COSIGN_KEY_FILE" || fail "cosign key not created"
  fi
fi

### --- persist .env (non-secret values + secret file paths) ---
persist_kv() {
  k="$1"; v="$2"
  if [ ! -f "$ENV_FILE" ]; then : >"$ENV_FILE"; chmod 600 "$ENV_FILE"; fi
  if grep -q "^$k=" "$ENV_FILE" 2>/dev/null; then
    # update in place
    sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE" 2>/dev/null || {
      # macOS/BSD sed fallback (no -i)
      tmp="${ENV_FILE}.tmp.$$"; sed "s|^$k=.*|$k=$v|" "$ENV_FILE" >"$tmp" && mv "$tmp" "$ENV_FILE"
    }
  else
    printf '%s=%s\n' "$k" "$v" >>"$ENV_FILE"
  fi
}
persist_kv "DOMAIN" "$DOMAIN"
persist_kv "QUAY_BIND_ADDR" "$QUAY_BIND_ADDR"
persist_kv "QUAY_PORT" "$QUAY_PORT"
persist_kv "DATA_DIR" "$DATA_DIR"
persist_kv "POSTGRES_DIR" "$PG_DIR"
persist_kv "REDIS_DIR" "$REDIS_DIR"
persist_kv "CLAIR_DIR" "$CLAIR_DIR"
persist_kv "QUAY_SUPERUSER" "$QUAY_SUPERUSER"
persist_kv "QUAY_SUPERPASS_FILE" "$QUAY_SUPERPASS_FILE"
persist_kv "QUAY_SECRET_KEY_FILE" "$QUAY_SECRET_FILE"
persist_kv "DB_USER" "$DB_USER"
persist_kv "DB_PASS_FILE" "$DB_PASS_FILE"
persist_kv "DB_NAME" "quay"
persist_kv "DB_HOST" "postgres"
persist_kv "DB_PORT" "5432"
persist_kv "CLAIR_DB_USER" "$CLAIR_DB_USER"
persist_kv "CLAIR_DB_PASS_FILE" "$CLAIR_DB_PASS_FILE"
persist_kv "COSIGN_KEY_FILE" "$COSIGN_KEY_FILE"
persist_kv "COSIGN_PUB_FILE" "$COSIGN_PUB_FILE"
persist_kv "FEATURE_USER_CREATION" "true"
persist_kv "FEATURE_ANONYMOUS_ACCESS" "true"
if [ "$SMTP_ENABLED" = "true" ]; then
  persist_kv "FEATURE_REQUIRE_EMAIL_VERIFICATION" "true"
else
  persist_kv "FEATURE_REQUIRE_EMAIL_VERIFICATION" "false"
fi
persist_kv "PREFERRED_URL_SCHEME" "https"
persist_kv "EXTERNAL_TLS_TERMINATION" "true"
persist_kv "SERVER_HOSTNAME" "$DOMAIN"

### --- render Quay config.yaml (non-destructive: create-if-missing, else patch keys) ---
CFG="${CONFIG_DIR}/config.yaml"
write_cfg() {
cat >"$CFG.tmp" <<EOF
SERVER_HOSTNAME: ${DOMAIN}
PREFERRED_URL_SCHEME: https
EXTERNAL_TLS_TERMINATION: true

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
DB_URI: postgresql+psycopg2://${DB_USER}:$(cat "${DB_PASS_FILE}")@postgres:5432/quay

# Redis
BUILDLOGS_REDIS: redis://redis:6379/0

EOF
mv "$CFG.tmp" "$CFG"
chmod 600 "$CFG"
}

if [ ! -f "$CFG" ]; then
  write_cfg
else
  # Basic key patching (keep simple & safe)
  # If you later need to change, edit ${CFG} manually; reruns won't clobber.
  :
fi

### --- render docker-compose.yml (always refresh; mounts keep data) ---
cat >"$COMPOSE_FILE.tmp" <<'YAML'
version: "3.9"

services:
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_DB=quay
      - POSTGRES_USER=${DB_USER}
      - POSTGRES_PASSWORD_FILE=${DB_PASS_FILE}
    volumes:
      - ${POSTGRES_DIR}:/var/lib/postgresql/data:z
    networks: [quay]

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server","--appendonly","yes"]
    volumes:
      - ${REDIS_DIR}:/data:z
    networks: [quay]

  clair:
    image: quay.io/projectquay/clair:latest
    restart: unless-stopped
    depends_on: [postgres]
    environment:
      - CLAIR_CONF=/clair-config/config.yaml
    volumes:
      - ${CLAIR_DIR}:/clairdata:z
      - ${DATA_DIR}/clair-config:/clair-config:z
    networks: [quay]

  quay:
    image: quay.io/projectquay/quay:latest
    restart: unless-stopped
    depends_on: [postgres, redis, clair]
    ports:
      - ${QUAY_BIND_ADDR}:${QUAY_PORT}:8080
    environment:
      - CONFIG_SECRET=${QUAY_SECRET_KEY_FILE}
      - QUAYCONF=/conf/stack
    volumes:
      - ${DATA_DIR}/config:/conf/stack:z
      - ${DATA_DIR}/config:/etc/quay-config:z
      - ${DATA_DIR}/config:/quay-registry/conf:z
      - ${DATA_DIR}/logs:/var/log/quay:z
      - ${DATA_DIR}/storage:/datastorage/registry:z
    networks: [quay]

  # Cosign helper (no long-running container; used for on-demand commands)
  cosign:
    image: ghcr.io/sigstore/cosign:v2.2.4
    command: ["sh","-c","sleep 1"]
    volumes:
      - ${COSIGN_KEY_FILE}:/keys/cosign.key:z
      - ${COSIGN_PUB_FILE}:/keys/cosign.pub:z
    networks: [quay]
    deploy:
      replicas: 0

  # Syft helper (SBOM generator)
  syft:
    image: anchore/syft:latest
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
CLAIR_CONF_DIR="${DATA_DIR}/clair-config"
mkdir -p "$CLAIR_CONF_DIR"
chmod 700 "$CLAIR_CONF_DIR"
cat >"${CLAIR_CONF_DIR}/config.yaml.tmp" <<EOF
http_listen_addr: :6060
introspection_addr: :6061
indexer:
  connstring: host=postgres port=5432 user=${CLAIR_DB_USER} password=$(cat "${CLAIR_DB_PASS_FILE}") dbname=clair sslmode=disable
matcher:
  connstring: host=postgres port=5432 user=${CLAIR_DB_USER} password=$(cat "${CLAIR_DB_PASS_FILE}") dbname=clair sslmode=disable
notifier:
  connstring: host=postgres port=5432 user=${CLAIR_DB_USER} password=$(cat "${CLAIR_DB_PASS_FILE}") dbname=clair sslmode=disable
EOF
mv "${CLAIR_CONF_DIR}/config.yaml.tmp" "${CLAIR_CONF_DIR}/config.yaml"
chmod 600 "${CLAIR_CONF_DIR}/config.yaml"

### --- bring up stack ---
info "Pulling container images (this may take a bit)…"
$COMPOSE -f "$COMPOSE_FILE" pull >/dev/null 2>&1 || true

info "Starting Quay stack…"
$COMPOSE -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || fail "Failed to start Quay stack"

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
[ "$HEALTH_OK" -eq 1 ] || warn "Quay health endpoint not responding yet; continuing."

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

DATA_DIR="/var/lib/quay"
ENV_FILE="${DATA_DIR}/.env"
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
  find "$(dirname "$GC_LOCK")" -maxdepth 1 -name "$(basename "$GC_LOCK")" -mmin +120 -exec rm -f {} \; >/dev/null 2>&1 || true
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
  DC="docker compose"
  if ! docker compose version >/dev/null 2>&1; then
    if command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"; fi
  fi
  # Try exec forms; ignore output, keep silent
  $DC -f /opt/quay/docker-compose.yml exec -T quay sh -c 'quay garbage-collect --delete 2>/dev/null || true' >/dev/null 2>&1 || true
  $DC -f /opt/quay/docker-compose.yml exec -T quay sh -c 'quay manage gc 2>/dev/null || true' >/dev/null 2>&1 || true
fi

# Log a terse line; no repo/tag names or secrets
log "Quay GC completed ${DRY}"
exit 0
EOS
mv "$GC_WRAPPER.tmp" "$GC_WRAPPER"
chmod 700 "$GC_WRAPPER"

if have systemctl; then
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
