#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-ascrapper}"
SERVICE_NAME="${SERVICE_NAME:-$APP_NAME}"
BRANCH="${BRANCH:-main}"
PY_BIN="${PY_BIN:-python3.11}"
INSTALL_CHROME="${INSTALL_CHROME:-1}"
REPO_URL="${REPO_URL:-}"
AUTH_MODE="${AUTH_MODE:-}"
DEPLOY_ACTION="${DEPLOY_ACTION:-}"

RUN_USER="${SUDO_USER:-${USER}}"
RUN_GROUP="$(id -gn "$RUN_USER")"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
APP_DIR="${APP_DIR:-$RUN_HOME/apps/$APP_NAME}"

TOKEN_FILE="$RUN_HOME/.config/$APP_NAME/github_token"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="$APP_DIR/.env"

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

run_as_user() {
  if [[ "$(id -u)" -eq 0 ]]; then
    sudo -u "$RUN_USER" -H bash -lc "$*"
  else
    bash -lc "$*"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing command: $1"; exit 1; }
}

normalize_repo_url_ssh() {
  local input="$1"
  if [[ "$input" =~ ^git@github.com:.+/.+\.git$ ]]; then
    echo "$input"
    return
  fi
  if [[ "$input" =~ ^https://github.com/([^/]+)/([^/]+?)(\.git)?$ ]]; then
    echo "git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
    return
  fi
  echo ""
}

extract_owner_repo() {
  local input="$1"
  if [[ "$input" =~ ^git@github.com:([^/]+)/([^/]+)\.git$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return
  fi
  if [[ "$input" =~ ^https://github.com/([^/]+)/([^/]+?)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return
  fi
  echo ""
}

build_pat_url() {
  local base_url="$1"
  local token="$2"
  local owner_repo
  owner_repo="$(extract_owner_repo "$base_url")"
  if [[ -z "$owner_repo" ]]; then
    echo ""
    return
  fi
  echo "https://${token}@github.com/${owner_repo}.git"
}

ensure_prerequisites() {
  echo "[Prerequisites] Installing required packages..."
  $SUDO apt-get update
  $SUDO apt-get install -y software-properties-common
  $SUDO add-apt-repository -y ppa:deadsnakes/ppa || true
  $SUDO apt-get update
  $SUDO apt-get install -y \
    git curl ca-certificates unzip build-essential pkg-config \
    "$PY_BIN" "${PY_BIN}-venv" "${PY_BIN}-distutils" \
    libnss3 libatk-bridge2.0-0 libgtk-3-0 libgbm1 libx11-xcb1 \
    libxcomposite1 libxdamage1 libxrandr2 libasound2 fonts-liberation

  if [[ "$INSTALL_CHROME" == "1" ]]; then
    echo "[Prerequisites] Installing Google Chrome stable..."
    local tmp_deb="/tmp/google-chrome-stable_current_amd64.deb"
    curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o "$tmp_deb"
    $SUDO dpkg -i "$tmp_deb" || $SUDO apt-get -f install -y
    rm -f "$tmp_deb"
  fi
}

prompt_repo_url() {
  while true; do
    if [[ -z "$REPO_URL" ]]; then
      read -r -p "GitHub repo URL را وارد کنید (SSH/HTTPS): " REPO_URL
    fi

    local owner_repo
    owner_repo="$(extract_owner_repo "$REPO_URL")"
    if [[ -n "$owner_repo" ]]; then
      break
    fi

    echo "[WARN] فرمت REPO_URL معتبر نیست. مثال: git@github.com:OWNER/REPO.git"
    REPO_URL=""
  done
}

setup_ssh_access() {
  local ssh_key="$RUN_HOME/.ssh/id_ed25519"
  run_as_user "mkdir -p '$RUN_HOME/.ssh' && chmod 700 '$RUN_HOME/.ssh'"

  if ! run_as_user "test -f '$ssh_key'"; then
    echo "کلید SSH پیدا نشد. در حال ساخت کلید جدید..."
    run_as_user "ssh-keygen -t ed25519 -C 'deploy@server' -f '$ssh_key' -N ''"
  fi

  echo
  echo "کلید عمومی شما:"
  run_as_user "cat '${ssh_key}.pub'"
  echo
  echo "این کلید را در GitHub Repo → Settings → Deploy Keys اضافه کنید (Read-only کافی است)."
  read -r -p "بعد از اضافه‌کردن کلید، Enter بزنید تا تست اتصال انجام شود..." _

  run_as_user "ssh -o StrictHostKeyChecking=accept-new -T git@github.com || true"

  local normalized
  normalized="$(normalize_repo_url_ssh "$REPO_URL")"
  if [[ -z "$normalized" ]]; then
    echo "REPO_URL باید قابل تبدیل به SSH باشد."
    REPO_URL=""
    prompt_repo_url
    normalized="$(normalize_repo_url_ssh "$REPO_URL")"
  fi
  REPO_URL="$normalized"
}

setup_pat_access() {
  local token="${GITHUB_PAT:-}"
  run_as_user "mkdir -p '$RUN_HOME/.config/$APP_NAME'"
  if [[ -z "$token" ]]; then
    read -r -s -p "GitHub PAT را وارد کنید: " token
    echo
  fi

  if [[ -z "$token" ]]; then
    echo "[WARN] توکن خالی است."
    return 1
  fi

  run_as_user "cat > '$TOKEN_FILE' <<'TOK'
$token
TOK"
  run_as_user "chmod 600 '$TOKEN_FILE'"
  echo "توکن در $TOKEN_FILE ذخیره شد (chmod 600)."
  return 0
}

check_repo_access() {
  local mode="$1"
  local test_url="$REPO_URL"

  if [[ "$mode" == "pat" ]]; then
    if ! run_as_user "test -f '$TOKEN_FILE'"; then
      return 1
    fi
    local token
    token="$(run_as_user "cat '$TOKEN_FILE'")"
    test_url="$(build_pat_url "$REPO_URL" "$token")"
    [[ -n "$test_url" ]] || return 1
  fi

  run_as_user "git ls-remote '$test_url' -h 'refs/heads/$BRANCH' >/dev/null 2>&1"
}

select_auth_and_validate() {
  prompt_repo_url

  if [[ "$AUTH_MODE" == "ssh" ]]; then
    setup_ssh_access
    check_repo_access "ssh"
    return
  fi

  if [[ "$AUTH_MODE" == "pat" ]]; then
    setup_pat_access
    check_repo_access "pat"
    return
  fi

  while true; do
    echo
    echo "روش دسترسی به ریپوی private کدام است؟"
    echo "1) SSH Deploy Key (پیشنهادی)"
    echo "2) GitHub Personal Access Token (PAT)"
    echo "0) خروج"
    read -r -p "انتخاب شما: " auth_choice

    case "$auth_choice" in
      1)
        setup_ssh_access
        if check_repo_access "ssh"; then
          AUTH_MODE="ssh"
          return 0
        fi
        echo "[WARN] دسترسی SSH ناموفق بود. لطفاً مجدد تلاش کنید."
        ;;
      2)
        if setup_pat_access && check_repo_access "pat"; then
          AUTH_MODE="pat"
          return 0
        fi
        echo "[WARN] دسترسی PAT ناموفق بود. لطفاً توکن/URL را بررسی کنید."
        ;;
      0)
        echo "خروج."
        exit 0
        ;;
      *)
        echo "گزینه نامعتبر."
        ;;
    esac
  done
}

clone_or_update_repo() {
  local work_url="$REPO_URL"
  if [[ "$AUTH_MODE" == "pat" ]]; then
    local token
    token="$(run_as_user "cat '$TOKEN_FILE'")"
    work_url="$(build_pat_url "$REPO_URL" "$token")"
  fi

  run_as_user "mkdir -p '$(dirname "$APP_DIR")'"
  if [[ ! -d "$APP_DIR/.git" ]]; then
    echo "[Repo] Cloning..."
    if ! run_as_user "git clone --branch '$BRANCH' '$work_url' '$APP_DIR'"; then
      echo "[WARN] clone ناموفق بود؛ تنظیم دسترسی دوباره اجرا می‌شود."
      AUTH_MODE=""
      select_auth_and_validate
      clone_or_update_repo
      return
    fi
  else
    echo "[Repo] Updating..."
    if ! run_as_user "git -C '$APP_DIR' remote set-url origin '$work_url' && git -C '$APP_DIR' fetch origin '$BRANCH' && git -C '$APP_DIR' checkout '$BRANCH' && git -C '$APP_DIR' pull --ff-only origin '$BRANCH'"; then
      echo "[WARN] pull ناموفق بود؛ تنظیم دسترسی دوباره اجرا می‌شود."
      AUTH_MODE=""
      select_auth_and_validate
      clone_or_update_repo
      return
    fi
  fi

  run_as_user "git -C '$APP_DIR' remote set-url origin '$REPO_URL'"
}

setup_venv_deps() {
  run_as_user "cd '$APP_DIR' && '$PY_BIN' -m venv .venv"
  run_as_user "cd '$APP_DIR' && .venv/bin/python -m pip install --upgrade pip setuptools wheel"
  run_as_user "cd '$APP_DIR' && .venv/bin/python -m pip install -r requirements.txt"
}

upsert_env() {
  local key="$1"
  local value="$2"
  run_as_user "touch '$ENV_FILE'"
  if run_as_user "grep -q '^${key}=' '$ENV_FILE'"; then
    run_as_user "sed -i 's|^${key}=.*|${key}=${value}|' '$ENV_FILE'"
  else
    run_as_user "printf '%s=%s\n' '$key' '$value' >> '$ENV_FILE'"
  fi
}

env_get() {
  local key="$1"
  local line=""
  local value=""

  if ! run_as_user "test -f '$ENV_FILE'"; then
    echo ""
    return 0
  fi

  line="$(run_as_user "grep -m1 -E '^${key}=' '$ENV_FILE' || true")"
  if [[ -z "$line" ]]; then
    echo ""
    return 0
  fi

  value="${line#*=}"

  # trim leading/trailing whitespace
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  # strip matching surrounding quotes
  if [[ "$value" =~ ^\".*\"$ ]]; then
    value="${value#\"}"
    value="${value%\"}"
  elif [[ "$value" =~ ^\'.*\'$ ]]; then
    value="${value#\'}"
    value="${value%\'}"
  fi

  echo "$value"
}

env_wizard() {
  run_as_user "mkdir -p '$APP_DIR' && touch '$ENV_FILE'"

  local token existing_token
  existing_token="$(env_get 'TELEGRAM_BOT_TOKEN' || true)"
  token="${TELEGRAM_BOT_TOKEN:-}"

  if [[ -z "$token" && -n "$existing_token" ]]; then
    token="$existing_token"
  fi

  if [[ -z "$token" ]]; then
    read -r -p "توکن تلگرام را وارد کنید: " token
    while [[ -z "$token" ]]; do
      echo "توکن نمی‌تواند خالی باشد."
      read -r -p "توکن تلگرام را وارد کنید: " token
    done
  fi
  upsert_env "TELEGRAM_BOT_TOKEN" "$token"

  local proxy_choice proxy_val
  proxy_val="${TELEGRAM_PROXY_URL:-$(env_get 'TELEGRAM_PROXY_URL' || true)}"

  if [[ -n "${TELEGRAM_PROXY_URL:-}" ]]; then
    upsert_env "TELEGRAM_PROXY_URL" "$TELEGRAM_PROXY_URL"
  else
    read -r -p "آیا پروکسی لازم دارید؟ (y/n): " proxy_choice
    if [[ "$proxy_choice" =~ ^[Yy]$ ]]; then
      read -r -p "آدرس پروکسی (مثال: http://127.0.0.1:10809): " proxy_val
      upsert_env "TELEGRAM_PROXY_URL" "$proxy_val"
    elif [[ -z "$proxy_val" ]]; then
      upsert_env "TELEGRAM_PROXY_URL" ""
    fi
  fi

  upsert_env "TELEGRAM_CONNECT_TIMEOUT" "30"
  upsert_env "TELEGRAM_READ_TIMEOUT" "30"
  upsert_env "HEADLESS" "1"
  upsert_env "DB_PATH" "realestate.db"
  upsert_env "OUTPUT_DIR" "output"
  upsert_env "PYTHONUNBUFFERED" "1"
}

ensure_token_present() {
  local token
  token="$(env_get 'TELEGRAM_BOT_TOKEN' || true)"
  if [[ -z "$token" ]]; then
    echo "[WARN] TELEGRAM_BOT_TOKEN خالی است."
    env_wizard
    token="$(env_get 'TELEGRAM_BOT_TOKEN' || true)"
    if [[ -z "$token" ]]; then
      echo "[ERROR] بدون TELEGRAM_BOT_TOKEN سرویس اجرا نمی‌شود."
      exit 1
    fi
  fi
}

write_service() {
  $SUDO tee "$SERVICE_FILE" >/dev/null <<SERVICEEOF
[Unit]
Description=${APP_NAME} bot service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/.venv/bin/python telegram_bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$SERVICE_NAME"
}

restart_service() {
  ensure_token_present
  $SUDO systemctl restart "$SERVICE_NAME"
  echo "سرویس ${SERVICE_NAME} ری‌استارت شد."
}

stop_service() {
  $SUDO systemctl stop "$SERVICE_NAME" || true
  echo "سرویس ${SERVICE_NAME} متوقف شد."
}

show_status_logs() {
  $SUDO systemctl status "$SERVICE_NAME" --no-pager || true
  $SUDO journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
}

install_setup_flow() {
  require_cmd awk
  ensure_prerequisites
  select_auth_and_validate
  clone_or_update_repo
  setup_venv_deps
  env_wizard
  write_service
  restart_service
  echo
  echo "Deploy complete"
  echo "Env file: $ENV_FILE"
  echo "Logs: journalctl -u $SERVICE_NAME -f"
  echo "Restart: sudo systemctl restart $SERVICE_NAME"
}

update_flow() {
  select_auth_and_validate
  clone_or_update_repo
  setup_venv_deps
  restart_service
  show_status_logs
}

restart_only_flow() {
  restart_service
  show_status_logs
}

menu_loop() {
  while true; do
    echo
    echo "===== $APP_NAME deploy menu ====="
    echo "1) نصب اولیه / راه‌اندازی"
    echo "2) بروزرسانی کد از GitHub + deps + restart سرویس"
    echo "3) ریستارت سرویس"
    echo "4) توقف سرویس"
    echo "5) مشاهده وضعیت و لاگ‌ها"
    echo "6) تنظیم مجدد توکن‌ها / پروکسی (.env wizard)"
    echo "0) خروج"
    read -r -p "انتخاب شما: " choice

    case "$choice" in
      1) install_setup_flow ;;
      2) update_flow ;;
      3) restart_only_flow ;;
      4) stop_service ;;
      5) show_status_logs ;;
      6) env_wizard ;;
      0) exit 0 ;;
      *) echo "گزینه نامعتبر." ;;
    esac
  done
}

main() {
  case "$DEPLOY_ACTION" in
    install)
      install_setup_flow
      return
      ;;
    update)
      update_flow
      return
      ;;
    restart)
      restart_only_flow
      return
      ;;
  esac

  if [[ -d "$APP_DIR" && -f "$SERVICE_FILE" ]]; then
    menu_loop
  else
    install_setup_flow
  fi
}

main "$@"
