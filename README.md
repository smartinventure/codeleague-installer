# Code League — Server installer

Public installer for the **Code League Server** edition (self-hosted, Docker).
A paid Code League Server license is required — get one at https://www.speedbits.io

## Install / update

```bash
curl -fsSL https://raw.githubusercontent.com/smartinventure/codeleague-installer/main/setup-codeleague-server.sh -o setup-codeleague-server.sh
sudo bash setup-codeleague-server.sh --install
```

Re-running `--install` updates an existing install in place (pulls the latest
release image and recreates the container).

## Other commands

```bash
sudo bash setup-codeleague-server.sh --status      # show status
sudo bash setup-codeleague-server.sh --uninstall   # remove container, keep data
sudo bash setup-codeleague-server.sh --deleteall   # remove container AND data
sudo bash setup-codeleague-server.sh --help
```

## Requirements

- Linux host with **Docker** + **Docker Compose v2** (`docker compose`)
- `curl` (and optionally `jq`)
- Your Code League Server license **email + key**

The installer validates your license, pulls the (partially encrypted) Docker
image, writes `docker-compose.yml`, and starts Code League. By default it serves
HTTP on port 3000 — set `CODELEAGUE_USE_TRAEFIK=true` + `CODELEAGUE_DOMAIN=...`
to attach it to a Traefik reverse proxy for HTTPS.

> This file is generated from the Code League source repo
> (`deploy/installer/setup-codeleague-server.sh`). Do not edit it here directly.
