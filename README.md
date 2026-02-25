# ascrapper-installer

Installer repository for deploying a private Python Telegram bot project (ascrapper) on **Ubuntu 22.04 headless servers** with `systemd` service management.

> This repo provides:
>
> - `bootstrap.sh` → one-command bootstrap installer
> - `deploy.sh` → full deploy/update/service management flow
> - this README → complete installation and operations guide

## Files

```text
/ascrapper-installer
├── bootstrap.sh
├── deploy.sh
└── README.md
```

## 1) One-liner install on Ubuntu 22.04

Run this on your target server:

```bash
curl -fsSL https://raw.githubusercontent.com/WiZARDWZ/ascrapper-installer/main/bootstrap.sh | bash
```

`bootstrap.sh` will:

1. Install prerequisites (`git`, `curl`, `python3.11`, build tools, etc.).
2. Ask for your target **private GitHub repo URL**.
3. Ask you to choose auth method:
   - SSH Deploy Key (recommended)
   - GitHub Personal Access Token (PAT)
4. Ask for `TELEGRAM_BOT_TOKEN` (and optional proxy).
5. Run `deploy.sh` for install/update/restart.

---

## 2) GitHub private repo access methods

### Option A: SSH Deploy Key (recommended)

- Script can generate an SSH key on the server.
- Copy printed public key.
- Add to GitHub:
  - `Repo → Settings → Deploy keys → Add deploy key`
- Then script validates access with `git ls-remote`.

### Option B: GitHub PAT

- Create a token from GitHub:
  - `Settings → Developer settings → Personal access tokens`
- Minimum scope for private repo read: repository read access.
- Script stores PAT at:

```bash
~/.config/ascrapper/github_token
```

with `chmod 600`.

---

## 3) Telegram token and proxy setup

The installer writes/updates:

```bash
~/apps/ascrapper/.env
```

Important keys:

```env
TELEGRAM_BOT_TOKEN=...
TELEGRAM_PROXY_URL=
TELEGRAM_CONNECT_TIMEOUT=30
TELEGRAM_READ_TIMEOUT=30
HEADLESS=1
DB_PATH=realestate.db
OUTPUT_DIR=output
PYTHONUNBUFFERED=1
```

### Get Telegram bot token

- Open Telegram and message **@BotFather**.
- Create a bot using `/newbot`.
- Copy token and provide it to installer.

Reference: https://core.telegram.org/bots#how-do-i-create-a-bot

### If proxy/firewall is required

Set `TELEGRAM_PROXY_URL`, for example:

```env
TELEGRAM_PROXY_URL=http://127.0.0.1:10809
```

Then restart service:

```bash
sudo systemctl restart ascrapper
```

---

## 4) deploy.sh usage

You can run deploy directly any time:

```bash
bash deploy.sh
```

It supports:

- Initial install/setup
- Update flow (`git pull`, dependency install, service restart)
- Restart service
- Stop service
- Show status and logs
- Reconfigure token/proxy via `.env` wizard

You can also automate action from bootstrap/environment:

```bash
DEPLOY_ACTION=update bash deploy.sh
```

Actions:

- `install`
- `update`
- `restart`

---

## 5) systemd service management

Service name defaults to `ascrapper`.

```bash
sudo systemctl status ascrapper
sudo systemctl restart ascrapper
sudo systemctl stop ascrapper
sudo systemctl enable ascrapper
journalctl -u ascrapper -f
```

Service file location:

```bash
/etc/systemd/system/ascrapper.service
```

---

## 6) Update after code changes

For future updates, just rerun:

```bash
bash deploy.sh
```

Choose update option from menu, or run non-interactive:

```bash
DEPLOY_ACTION=update bash deploy.sh
```

This will:

1. Pull latest code from your branch (`main` by default)
2. Reinstall/update dependencies from `requirements.txt`
3. Restart the systemd service

---

## 7) Windows note

This installer is optimized for **Ubuntu 22.04 servers**.

For Windows deployments, run your bot with:

- Python 3.11
- virtualenv
- `.env` file values matching Linux setup

`systemd` parts are Linux-only; on Windows, use Task Scheduler/NSSM/PM2 equivalent if persistent background execution is needed.
