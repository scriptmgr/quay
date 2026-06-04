# Quay Installer (Self-Hosted Container Registry)

A single POSIX-compliant installer script (`install.sh`) that sets up a full-featured [Quay](https://quay.io/) container registry with vulnerability scanning, image signing, SBOM support, and automated garbage collection.

Designed to be **distro-agnostic**, **idempotent**, and safe to re-run.

---

## 📦 Install

```sh
git clone https://github.com/scriptmgr/quay
cd quay
DOMAIN=registry.example.com sh install.sh
```

The installer will:

1. Detect or generate all secrets into `/opt/quay/.env` (mode 600)
2. Create the directory tree under `/opt/quay/volumes/`
3. Generate Quay and Clair configurations
4. Pull and start all containers via Docker Compose
5. Wait for Quay's health endpoint to respond
6. Set up daily garbage collection (systemd timer preferred; cron fallback)
7. Print superuser credentials — the only time they are displayed

---

## ⚙️ Configuration

### Environment Variables

Pass these before `sh install.sh` to override defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | auto-detected from `hostname` | Registry hostname (e.g. `registry.example.com`) |
| `APP_ADMIN_USER` | `administrator` | Superuser account created on first run |
| `DB_USER_NAME` | `quay` | Postgres user for the Quay database |
| `CLAIR_DB_USER_NAME` | `clair` | Postgres user for the Clair database |
| `TZ` | `America/New_York` | Timezone for all containers |

All other values (passwords, secret keys, port) are auto-generated and persisted to `/opt/quay/.env`.

### `.env` File

The installer writes a single `/opt/quay/.env` (mode 600, never committed) on every run. It is sourced on subsequent runs to preserve secrets across re-runs. See `.env.sample` in this repo for the full list of variables and generation commands.

### Directory Structure

All runtime data lives under `/opt/quay/volumes/` — the Docker Compose `./volumes/` convention. Easy to back up as a single directory.

```
/opt/quay/
├── .env                              # All credentials and config (mode 600)
├── docker-compose.yml                # Generated compose file
├── bin/
│   └── quay-gc.sh                    # Garbage collection wrapper
└── volumes/
    ├── data/
    │   ├── db/
    │   │   ├── postgres/quay/        # Postgres data
    │   │   └── redis/                # Redis data
    │   ├── quay/
    │   │   ├── storage/              # Registry blob storage
    │   │   ├── logs/                 # Quay logs
    │   │   └── run/                  # GC lock and first-run flag
    │   └── clair/                    # Clair vulnerability data
    └── config/
        ├── quay/
        │   ├── stack/
        │   │   └── config.yaml       # Quay configuration (mode 640, root:root)
        │   └── init-db/              # Postgres first-boot init scripts
        ├── clair/
        │   └── config.yaml           # Clair configuration (mode 640, nobody:nobody)
        └── credentials/              # Cosign keys (mode 700 dir, 600 files)
            ├── cosign.key
            └── cosign.pub
```

To back up everything:

```sh
tar -czf quay-backup.tar.gz /opt/quay/.env /opt/quay/volumes
```

---

## 🔌 Client Setup

Quay runs on HTTP internally and expects TLS termination at a reverse proxy.

### Option 1: Reverse Proxy (Recommended)

Configure nginx, Caddy, or Traefik to:

- Listen on `https://registry.example.com`
- Proxy to `http://172.17.0.1:<port>` (port shown in installer output)
- Terminate TLS

### Option 2: Insecure Registry (Testing Only)

Add to `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["172.17.0.1:62xxx"]
}
```

Replace `62xxx` with the actual port from the install output, then:

```sh
systemctl restart docker
cd /opt/quay && docker compose up -d
```

---

## 🐳 Usage

### Login

```sh
docker login registry.example.com -u administrator
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

### Web UI

Navigate to `https://registry.example.com`.

---

## 🛠️ Management

### Start / Stop

```sh
cd /opt/quay
docker compose up -d      # start
docker compose down       # stop
docker compose restart    # restart
```

### View Logs

```sh
docker compose -f /opt/quay/docker-compose.yml logs -f quay-app
docker compose -f /opt/quay/docker-compose.yml logs -f quay-clair
```

### Health Check

```sh
curl http://172.17.0.1:<port>/health/instance
```

### Re-run Installer

The script is idempotent — re-run to update configurations. Existing secrets and data are preserved:

```sh
DOMAIN=registry.example.com sh install.sh
```

---

## 🔍 Troubleshooting

### Containers not starting

```sh
docker compose -f /opt/quay/docker-compose.yml logs
```

### Clair not scanning

Clair downloads vulnerability databases on first start — this takes several minutes. Monitor:

```sh
docker logs quay-clair -f
```

### Database connection errors

```sh
docker exec quay-db pg_isready
```

### Permission denied errors

Check SELinux context on the `volumes/` directories. The compose file uses `:z` SELinux relabeling on all bind mounts.

---

## 🗑️ Uninstall

```sh
cd /opt/quay
docker compose down -v
rm -rf /opt/quay
systemctl disable --now quay-gc.timer quay-gc.service 2>/dev/null || true
rm -f /etc/systemd/system/quay-gc.{service,timer} /etc/cron.d/quay-gc
```

---

## 📋 Requirements

- Linux host with: `sh`, `awk`, `sed`, `grep`, `tr`, `dd`, `curl`
- Docker (with Compose plugin) or Podman + podman-compose
- Outbound internet access (image pulls, Clair vulnerability database updates)
- Valid domain name pointing to your host (for TLS via reverse proxy)
- `openssl` recommended for Cosign key generation (falls back to cosign container)

---

## 🛠️ Development

This repo ships a single installer script — there is no build system. To contribute:

```sh
git clone https://github.com/scriptmgr/quay
cd quay
# Edit install.sh, test with:
DOMAIN=test.example.com sh install.sh
```

Run shellcheck before submitting:

```sh
shellcheck -s sh install.sh
```

---

## 📄 License

MIT — see [LICENSE.md](LICENSE.md)
