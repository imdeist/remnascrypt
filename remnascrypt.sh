#!/bin/bash
set -euo pipefail

# --- Конфигурация по умолчанию ---
SPORT=9000
NODE_PORT_DEFAULT=2272
WEBROOT_DIR="/var/www/remnascrypt"
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/remnascrypt.conf"
NGINX_DEFAULT_LINK="/etc/nginx/sites-enabled/default"
INDEX_HTML_URL="https://raw.githubusercontent.com/imdeist/remnascrypt/main/index.html"

# Проверка прав суперпользователя (скрипт должен работать от root)
if [[ "$EUID" -ne 0 ]]; then echo "Ошибка: скрипт необходимо запускать от root."; exit 1; fi

# --- Ввод пользовательских данных ---
read -r -p "Введите доменное имя: " DOMAIN
read -r -p "Введите порт для ноды RemnaNode [${NODE_PORT_DEFAULT}]: " NODE_PORT
NODE_PORT="${NODE_PORT:-$NODE_PORT_DEFAULT}"
read -r -s -p "Введите SECRET_KEY для RemnaNode: " SECRET_KEY
echo
read -r -p "Версия ядра xray (оставьте поле пустым для пропуска): " XRAY_VERSION

# --- Установка системных зависимостей ---
apt update
apt install -y curl nginx certbot git dnsutils ca-certificates gnupg lsb-release unzip

# --- Логика установки кастомного ядра Xray ---
XRAY_VOLUME=""
if [[ -n "$XRAY_VERSION" ]]; then
    echo "Скачивание Xray версии $XRAY_VERSION..."
    mkdir -p /opt/remnanode/xray
    cd /opt/remnanode
    # Качаем архив по прямой ссылке с GitHub
    if curl -L "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip" -o Xray-linux-64.zip; then
        unzip -o Xray-linux-64.zip -d ./xray
        rm Xray-linux-64.zip
        # Проверяем, что файл действительно распаковался
        if [[ -f "./xray/xray" ]]; then
            XRAY_VOLUME="- ./xray/xray:/usr/local/bin/xray"
            echo "Xray $XRAY_VERSION успешно установлен."
        else
            echo "Ошибка: исполняемый файл xray не найден."
            exit 1
        fi
    else
        echo "Ошибка скачивания Xray."
        exit 1
    fi
fi

# --- Настройка Nginx ---
mkdir -p "$WEBROOT_DIR"
curl -fsSL "$INDEX_HTML_URL" -o "$WEBROOT_DIR/index.html"
rm -f "$NGINX_DEFAULT_LINK" 2>/dev/null || true

# Создание конфигурации Nginx с поддержкой Proxy Protocol для VLESS
cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $WEBROOT_DIR; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    root $WEBROOT_DIR;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
systemctl restart nginx

# Выпуск SSL сертификата через Certbot (HTTP-01 challenge)
certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive

# --- Установка Docker ---
if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
apt install -y docker-compose-plugin

# --- Генерация Docker Compose ---
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
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY=$SECRET_KEY
    volumes:
      # Монтируем сертификаты в фиксированные пути для универсальности
      - '/etc/letsencrypt/live/$DOMAIN/fullchain.pem:/etc/letsencrypt/live/fullchain.pem:ro'
      - '/etc/letsencrypt/live/$DOMAIN/privkey.pem:/etc/letsencrypt/live/privkey.pem:ro'
      - '/etc/letsencrypt/archive:/etc/letsencrypt/archive:ro'
      $XRAY_VOLUME
EOF

# --- Оптимизация сетевого стека (BBR) ---
cat > /etc/sysctl.d/99-vpn-optim.conf << EOF
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF
sysctl -p /etc/sysctl.d/99-vpn-optim.conf

# Запуск контейнера
cd /opt/remnanode && docker compose up -d

# --- Финальная информация ---
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
