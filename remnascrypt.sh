#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
REPO_URL="https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh"
DIR="/opt/remnascrypt"
WEBROOT_DIR="/var/www/remnascrypt"
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf"
CONFIG_FILE="$DIR/docker-compose.yml"
SCRIPT_PATH="/usr/local/bin/remnascrypt"

# --- ЦВЕТА ---
RESET="\033[0m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
PURPLE="\033[35m"

# --- ФУНКЦИИ ---
log() { echo -e "\n${GREEN}[INFO]${RESET} $1"; }
warn() { echo -e "\n${YELLOW}[WARN]${RESET} $1"; }
error() { echo -e "\n${RED}[ERROR]${RESET} $1"; exit 1; }

check_deps() {
    log "Проверка зависимостей..."
    apt update && apt install -y curl jq unzip nginx certbot git
    
    if ! command -v docker &> /dev/null; then
        log "Установка официального Docker..."
        curl -fsSL https://get.docker.com | bash
    fi
}

uninstall_all() {
    echo -e "\n${RED}⚠️  ВНИМАНИЕ: УДАЛЕНИЕ ⚠️${RESET}"
    read -r -p "Уверен? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    docker compose -f "$CONFIG_FILE" down -v 2>/dev/null
    rm -rf "$DIR" "$WEBROOT_DIR" "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf "$SCRIPT_PATH"
    systemctl reload nginx
    log "Удалено."
    exit 0
}

select_xray_version() {
    echo -e "\n${CYAN}🔍 Поиск версий Xray...${RESET}"
    local releases_json=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases")
    [[ -z "$releases_json" ]] && error "Ошибка API GitHub"
    
    mapfile -t versions < <(echo "$releases_json" | jq -r '.[0:10] | .[] | "\(.tag_name)|\(.prerelease)"')
    for i in "${!versions[@]}"; do
        IFS='|' read -r tag pre <<< "${versions[$i]}"
        echo -e "$((i+1))) $tag"
    done
    
    read -r -p "Выбор [1-10]: " choice
    [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt 10 ] && return
    
    IFS='|' read -r tag pre <<< "${versions[$choice-1]}"
    mkdir -p "$DIR/xray"
    curl -L "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip" -o /tmp/xray.zip
    unzip -o /tmp/xray.zip -d "$DIR/xray" && chmod +x "$DIR/xray/xray" && rm /tmp/xray.zip
    
    if ! grep -q "\./xray/xray" "$CONFIG_FILE"; then
        sed -i '/volumes:/a \      - ./xray/xray:/usr/local/bin/xray' "$CONFIG_FILE"
    fi
    docker compose -f "$CONFIG_FILE" up -d && log "Xray $tag установлен!"
}

show_info() {
    local domain=$(grep -oP '(?<=/etc/letsencrypt/live/)[^/]+' "$CONFIG_FILE" 2>/dev/null || echo "Не найдено")
    local status_docker=$(docker inspect -f '{{.State.Running}}' remnascrypt 2>/dev/null)
    echo -e "\n${PURPLE}=== СТАТУС ===${RESET}"
    echo -e "Домен: $domain"
    echo -e "Docker: $([[ "$status_docker" == "true" ]] && echo "RUNNING" || echo "STOPPED")"
    read -n 1 -s -r -p "Нажми любую кнопку..."
}

install_process() {
    clear
    echo -e "${CYAN}=== REMNASCRYPT INSTALLER ===${RESET}"
    read -r -p "Домен: " DOMAIN
    read -r -p "Порт SelfSNI [9000]: " SPORT; SPORT="${SPORT:-9000}"
    read -r -p "Порт ноды [2272]: " NODE_PORT; NODE_PORT="${NODE_PORT:-2272}"
    read -r -s -p "SECRET_KEY: " SECRET_KEY; echo
    [[ -z "$SECRET_KEY" ]] && SECRET_KEY="secret"

    check_deps
    mkdir -p "$DIR" "$WEBROOT_DIR"
    
    # Nginx (для сертификата)
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf
    systemctl restart nginx || error "Nginx не стартует. Проверь 80 порт!"
    
    log "Получаю SSL (Certbot)..."
    certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive || error "Ошибка получения SSL"
    
    # Nginx (финальный)
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    root $WEBROOT_DIR;
}
EOF
    systemctl restart nginx
    
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
EOF
    cd "$DIR" && docker compose up -d || error "Docker не поднялся"
    
    curl -fsSL "$REPO_URL" -o "$DIR/remnascrypt.sh"
    chmod +x "$DIR/remnascrypt.sh"
    echo -e "#!/bin/bash\nbash $DIR/remnascrypt.sh" > "$DIR/run.sh"
    chmod +x "$DIR/run.sh"
    ln -sf "$DIR/run.sh" "$SCRIPT_PATH"
    log "✅ УСТАНОВКА ЗАВЕРШЕНА!"
}

main_menu() {
    while true; do
        clear
        echo "1) Статус 2) Xray 3) Рестарт 4) Порт SNI 5) Порт Ноды 6) Ключ 7) Удалить 8) Выход"
        read -r -p "Выбор: " act
        case "$act" in
            1) show_info ;;
            2) select_xray_version ;;
            3) docker compose -f "$CONFIG_FILE" up -d ;;
            4) read -r -p "Порт: " NP; [[ "$NP" =~ ^[0-9]+$ ]] && sed -i "s/listen 127.0.0.1:[0-9]\+/listen 127.0.0.1:$NP/" "$NGINX_SITE" && systemctl restart nginx ;;
            5) read -r -p "Порт: " NP; [[ "$NP" =~ ^[0-9]+$ ]] && sed -i "s/NODE_PORT=.*/NODE_PORT=$NP/" "$CONFIG_FILE" && docker compose -f "$CONFIG_FILE" up -d ;;
            6) read -r -p "Ключ: " NK; [[ -n "$NK" ]] && sed -i "s/SECRET_KEY=.*/SECRET_KEY=$NK/" "$CONFIG_FILE" && docker compose -f "$CONFIG_FILE" up -d ;;
            7) uninstall_all ;;
            8) exit 0 ;;
        esac
    done
}

[[ "$EUID" -ne 0 ]] && echo "Root required." && exit 1
[[ -f "$CONFIG_FILE" ]] && main_menu || install_process
