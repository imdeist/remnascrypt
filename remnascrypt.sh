#!/bin/bash
set -euo pipefail

SPORT=9000
NODE_PORT_DEFAULT=2272
WEBROOT_DIR="/var/www/remnascrypt"
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/remnascrypt.conf"
NGINX_DEFAULT_LINK="/etc/nginx/sites-enabled/default"

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

if [[ "$EUID" -ne 0 ]]; then
    echo "Ошибка: скрипт необходимо запускать от root."
    exit 1
fi

if ! grep -E -q "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    echo "Скрипт поддерживает только Debian или Ubuntu."
    exit 1
fi

if ! [[ "$SPORT" =~ ^[0-9]+$ ]] || (( SPORT < 1 || SPORT > 65535 )); then
    echo "Ошибка: некорректный SelfSNI порт."
    exit 1
fi

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

external_ip=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
if [[ -z "$external_ip" ]]; then
    echo "Не удалось определить внешний IP сервера."
    exit 1
fi

echo "Внешний IP сервера: $external_ip"

apt update
apt install -y curl nginx certbot git dnsutils ca-certificates gnupg lsb-release

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
cat > "$WEBROOT_DIR/index.html" <<'EOF'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>OK</title>
  <style>
    body{font-family:system-ui,sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:#f7f6f2;color:#28251d}
    .box{padding:24px 28px;border:1px solid #d4d1ca;border-radius:16px;background:#f9f8f5;box-shadow:0 4px 12px rgba(0,0,0,.06)}
  </style>
</head>
<body>
  <div class="box">remnascrypt webroot is ready</div>
</body>
</html>
EOF

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

cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root $WEBROOT_DIR;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root $WEBROOT_DIR;
        index index.html;
    }
}
EOF

nginx -t
systemctl restart nginx

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version >/dev/null 2>&1; then
    apt update
    apt install -y docker-compose-plugin
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "Ошибка: docker compose недоступен после установки."
    exit 1
fi

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
