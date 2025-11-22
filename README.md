# Quay Installer (Self-Hosted Container Registry)

A single POSIX-compliant installer script (`install.sh`) that sets up a full-featured [Quay](https://quay.io/) container registry with security scanning, signing, SBOM support, and automated garbage collection.

Designed to be **distro-agnostic**, **idempotent**, and safe to re-run.

---

## Features

- **Quay Stack (Docker Compose)**
  - Quay (registry + UI + API)
  - Postgres 15 (database)
  - Redis 7 (cache)
  - Clair v4 (vulnerability scanning)
  - Cosign (image signing)
  - Syft (SBOM generation)

- **Authentication & Access**
  - Open user registration
  - Anonymous pulls for public repos
  - Auth required for pushes
  - Organizations, teams, and robot accounts

- **Supply Chain Security**
  - Cosign keypair auto-generated on first run
  - OCI signature storage built into Quay
  - SBOMs generated with Syft

- **Email & User Management**
  - SMTP auto-detect via Docker host (`172.17.0.1:25`)
  - Email verification enabled if SMTP is reachable
  - Default sender: `no-reply@<DOMAIN>`

- **Security & Hardening**
  - Secrets stored in files with `0600` permissions
  - Never printed to logs; only shown in final summary
  - SELinux-safe mounts (`:z`)
  - Daily garbage collection at 03:00

- **Networking**
  - Quay bound to `172.17.0.1:<random 64xxx>` (persisted across restarts)
  - Designed for reverse proxy with TLS termination
  - Isolated Docker network `quay`

---

## Requirements

- Linux host with:
  - `sh`, `awk`, `sed`, `grep`, `tr`, `dd`, `curl`
  - Docker or Podman with Docker Compose
- Outbound internet access (for pulling images and Clair updates)
- Valid domain name pointing to your host (for TLS via reverse proxy)

---

## Quick Start

```sh
git clone https://github.com/scriptmgr/quay
cd quay
DOMAIN=registry.example.com sh install.sh
```

The installer will:
1. Create necessary directories and secrets
2. Generate Quay and Clair configurations
3. Pull and start all containers
4. Wait for health checks to pass
5. Display superuser credentials

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | (required) | Registry hostname (e.g., `registry.example.com`) |
| `OPT_ROOT` | `/opt/quay` | Installation directory for compose files |
| `DATA_DIR` | `/var/lib/quay` | Data directory for configs, secrets, storage |

### Directory Structure

```
/opt/quay/
├── docker-compose.yml
└── .env

/var/lib/quay/
├── config/stack/config.yaml    # Quay configuration
├── credentials/
│   ├── db_password             # Postgres password
│   ├── quay_secret             # Quay secret key
│   ├── clair_db_password       # Clair DB password
│   ├── cosign.key              # Cosign private key
│   └── cosign.pub              # Cosign public key
├── clair-config/config.yaml    # Clair configuration
├── init-db/                    # Postgres init scripts
├── storage/                    # Registry blob storage
├── logs/                       # Quay logs
└── postgres/                   # Postgres data
```

---

## Client Configuration

Quay runs on HTTP internally and expects TLS termination at a reverse proxy. For local/internal testing without TLS, configure Docker to allow insecure registries.

### Option 1: Via Reverse Proxy (Recommended)

Configure your reverse proxy (nginx, Caddy, Traefik) to:
- Listen on `https://registry.example.com`
- Proxy to `http://172.17.0.1:<port>` (port shown in install output)
- Terminate TLS

### Option 2: Insecure Registry (Testing Only)

Add to `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["172.17.0.1:64xxx"]
}
```

Replace `64xxx` with the actual port from the install output, then restart Docker:

```sh
systemctl restart docker
cd /opt/quay && docker compose up -d
```

---

## Usage

### Login

```sh
docker login registry.example.com -u administrator
# Or for insecure local testing:
docker login 172.17.0.1:64xxx -u administrator
```

### Push an Image

```sh
docker tag myimage:latest registry.example.com/administrator/myimage:latest
docker push registry.example.com/administrator/myimage:latest
```

### Pull an Image

```sh
docker pull registry.example.com/administrator/myimage:latest
```

### Access Web UI

Navigate to `https://registry.example.com` (or `http://172.17.0.1:<port>` for local testing).

---

## Management

### Start/Stop Stack

```sh
cd /opt/quay
docker compose up -d      # Start
docker compose down       # Stop
docker compose restart    # Restart
```

### View Logs

```sh
docker compose -f /opt/quay/docker-compose.yml logs -f quay
docker compose -f /opt/quay/docker-compose.yml logs -f clair
```

### Check Health

```sh
curl http://172.17.0.1:<port>/health/instance
```

### Re-run Installer

The script is idempotent. Re-run to update configurations:

```sh
DOMAIN=registry.example.com sh install.sh
```

Existing data and secrets are preserved.

---

## Troubleshooting

### Containers not starting

Check logs:
```sh
docker compose -f /opt/quay/docker-compose.yml logs
```

### Clair not scanning

Clair needs time to download vulnerability databases on first start. Check logs:
```sh
docker logs quay-clair-1 -f
```

### Database connection errors

Ensure Postgres is healthy:
```sh
docker exec quay-postgres-1 pg_isready
```

### Permission denied errors

Check SELinux context and file permissions on data directories.

---

## Uninstall

```sh
cd /opt/quay
docker compose down -v
rm -rf /opt/quay /var/lib/quay /var/lib/postgres /var/lib/redis /var/lib/clair
```

---

## License

MIT
