#!/bin/bash
set -euo pipefail

SPORT=9000
WITHOUT_80=0
NODE_PORT_DEFAULT=2272

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
            WITHOUT_80=1
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            echo "Использование: $0 [--selfsni-port <порт>] [--without-80]"
            exit 1
            ;;
    esac
done

if [[ "$EUID" -ne 0 ]]; then
    echo "Ошибка: скрипт необходимо запускать от root."
    echo "Пример:"
    echo "sudo bash $0"
    exit 1
fi

if ! grep -E -q "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    echo "Скрипт поддерживает только Debian или Ubuntu. Завершаю работу."
    exit 1
fi

if ! [[ "$SPORT" =~ ^[0-9]+$ ]] || (( SPORT < 1 || SPORT > 65535 )); then
    echo "Ошибка: некорректный SelfSNI порт."
    exit 1
fi

if [[ $WITHOUT_80 -eq 1 ]]; then
    echo "Ошибка: режим --without-80 в этом скрипте отключён."
    echo "Причина: стандартный certbot не поддерживает challenge tls-alpn-01."
    echo "Используйте обычный режим с открытым портом 80 или реализуйте DNS-01 отдельно."
    exit 1
fi

read -r -p "Введите доменное имя: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "Доменное имя не может быть пустым. Завершаю работу."
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
    echo "SECRET_KEY не может быть пустым. Завершаю работу."
    exit 1
fi

external_ip=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
if [[ -z "$external_ip" ]]; then
    echo "Не удалось определить внешний IP сервера. Проверьте подключение к интернету."
    exit 1
fi

echo "Внешний IP сервера: $external_ip"

apt update
apt install -y curl nginx certbot python3-certbot-nginx git dnsutils ca-certificates gnupg lsb-release

domain_ip=$(dig +short A "$DOMAIN" | tail -n1)

if [[ -z "$domain_ip" ]]; then
    echo "Не удалось получить A-запись для домена $DOMAIN."
    echo "Убедитесь, что домен существует и уже направлен на сервер."
    exit 1
fi

echo "A-запись домена $DOMAIN указывает на: $domain_ip"

if [[ "$domain_ip" != "$external_ip" ]]; then
    echo "A-запись домена $DOMAIN не соответствует внешнему IP сервера."
    exit 1
fi

echo "A-запись домена $DOMAIN соответствует внешнему IP сервера."

if ss -tuln | grep -q ":443 "; then
    echo "Порт 443 занят. Освободите его перед запуском скрипта."
    exit 1
else
    echo "Порт 443 свободен."
fi

if ss -tuln | grep -q ":80 "; then
    echo "Порт 80 занят. Для этого скрипта он должен быть свободен."
    exit 1
else
    echo "Порт 80 свободен."
fi

if ss -tuln | grep -q ":${NODE_PORT} "; then
    echo "Порт ноды ${NODE_PORT} уже занят. Укажите другой порт."
    exit 1
else
    echo "Порт ноды ${NODE_PORT} свободен."
fi

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

git clone https://github.com/learning-zone/website-templates.git "$TEMP_DIR"

SITE_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | shuf -n 1)

mkdir -p /var/www/html
rm -rf /var/www/html/*
cp -r "$SITE_DIR"/* /var/www/html/

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

cat > /etc/nginx/sites-enabled/bootstrap.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

nginx -t
systemctl restart nginx

echo "Выпускаем сертификат через HTTP-01..."
certbot --nginx -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive --redirect

cat > /etc/nginx/sites-enabled/sni.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    if (\$host = $DOMAIN) {
        return 301 https://\$host\$request_uri;
    }

    return 404;
}

server {
    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

    ssl_stapling on;
    ssl_stapling_verify on;

    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/bootstrap.conf

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
echo
echo "Сертификат: $CERT_PATH"
echo "Ключ: $KEY_PATH"
echo
echo "В качестве Dest укажите: 127.0.0.1:$SPORT"
echo "В качестве SNI укажите: $DOMAIN"
echo
echo "Docker compose: /opt/remnanode/docker-compose.yml"
echo "Контейнер remnanode запущен."
echo "Проверка статуса: docker ps | grep remnanode"
echo "Логи: docker compose -f /opt/remnanode/docker-compose.yml logs -f remnanode"
echo "========================================"
