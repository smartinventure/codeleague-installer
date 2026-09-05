# CodeLeague — standalone Docker installer

Run the **CodeLeague server** with just Docker — no Infinity Tools required.
`install-codeleague.sh` writes a minimal `docker-compose.yml`, pulls the image,
and starts CodeLeague in **Community mode**. You activate your license **inside
the app** afterwards.

## Requirements

- Docker Engine + Docker Compose v2 (`docker compose`)
- `openssl` (for generating secrets)

## Install / update

```bash
./install-codeleague.sh
```

Re-running it **updates** in place: it pulls the latest image and **reuses** the
secrets and machine id from the previous install (so nobody is signed out and
stored Git tokens stay readable).

Options (environment variables):

| Variable            | Default                              | Purpose                          |
|---------------------|--------------------------------------|----------------------------------|
| `CODELEAGUE_PORT`   | `3000`                               | Host port (HTTP)                 |
| `CODELEAGUE_DIR`    | `./codeleague`                       | Install / data directory         |
| `CODELEAGUE_IMAGE`  | `ghcr.io/…/codeleague:latest-release`| Override the image tag           |

```bash
CODELEAGUE_PORT=8080 CODELEAGUE_DIR=/opt/codeleague ./install-codeleague.sh
./install-codeleague.sh --status
./install-codeleague.sh --uninstall     # keeps your data unless you confirm deletion
```

## Updating (in-app, one click)

A container can't recreate itself, so the installer also sets up a small **host
updater** on install: `codeleague-update.sh` plus a watcher (a systemd path-unit
when run as root with systemd, otherwise a 1-minute cron poll). It writes a marker
(`<dir>/data/.host-update-enabled`) that the app detects.

When a new version is available, CodeLeague shows an update banner → **Update…**
modal. If the host updater is present you get an **Update now** button: the app
writes `<dir>/data/.update-request`, the host watcher runs `codeleague-update.sh`
(`docker compose pull && up -d`), and the container comes back on the new image
(~30–60 s downtime; data preserved). If no host updater is installed, the modal
shows the manual command instead:

```bash
./install-codeleague.sh --install       # pull the new image + recreate in place
```

## Activate your license (unlock premium)

The container starts in **Community mode**. To unlock premium features (AI
analysis, etc.):

1. Open CodeLeague at `http://<host>:<port>` → **Settings → License** (a first-run
   screen also prompts you).
2. Enter your **Server** license email + key (`COSE-…`).
3. **Restart the container** to finish unlocking premium:
   ```bash
   cd <install-dir> && docker compose restart
   ```
   The edition switches immediately; the premium modules load on that restart.

## HTTPS

The installer exposes plain **HTTP**. For TLS, put your own reverse proxy
(nginx / Caddy / Traefik) in front of `http://127.0.0.1:<port>`.

## Data, persistence & backups

Everything lives under your install directory on the **host**:

- `data/` — the database, license, and machine id (`data/codingfame.db`,
  `data/.machine_id`, …).
- `repos/` — a place to keep git clones. **Keep clones on a host-mounted path**
  (this `repos/`, or under `data/`) so they survive image updates — CodeLeague
  retains commits from deleted feature branches *in the local clone*, so losing
  the clone loses that history.
- `docker-compose.yml` — holds `JWT_SECRET` and `CF_ENC_KEY` (chmod `600`).
  **Keep it safe** and never change `CF_ENC_KEY` after first run, or stored Git
  tokens become undecryptable.

Back up the whole install directory to preserve your database, secrets, and clones.

## Uninstall

```bash
./install-codeleague.sh --uninstall
```

Stops and removes the container. Your `data/` is kept unless you confirm deletion.
