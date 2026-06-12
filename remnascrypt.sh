#!/bin/bash
set -euo pipefail

# --- КОНСТАНТЫ ---
DIR="/opt/remnascrypt"
WEBROOT_DIR="/var/www/remnascrypt"
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf"
CONFIG_FILE="$DIR/docker-compose.yml"
INDEX_HTML_URL="https://raw.githubusercontent.com/imdeist/capsite/main/caps/service_superlight_1.html"

# --- УТИЛИТЫ ---
log() { echo -e "\n[INFO] $1"; }
error() { echo -e "\n[ERROR] $1"; }
is_installed() { [[ -f "$CONFIG_FILE" ]]; }

# --- ФУНКЦИИ УПРАВЛЕНИЯ ---

select_template() {
    local API_URL="https://api.github.com/repos/imdeist/capsite/contents/caps"
    local RAW_URL="https://raw.githubusercontent.com/imdeist/capsite/main/caps"
    local files_json=$(curl -s "$API_URL")
    mapfile -t templates < <(echo "$files_json" | jq -r '.[].name' | grep ".html" | sort -V)
    
    if [ ${#templates[@]} -eq 0 ]; then
        curl -fsSL "$INDEX_HTML_URL" -o "$WEBROOT_DIR/index.html"
    else
        echo -e "\nДоступные шаблоны:"
        for i in "${!templates[@]}"; do echo "$((i+1))) ${templates[$i]}"; done
        read -r -p "Выберите номер [1-${#templates[@]}]: " choice
        
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#templates[@]}" ]; then
            curl -fsSL "$INDEX_HTML_URL" -o "$WEBROOT_DIR/index.html"
        else
            curl -fsSL "$RAW_URL/${templates[$choice-1]}" -o "$WEBROOT_DIR/index.html"
        fi
    fi
    systemctl reload nginx
    log "Шаблон обновлен."
}

select_xray_version() {
    if ! command -v jq &> /dev/null; then apt update -qq && apt install -y jq; fi
    local releases_json=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases")
    mapfile -t versions < <(echo "$releases_json" | jq -r '.[0:5] | .[] | "\(.tag_name)"')
    
    echo -e "\nДоступные версии Xray:"
    for i in "${!versions[@]}"; do echo "$((i+1))) ${versions[$i]}"; done
    read -r -p "Выберите версию (0 для отмены): " choice
    
    if [[ "$choice" =~ ^[1-5]$ ]]; then
        local tag="${versions[$choice-1]}"
        log "Установка $tag..."
        mkdir -p "$DIR/xray"
        curl -L "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip" -o /tmp/xray.zip
        unzip -o /tmp/xray.zip -d "$DIR/xray"
        chmod +x "$DIR/xray/xray" && rm /tmp/xray.zip
        
        # Инъекция проброса в docker-compose
        if ! grep -q "./xray/xray" "$CONFIG_FILE"; then
            sed -i '/volumes:/a \      - ./xray/xray:/usr/local/bin/xray' "$CONFIG_FILE"
        fi
        docker compose -f "$CONFIG_FILE" restart
        log "Xray $tag установлен и контейнер перезапущен."
    fi
}

show_system_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then error "Конфиг не найден."; return; fi
    
    local domain=$(grep -oP '(?<=/etc/letsencrypt/live/)[^/]+' "$CONFIG_FILE" | head -n1)
    local port_sni=$(grep -oP 'listen 127.0.0.1:\K\d+' "$NGINX_SITE" || echo "Неизвестно")
    local port_node=$(grep -oP 'NODE_PORT=\K\d+' "$CONFIG_FILE" || echo "Неизвестно")
    local container_status=$(docker inspect -f '{{.State.Running}}' remnascrypt 2>/dev/null && echo "ЗАПУЩЕН" || echo "ОСТАНОВЛЕН")

    echo -e "\n=== СТАТУС НОДЫ ==="
    echo "Домен: $domain"
    echo "SelfSNI порт: $port_sni"
    echo "Порт ноды: $port_node"
    echo "Статус контейнера: $container_status"
    echo "===================="
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
}

change_selfsni_port() {
    read -r -p "Введите новый порт для SelfSNI: " NEW_PORT
    if [[ -f "$NGINX_SITE" ]]; then
        sed -i "s/listen 127.0.0.1:[0-9]\+/listen 127.0.0.1:$NEW_PORT/" "$NGINX_SITE"
        systemctl restart nginx
        log "Порт SelfSNI успешно изменен на $NEW_PORT."
    else
        error "Файл Nginx не найден."
    fi
}

change_node_port() {
    read -r -p "Введите новый порт ноды: " NEW_PORT
    if [[ -f "$CONFIG_FILE" ]]; then
        sed -i "s/NODE_PORT=.*/NODE_PORT=$NEW_PORT/" "$CONFIG_FILE"
        docker compose -f "$CONFIG_FILE" up -d
        log "Порт ноды успешно изменен на $NEW_PORT."
    else
        error "Файл docker-compose не найден."
    fi
}

change_secret_key() {
    read -r -s -p "Введите новый SECRET_KEY: " NEW_KEY; echo
    if [[ -f "$CONFIG_FILE" ]]; then
        sed -i "s/SECRET_KEY=.*/SECRET_KEY=$NEW_KEY/" "$CONFIG_FILE"
        docker compose -f "$CONFIG_FILE" up -d
        log "SECRET_KEY обновлен."
    else
        error "Файл docker-compose не найден."
    fi
}

restart_container() {
    if [[ -f "$CONFIG_FILE" ]]; then
        docker compose -f "$CONFIG_FILE" restart
        log "Контейнер перезапущен."
    else
        error "Конфиг не найден."
    fi
}

# --- УСТАНОВКА ---
install_remnascrypt() {
    echo "=== УСТАНОВКА REMNASCRYPT ==="
    read -r -p "Введите домен: " DOMAIN
    read -r -p "Введите порт SelfSNI [9000]: " SPORT; SPORT="${SPORT:-9000}"
    read -r -p "Введите порт ноды [2272]: " NODE_PORT; NODE_PORT="${NODE_PORT:-2272}"
    read -r -s -p "Введите SECRET_KEY: " SECRET_KEY; echo
    
    apt update && apt install -y curl nginx certbot git dnsutils jq unzip
    mkdir -p "$WEBROOT_DIR" "$DIR"
    
    # 1. Nginx для получения сертификата
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf
    systemctl restart nginx
    certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive
    
    # 2. Финальный Nginx
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $WEBROOT_DIR; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    real_ip_header proxy_protocol; set_real_ip_from 127.0.0.1;
    root $WEBROOT_DIR; location / { try_files \$uri \$uri/ =404; }
}
EOF
    systemctl restart nginx
    
    # 3. Docker
    if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
    apt install -y docker-compose-plugin
    cat > "$CONFIG_FILE" <<EOF
services:
  remnascrypt:
    container_name: remnascrypt
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add: [NET_ADMIN]
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY=$SECRET_KEY
    volumes:
      - '/etc/letsencrypt/live/$DOMAIN/fullchain.pem:/etc/letsencrypt/live/fullchain.pem:ro'
      - '/etc/letsencrypt/live/$DOMAIN/privkey.pem:/etc/letsencrypt/live/privkey.pem:ro'
      - '/etc/letsencrypt/archive:/etc/letsencrypt/archive:ro'
EOF
    cd "$DIR" && docker compose up -d
    
    # 4. Финализация
    cp "$0" /usr/local/bin/remnascrypt
    chmod +x /usr/local/bin/remnascrypt
    
    select_template
    log "Установка завершена. Используйте команду: remnascrypt"
}

# --- ОСНОВНАЯ ЛОГИКА ---
if [[ "$EUID" -ne 0 ]]; then echo "Требуются права root."; exit 1; fi

if ! is_installed; then
    install_remnascrypt
else
    while true; do
        clear
        echo "=== REMNASCRYPT MANAGER ==="
        echo "1) Информация о ноде"
        echo "2) Замена шаблона (CAP)"
        echo "3) Обновить ядро Xray"
        echo "4) Перезагрузить Docker"
        echo "5) Изменить порт SelfSNI"
        echo "6) Изменить порт ноды"
        echo "7) Изменить SECRET_KEY"
        echo "8) Удалить всё"
        echo "9) Выход"
        read -r -p "Ваш выбор: " act
        case "$act" in
            1) show_system_info ;;
            2) select_template ;;
            3) select_xray_version ;;
            4) restart_container ;;
            5) change_selfsni_port ;;
            6) change_node_port ;;
            7) change_secret_key ;;
            8) 
                read -r -p "Вы уверены, что хотите удалить всё? (y/n): " conf
                if [[ "$conf" == "y" ]]; then 
                    docker compose -f "$CONFIG_FILE" down 2>/dev/null
                    rm -rf "$DIR" "$WEBROOT_DIR" "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf /usr/local/bin/remnascrypt
                    systemctl restart nginx
                    log "Система полностью очищена."
                    exit 0
                fi ;;
            9) exit 0 ;;
            *) echo "Неверная команда" ;;
        esac
    done
fi
