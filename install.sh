#!/usr/bin/env bash
#
# server-setup.sh — настройка чистого VPS до состояния "готов к DEPLOY.md"
#
# ЗАПУСКАТЬ ОТ ROOT, один раз, на СВЕЖЕМ сервере (Ubuntu 22.04/24.04, Debian 12).
#
#   ssh root@IP_СЕРВЕРА
#   nano server-setup.sh      # вставить содержимое, поправить переменные ниже
#   chmod +x server-setup.sh
#   ./server-setup.sh
#
# Перед запуском обязательно сделайте (руками, до скрипта):
#   1. DNS A-записи на IP сервера (@, api, studio, analytics) — см. п.1 гайда.
#      Для Cloudflare — Proxy status: DNS only (серое облако).
#   2. На ЛОКАЛЬНОЙ машине сгенерируйте SSH-ключ, если его нет:
#        ssh-keygen -t ed25519 -C "art-studio-vps"
#      и скопируйте публичный ключ (cat ~/.ssh/id_ed25519.pub) — он понадобится
#      в переменной DEPLOY_SSH_PUBKEY ниже.
#
# После скрипта: перелогиньтесь под deploy и переходите к DEPLOY.md.
#
set -euo pipefail

### ─────────────────────── НАСТРОЙКИ ───────────────────────
# Можно править прямо в файле, а можно (удобно при curl-запуске без
# редактирования) передать через переменные окружения перед запуском, напр.:
#
#   DEPLOY_SSH_PUBKEY="ssh-ed25519 AAAA..." GIT_REPO_URL="https://github.com/you/repo.git" \
#     ./server-setup.sh
#
# Значения ниже — это дефолты, которые используются, если переменная не задана
# в окружении (синтаксис ${VAR:-default}).

DEPLOY_USER="${DEPLOY_USER:-deploy}"

# Публичный SSH-ключ пользователя deploy. ОБЯЗАТЕЛЬНО заполните — иначе после
# hardening (PasswordAuthentication no) вы не сможете зайти под deploy.
# Пример: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@host"
DEPLOY_SSH_PUBKEY="${DEPLOY_SSH_PUBKEY:-}"

# Порт SSH. Оставьте 22, если не хотите менять.
SSH_PORT="${SSH_PORT:-22}"

# Часовой пояс (опционально). Пусто — не менять.
TIMEZONE="${TIMEZONE:-Europe/Moscow}"

# Размер swap-файла. Пусто — пропустить создание swap.
SWAP_SIZE="${SWAP_SIZE:-4G}"

# Git-репозиторий проекта. Пусто — пропустить клонирование (сделаете вручную).
# Публичный: "https://github.com/<вы>/ai-studio-art.git"
# Приватный (deploy key) — оставьте пусто и клонируйте руками по варианту Б гайда.
GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_CLONE_DIR="${GIT_CLONE_DIR:-ai-studio-art}"

### ─────────────────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  echo "Запускайте скрипт от root (ssh root@IP_СЕРВЕРА)." >&2
  exit 1
fi

if [[ -z "$DEPLOY_SSH_PUBKEY" ]]; then
  echo "ОШИБКА: заполните DEPLOY_SSH_PUBKEY в начале скрипта — это публичный ключ" >&2
  echo "для пользователя deploy. Без него после SSH hardening вы потеряете доступ." >&2
  exit 1
fi

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

### 2. Первый вход и обновление ------------------------------------------------------
log "2. Обновление системы"
apt update && apt upgrade -y
apt install -y curl git ufw fail2ban

if [[ -n "$TIMEZONE" ]]; then
  timedatectl set-timezone "$TIMEZONE"
fi

### 3. Непривилегированный пользователь ----------------------------------------------
log "3. Создание пользователя $DEPLOY_USER"
if ! id "$DEPLOY_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG sudo "$DEPLOY_USER"

mkdir -p "/home/$DEPLOY_USER/.ssh"
# Не затираем существующие ключи, добавляем свой, если его там ещё нет.
touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
if ! grep -qF "$DEPLOY_SSH_PUBKEY" "/home/$DEPLOY_USER/.ssh/authorized_keys"; then
  echo "$DEPLOY_SSH_PUBKEY" >> "/home/$DEPLOY_USER/.ssh/authorized_keys"
fi
chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
chmod 700 "/home/$DEPLOY_USER/.ssh"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"

echo "Проверьте В ДРУГОМ терминале, не закрывая этот:"
echo "  ssh -p $SSH_PORT $DEPLOY_USER@$(curl -s ifconfig.me 2>/dev/null || echo IP_СЕРВЕРА)"
read -rp "Вход под $DEPLOY_USER по ключу работает? Продолжить hardening SSH? [y/N] " ans
if [[ "${ans,,}" != "y" ]]; then
  echo "Остановлено. Почините доступ под $DEPLOY_USER и перезапустите скрипт." >&2
  exit 1
fi

### 4. SSH hardening -------------------------------------------------------------------
log "4. SSH hardening"
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

set_sshd_option() {
  local key="$1" value="$2"
  if grep -qE "^\s*#?\s*${key}\s+" "$SSHD_CONFIG"; then
    sed -i -E "s|^\s*#?\s*${key}\s+.*|${key} ${value}|" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
}

set_sshd_option "PermitRootLogin" "no"
set_sshd_option "PasswordAuthentication" "no"
set_sshd_option "PubkeyAuthentication" "yes"
set_sshd_option "ChallengeResponseAuthentication" "no"
set_sshd_option "Port" "$SSH_PORT"

systemctl restart ssh

### 5. Фаервол (UFW) -------------------------------------------------------------------
log "5. Настройка UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

### 6. fail2ban ---------------------------------------------------------------------
log "6. fail2ban"
systemctl enable --now fail2ban
fail2ban-client status sshd || true

### 7. Автообновления безопасности ---------------------------------------------------
log "7. Автообновления безопасности"
apt install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

### 8. Swap ---------------------------------------------------------------------------
if [[ -n "$SWAP_SIZE" ]]; then
  log "8. Swap ($SWAP_SIZE)"
  if [[ -f /swapfile ]]; then
    echo "Файл /swapfile уже существует, пропускаю."
  else
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  free -h
fi

### 9. Docker ---------------------------------------------------------------------------
log "9. Установка Docker"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$DEPLOY_USER"

### 10. Получение кода ------------------------------------------------------------------
if [[ -n "$GIT_REPO_URL" ]]; then
  log "10. Клонирование репозитория"
  su - "$DEPLOY_USER" -c "cd ~ && [ -d '$GIT_CLONE_DIR' ] || git clone '$GIT_REPO_URL' '$GIT_CLONE_DIR'"
else
  log "10. Клонирование репозитория пропущено (GIT_REPO_URL не задан)"
  echo "Склонируйте проект вручную под пользователем $DEPLOY_USER — см. варианты А/Б/В в гайде:"
  echo "  su - $DEPLOY_USER"
  echo "  git clone <url> ~/ai-studio-art"
fi

### Готово --------------------------------------------------------------------------
log "Готово"
cat <<EOF

Сервер настроен:
  - root по SSH отключён, пароли отключены, только ключи
  - пользователь '$DEPLOY_USER' с sudo и docker
  - UFW: открыты только $SSH_PORT (SSH), 80, 443
  - fail2ban активен
  - автообновления безопасности включены
  - Docker установлен

Дальше:
  1. Перелогиньтесь под $DEPLOY_USER, чтобы применилась группа docker:
       ssh -p $SSH_PORT $DEPLOY_USER@IP_СЕРВЕРА
       docker run --rm hello-world
       docker compose version
  2. Переходите к DEPLOY.md — сначала поднимаете Supabase, потом
     docker-compose.prod.yml для приложения.

Не забудьте отметить чеклист безопасности (п.14 гайда) и синхронизировать
общие ключи (.env) между Supabase и приложением.
EOF
