# 🚀 Quay Installer (Self-Hosted Container Registry)

This repository contains a **single POSIX-compliant installer script** (`install.sh`) that sets up a full-featured [Quay](https://quay.io/) container registry, complete with security scanning, signing, SBOM support, and automated garbage collection.  

Designed to be **distro-agnostic**, **idempotent**, and safe to re-run anytime.

---

## ✨ Features

- **Quay Stack (Docker Compose)**
  - Quay (registry + UI + API)
  - Postgres (database)
  - Redis (cache)
  - Clair v4 (vulnerability scanning)
  - Cosign (image signing)
  - Syft (SBOM generation)

- **Authentication & Access**
  - Open user registration
  - Anonymous pulls for public repos
  - Auth required for pushes
  - Full support for organizations, teams, and robot accounts

- **Supply Chain Security**
  - Cosign keypair auto-generated on first run
  - OCI signature storage built into Quay
  - SBOMs generated with Syft and attached as attestations

- **Email & User Management**
  - SMTP auto-detect via Docker host (`172.17.0.1:25`)
  - Email verification **enabled if SMTP is reachable**
  - Default sender: `no-reply@<DOMAIN>`

- **Security & Hardening**
  - Secrets stored in files (`*_FILE` pattern), `0600` perms
  - Never printed to logs; only shown in final summary
  - SELinux-safe mounts (`:z`)
  - Daily garbage collection at 03:00 (first run is dry-run)

- **Networking**
  - Quay bound to `172.17.0.1:<random 64xxx>` (persisted)
  - Reverse proxy terminates TLS (`https://<DOMAIN> → quay host`)
  - Isolated Docker network `quay` (`external: false`)

---

## 📦 Requirements

- Linux host with:
  - `sh`, `awk`, `sed`, `grep`, `tr`, `dd`, `curl`
  - Docker (preferred) or Podman
  - Docker Compose (plugin or `docker-compose`)
- Outbound internet access (for pulling images and Clair updates)
- **Valid registerable domain name** pointing to your host

---

## ⚡ Quick Start

Clone and run the installer:

```sh
git clone https://github.com/scriptmgr/quay
cd quay
sh install.sh
