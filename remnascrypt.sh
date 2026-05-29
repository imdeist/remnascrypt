#!/bin/bash
set -euo pipefail

# Порт, на котором nginx будет слушать локальный TLS для SelfSNI
SPORT=9000

# Порт RemnaNode по умолчанию
NODE_PORT_DEFAULT=2272

# Каталог, из которого nginx будет отдавать статические файлы
WEBROOT_DIR="/var/www/remnascrypt"

# Пути к конфигу nginx
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/remnascrypt.conf"
NGINX_DEFAULT_LINK="/etc/nginx/sites-enabled/default"

# Ссылка на кастомную заглушку index.html в GitHub
INDEX_HTML_URL="https://raw.githubusercontent.com/imdeist/remnascrypt/main/index.html"

# Разбор аргументов командной строки
while [[ $# -gt 0 ]]; do
    case "$1" in
        --selfsni-port)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                SPORT="$2"
                shift 2
            else
                echo "Ошибка: укажите корректный порт после аргумента --selfsni-port."
                exit 1
            fi
            ;;
        --without-80)
            echo "Ошибка: режим --without-80 в этом скрипте отключён."
            echo "Причина: выпуск сертификата реализован через webroot и требует обычного HTTP-01 доступа по 80/tcp."
            exit 1
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            echo "Использование: $0 [--selfsni-port <порт>]"
            exit 1
            ;;
    esac
done

# Скрипт должен запускаться от root
if [[ "$EUID" -ne 0 ]]; then
    echo "Ошибка: скрипт необходимо запускать от root."
    exit 1
fi

# Поддерживаются только Debian и Ubuntu
if ! grep -E -q "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    echo "Скрипт поддерживает только Debian или Ubuntu."
    exit 1
fi

# Проверяем корректность SelfSNI порта
if ! [[ "$SPORT" =~ ^[0-9]+$ ]] || (( SPORT < 1 || SPORT > 65535 )); then
    echo "Ошибка: некорректный SelfSNI порт."
    exit 1
fi

# Ввод параметров
read -r -p "Введите доменное имя: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "Доменное имя не может быть пустым."
    exit 1
fi

read -r -p "Введите порт для ноды RemnaNode [${NODE_PORT_DEFAULT}]: " NODE_PORT
NODE_PORT="${NODE_PORT:-$NODE_PORT_DEFAULT}"

if ! [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || (( NODE_PORT < 1 || NODE_PORT > 65535 )); then
    echo "Ошибка: указан некорректный порт ноды."
    exit 1
fi

if [[ "$NODE_PORT" == "$SPORT" ]]; then
    echo "Ошибка: порт ноды и SelfSNI порт не должны совпадать."
    exit 1
fi

read -r -s -p "Введите SECRET_KEY для RemnaNode: " SECRET_KEY
echo

if [[ -z "$SECRET_KEY" ]]; then
    echo "SECRET_KEY не может быть пустым."
    exit 1
fi

# Определение внешнего IP и установка пакетов
external_ip=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
if [[ -z "$external_ip" ]]; then
    echo "Не удалось определить внешний IP сервера."
    exit 1
fi

echo "Внешний IP сервера: $external_ip"

apt update
apt install -y curl nginx certbot git dnsutils ca-certificates gnupg lsb-release

# Проверка DNS
domain_ip=$(dig +short A "$DOMAIN" | tail -n1)
if [[ -z "$domain_ip" ]]; then
    echo "Не удалось получить A-запись для домена $DOMAIN."
    exit 1
fi

echo "A-запись домена $DOMAIN указывает на: $domain_ip"

if [[ "$domain_ip" != "$external_ip" ]]; then
    echo "A-запись домена $DOMAIN не соответствует внешнему IP сервера."
    exit 1
fi

echo "A-запись домена $DOMAIN соответствует внешнему IP сервера."

# Проверка занятости портов
if ss -tuln | grep -q ":${SPORT} "; then
    echo "Порт SelfSNI ${SPORT} уже занят. Укажите другой порт."
    exit 1
fi

if ss -tuln | grep -q ":${NODE_PORT} "; then
    echo "Порт ноды ${NODE_PORT} уже занят. Укажите другой порт."
    exit 1
fi

if ss -tuln | grep -q ":80 "; then
    echo "Порт 80 занят — это нормально, если его использует nginx."
else
    echo "Порт 80 свободен."
fi

if ss -tuln | grep -q ":443 "; then
    echo "Порт 443 занят. Освободите его перед запуском."
    exit 1
fi

mkdir -p "$WEBROOT_DIR"

if ! curl -fsSL "$INDEX_HTML_URL" -o "$WEBROOT_DIR/index.html"; then
    echo "Ошибка: не удалось скачать index.html из репозитория."
    exit 1
fi

rm -f "$NGINX_DEFAULT_LINK" 2>/dev/null || true

cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $WEBROOT_DIR;
    index index.html;

    location /.well-known/acme-challenge/ {
        allow all;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"

nginx -t
systemctl restart nginx

echo "Выпускаем сертификат через HTTP-01 webroot..."
certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive

#Добавление конечного NGINX конфига со всеми плюшками для vless reality
cat > "$NGINX_SITE" <<EOF
server {
    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Настройки Proxy Protocol
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    root $WEBROOT_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

nginx -t
systemctl restart nginx

# Установка Docker при отсутствии
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

# Установка Docker Compose plugin при отсутствии
if ! docker compose version >/dev/null 2>&1; then
    apt update
    apt install -y docker-compose-plugin
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "Ошибка: docker compose недоступен после установки."
    exit 1
fi

# Подготовка docker-compose для RemnaNode
mkdir -p /opt/remnanode

cat > /opt/remnanode/docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY=$SECRET_KEY
    volumes:
      - '/etc/letsencrypt:/etc/letsencrypt:ro'
EOF

cd /opt/remnanode
docker compose up -d

cat > /etc/sysctl.d/99-vpn-optim.conf << EOF
# VPN оптимизация - буферы 64MB
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

# TCP буферы (min default max)
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# BBR + сетевые улучшения
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 5000
EOF

# Применить
sysctl -p /etc/sysctl.d/99-vpn-optim.conf

# Финальная информация
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo
echo "========================================"
echo "Установка завершена."
echo "========================================"
echo "Домен: $DOMAIN"
echo "SelfSNI порт: $SPORT"
echo "Порт ноды: $NODE_PORT"
echo "Сертификат: $CERT_PATH"
echo "Ключ: $KEY_PATH"
echo "Dest: 127.0.0.1:$SPORT"
echo "SNI: $DOMAIN"
echo "Docker compose: /opt/remnanode/docker-compose.yml"
echo "Контейнер remnanode запущен."
echo "Проверка статуса: docker ps | grep remnanode"
echo "Логи: docker compose -f /opt/remnanode/docker-compose.yml logs -f remnanode"
echo "========================================"
