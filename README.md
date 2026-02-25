# ascrapper-installer

Installer repository for deploying a private Python Telegram bot project (`ascrapper`) on **Ubuntu 22.04 headless servers** with `systemd`.

This repo provides:

- `bootstrap.sh` — bootstrap entrypoint
- `deploy.sh` — install/update/service menu
- `README.md` — usage and operational guide

## Files

```text
/ascrapper-installer
├── bootstrap.sh
├── deploy.sh
└── README.md
```

## Install methods (Ubuntu 22.04)

### Recommended

```bash
curl -fsSLo /tmp/bootstrap.sh https://raw.githubusercontent.com/WiZARDWZ/ascrapper-installer/main/bootstrap.sh && bash /tmp/bootstrap.sh
```

### Alternative

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/WiZARDWZ/ascrapper-installer/main/bootstrap.sh)"
```

`bootstrap.sh` handles TTY safely:

- Reads prompts from `/dev/tty` when available.
- In non-interactive mode, accepts env vars:
  `REPO_URL`, `BRANCH`, `APP_NAME`, `AUTH_MODE`/`AUTH_CHOICE`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_PROXY_URL`, `DEPLOY_ACTION`.
- If required values are missing and no TTY exists, exits with a clear hint.

## Command shortcut

Bootstrap installs a wrapper command:

```bash
ascrapper
```

This runs the cached installer menu:

```bash
bash "${XDG_CACHE_HOME:-$HOME/.cache}/ascrapper-installer/deploy.sh"
```

## Paths used by installer

- Installer cache:
  - `${XDG_CACHE_HOME:-$HOME/.cache}/ascrapper-installer/deploy.sh`
  - `${XDG_CACHE_HOME:-$HOME/.cache}/ascrapper-installer/bootstrap.sh`
- Installer persistent config:
  - `~/.config/ascrapper/installer.conf`
- PAT storage:
  - `~/.config/ascrapper/github_token`
- App directory:
  - `~/apps/ascrapper`
- App env file:
  - `~/apps/ascrapper/.env`
- systemd unit:
  - `/etc/systemd/system/ascrapper.service`

## Persistent installer config behavior

After a successful clone/update, `deploy.sh` saves and reuses config values:

- `REPO_URL`
- `AUTH_MODE`
- `BRANCH`
- `APP_NAME`
- `INSTALL_CHROME`

Result: update runs do **not** ask for repo URL/auth again unless:

- config is missing,
- git access fails,
- or you choose **Reset saved installer config (repo/auth)** in the menu.

## GitHub private repo access

### Option A: SSH Deploy Key (recommended)

- Script can generate a key.
- Add printed public key in:
  `Repo -> Settings -> Deploy keys -> Add deploy key`
- Script validates access using `git ls-remote`.

### Option B: GitHub PAT

- Create a PAT from:
  `GitHub -> Settings -> Developer settings -> Personal access tokens`
- Script stores token with `chmod 600`.

## Telegram token and proxy

The installer writes `.env` here:

```bash
~/apps/ascrapper/.env
```

You can edit `.env` manually any time:

```bash
nano ~/apps/ascrapper/.env
```

Key values:

```env
TELEGRAM_BOT_TOKEN=...
TELEGRAM_PROXY_URL=
PERF_PROFILE=normal
TELEGRAM_CONNECT_TIMEOUT=30
TELEGRAM_READ_TIMEOUT=30
HEADLESS=0
LIGHT_CHECK_INTERVAL_SECONDS=180
LIGHT_CHECK_PAGES=2
WORKER_TICK_SECONDS=10
DB_PATH=realestate.db
OUTPUT_DIR=output
PYTHONUNBUFFERED=1
```

If token is already present, wizard does not ask again.
If token is empty, wizard prompts and deploy fails clearly if it remains empty.

### Performance profile in wizard

During install, the wizard asks for a performance profile:

- **Normal** (recommended for stronger servers)
  - `PERF_PROFILE=normal`
  - default `HEADLESS=0` (Xvfb service mode)
  - optional advanced headless override to `HEADLESS=1`
  - `LIGHT_CHECK_INTERVAL_SECONDS=180`
  - `LIGHT_CHECK_PAGES=2`
  - `WORKER_TICK_SECONDS=10`

- **Low-end** (recommended for 1 CPU / 1 GB RAM)
  - `PERF_PROFILE=low`
  - `HEADLESS=0`
  - `LIGHT_CHECK_INTERVAL_SECONDS=600`
  - `LIGHT_CHECK_PAGES=1`
  - `WORKER_TICK_SECONDS=20`

To change later, edit `.env` and restart:

```bash
nano ~/apps/ascrapper/.env
sudo systemctl restart ascrapper
```

## deploy.sh menu actions

Run menu:

```bash
ascrapper
```

Menu options:

1. Initial install / setup
2. Update code from GitHub + deps + restart service
3. Restart service
4. Stop service
5. Show status and logs
6. Reconfigure token/proxy (`.env` wizard)
7. **Update installer only** (updates cached scripts; does not touch bot repo/service)
8. Reset saved installer config (repo/auth)
0. Exit

Update action keeps your existing `.env` values (including profile) and only runs:

- `git pull`/repo sync
- dependency install from `requirements.txt`
- service restart

## Update installer only (no bot/service impact)

Option 7 updates installer scripts in cache only:

- updates `deploy.sh`
- updates `bootstrap.sh`
- does **not** run `git pull` on bot repo
- does **not** restart/stop systemd bot service

After update, rerun `ascrapper`.

## Service operations

```bash
sudo systemctl status ascrapper
sudo systemctl restart ascrapper
sudo systemctl stop ascrapper
sudo systemctl enable ascrapper
journalctl -u ascrapper -f
```

`deploy.sh` writes `ExecStart` with `xvfb-run` based on `PERF_PROFILE`:

- `low` -> `-screen 0 1365x768x24`
- `normal` -> `-screen 0 1920x1080x24`

## Windows note

This installer is optimized for Ubuntu 22.04 servers.
For Windows, use Python 3.11 + virtualenv + equivalent service manager (Task Scheduler/NSSM/etc.).
