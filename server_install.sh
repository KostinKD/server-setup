#!/usr/bin/env bash
#
# server-setup.sh — настройка чистого VPS: пользователь, SSH, фаервол,
# fail2ban, автообновления, swap, Docker.
#
# ЗАПУСКАТЬ ОТ ROOT, один раз, на СВЕЖЕМ сервере (Ubuntu 22.04/24.04, Debian 12).
#
#   ssh root@IP_СЕРВЕРА
#   nano server-setup.sh      # вставить содержимое, поправить переменные ниже
#   chmod +x server-setup.sh
#   ./server-setup.sh
#
# Перед запуском (руками, до скрипта):
#   На ЛОКАЛЬНОЙ машине сгенерируйте SSH-ключ, если его нет:
#     ssh-keygen -t ed25519 -C "vps-deploy"
#   и скопируйте публичный ключ (cat ~/.ssh/id_ed25519.pub) — он понадобится
#   в переменной DEPLOY_SSH_PUBKEY ниже.
#
# После скрипта сервер готов к развёртыванию любого проекта поверх Docker —
# сам скрипт приложение не разворачивает.
#
set -euo pipefail

### ─────────────────────── НАСТРОЙКИ ───────────────────────
# Можно править прямо в файле, а можно (удобно при curl-запуске без
# редактирования) передать через переменные окружения перед запуском, напр.:
#
#   DEPLOY_SSH_PUBKEY="ssh-ed25519 AAAA..." ./server-setup.sh
#
# Значения ниже — дефолты, которые используются, если переменная не задана
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

### ─────────────────────────────────────────────────────────────────────────

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

### 1. Первый вход и обновление ------------------------------------------------------
log "1. Обновление системы"
apt update && apt upgrade -y
apt install -y curl git ufw fail2ban

if [[ -n "$TIMEZONE" ]]; then
  timedatectl set-timezone "$TIMEZONE"
fi

### 2. Непривилегированный пользователь ----------------------------------------------
log "2. Создание пользователя $DEPLOY_USER"
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

### 3. SSH hardening -------------------------------------------------------------------
log "3. SSH hardening"
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

### 4. Фаервол (UFW) -------------------------------------------------------------------
log "4. Настройка UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

### 5. fail2ban ---------------------------------------------------------------------
log "5. fail2ban"
systemctl enable --now fail2ban
fail2ban-client status sshd || true

### 6. Автообновления безопасности ---------------------------------------------------
log "6. Автообновления безопасности"
apt install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

### 7. Swap ---------------------------------------------------------------------------
if [[ -n "$SWAP_SIZE" ]]; then
  log "7. Swap ($SWAP_SIZE)"
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

### 8. Docker ---------------------------------------------------------------------------
log "8. Установка Docker"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$DEPLOY_USER"

### Готово --------------------------------------------------------------------------
log "Готово"
cat <<EOF

Сервер настроен:
  [x] root по SSH отключён, пароли отключены, только ключи
  [x] пользователь '$DEPLOY_USER' с sudo и docker
  [x] UFW: открыты только $SSH_PORT (SSH), 80, 443
  [x] fail2ban активен
  [x] автообновления безопасности включены
  [x] swap: ${SWAP_SIZE:-не создавался}
  [x] Docker установлен

Проверка после перелогина под $DEPLOY_USER:
  ssh -p $SSH_PORT $DEPLOY_USER@IP_СЕРВЕРА
  docker run --rm hello-world
  docker compose version

Сервер готов принимать проект. Разворачивание конкретного приложения
(docker-compose, .env, git clone и т.д.) — отдельный шаг, выполняется вручную.
EOF
