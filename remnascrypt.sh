#!/bin/bash

# --- ЦВЕТА И ЭСТЕТИКА ---
ESC="\033["
RESET="${ESC}0m"
BOLD="${ESC}1m"
CYAN="${ESC}36m"
GREEN="${ESC}32m"
RED="${ESC}31m"
YELLOW="${ESC}33m"
PURPLE="${ESC}35m"

# --- ПУТИ ---
DIR="/opt/remnascrypt"
WEBROOT_DIR="/var/www/remnascrypt"
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf"
CONFIG_FILE="$DIR/docker-compose.yml"
SCRIPT_PATH="/usr/local/bin/remnascrypt"

# --- ФУНКЦИИ ---
log() { echo -e "\n${GREEN}[INFO]${RESET} $1"; }
warn() { echo -e "\n${YELLOW}[WARN]${RESET} $1"; }
error() { echo -e "\n${RED}[ERROR]${RESET} $1"; }

uninstall_all() {
    echo -e "\n${RED}⚠️  ВНИМАНИЕ: ПОЛНОЕ УДАЛЕНИЕ ⚠️${RESET}"
    read -r -p "Ты уверен, что хочешь сжечь мосты? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then log "Фух, отмена. Работаем дальше!"; return; fi

    log "Тушим Docker..."
    [[ -f "$CONFIG_FILE" ]] && docker compose -f "$CONFIG_FILE" down -v --remove-orphans >/dev/null 2>&1 || true

    log "Стираем следы..."
    rm -rf "$DIR" "$WEBROOT_DIR" "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf "$SCRIPT_PATH"
    systemctl reload nginx 2>/dev/null || true

    echo -e "\n${GREEN}✅ Всё чисто. Нода удалена.${RESET}"
    exit 0
}

select_xray_version() {
    if ! command -v jq &> /dev/null; then apt update -qq && apt install -y jq; fi
    
    echo -e "\n${CYAN}🔍 Ищем свежие версии Xray...${RESET}"
    local releases_json=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases")
    
    mapfile -t versions < <(echo "$releases_json" | jq -r '.[0:10] | .[] | "\(.tag_name)|\(.prerelease)"')
    
    echo -e "\n${BOLD}Выберите версию:${RESET}"
    for i in "${!versions[@]}"; do
        IFS='|' read -r tag pre <<< "${versions[$i]}"
        local status="${GREEN}STABLE${RESET}"
        [[ "$pre" == "true" ]] && status="${YELLOW}BETA${RESET}"
        echo -e "$((i+1))) $tag [$status]"
    done
    
    read -r -p "Выбор [1-10] (0 - отмена): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt 10 ]; then return; fi
    
    IFS='|' read -r tag pre <<< "${versions[$choice-1]}"
    log "Устанавливаю $tag..."
    
    mkdir -p "$DIR/xray"
    curl -L "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip" -o /tmp/xray.zip
    unzip -o /tmp/xray.zip -d "$DIR/xray" && chmod +x "$DIR/xray/xray" && rm /tmp/xray.zip
    
    if ! grep -q "./xray/xray" "$CONFIG_FILE"; then
        sed -i '/volumes:/a \      - ./xray/xray:/usr/local/bin/xray' "$CONFIG_FILE"
    fi
    
    docker compose -f "$CONFIG_FILE" restart
    log "Версия $tag установлена и работает! 🔥"
}

show_info() {
    local domain=$(grep -oP '(?<=/etc/letsencrypt/live/)[^/]+' "$CONFIG_FILE" 2>/dev/null || echo "Не найдено")
    local port_sni=$(grep -oP 'listen 127.0.0.1:\K\d+' "$NGINX_SITE" 2>/dev/null || echo "Не найдено")
    local port_node=$(grep -oP 'NODE_PORT=\K\d+' "$CONFIG_FILE" 2>/dev/null || echo "Не найдено")
    
    echo -e "\n${PURPLE}=== СТАТУС НОДЫ ===${RESET}"
    echo -e "🌐 Домен: ${CYAN}$domain${RESET}"
    echo -e "🚪 SelfSNI порт: ${YELLOW}$port_sni${RESET}"
    echo -e "⚙️ Порт ноды: ${YELLOW}$port_node${RESET}"
    echo -e "🚀 Статус: $(docker inspect -f '{{.State.Running}}' remnascrypt 2>/dev/null && echo -e "${GREEN}РАБОТАЕТ${RESET}" || echo -e "${RED}ОСТАНОВЛЕН${RESET}")"
    read -n 1 -s -r -p "Нажми любую кнопку..."
}

install_process() {
    clear
    echo -e "${CYAN}===================================${RESET}"
    echo -e "${CYAN}🚀 WELCOME TO REMNASCRYPT INSTALLER 🚀${RESET}"
    echo -e "${CYAN}===================================${RESET}"
    
    read -r -p "Домен: " DOMAIN
    read -r -p "Порт SelfSNI [9000]: " SPORT; SPORT="${SPORT:-9000}"
    read -r -p "Порт ноды [2272]: " NODE_PORT; NODE_PORT="${NODE_PORT:-2272}"
    read -r -s -p "SECRET_KEY: " SECRET_KEY; echo
    
    apt update && apt install -y curl nginx certbot git dnsutils jq unzip
    mkdir -p "$DIR" "$WEBROOT_DIR"
    
    # 1. СНАЧАЛА БАЗОВЫЙ NGINX (только HTTP)
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf
    systemctl restart nginx
    
    # 2. ПОЛУЧАЕМ СЕРТИФИКАТ (теперь Nginx работает, порт 80 открыт)
    log "Получаю SSL сертификат..."
    certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive
    
    # 3. ТЕПЕРЬ ПЕРЕЗАПИСЫВАЕМ NGINX НА HTTPS
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
    ssl_protocols TLSv1.2 TLSv1.3;
    real_ip_header proxy_protocol; set_real_ip_from 127.0.0.1;
    root $WEBROOT_DIR; location / { try_files \$uri \$uri/ =404; }
}
EOF
    systemctl restart nginx
    
    # 4. Docker
    if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
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
    cd "$DIR" && docker compose up -d
    
    # Персистентность команды
    cat > "$DIR/run.sh" <<EOF
#!/bin/bash
bash $DIR/remnascrypt.sh
EOF
    chmod +x "$DIR/run.sh"
    ln -sf "$DIR/run.sh" "$SCRIPT_PATH"
    cp "$0" "$DIR/remnascrypt.sh"
    
    echo -e "\n${GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА!${RESET}"
    echo -e "Теперь пиши ${BOLD}remnascrypt${RESET} в консоли."
}

# --- МЕНЮ ---
main_menu() {
    while true; do
        clear
        echo -e "${PURPLE}=============================="
        echo -e "    REMNASCRYPT MANAGER"
        echo -e "==============================${RESET}"
        echo "1) 📊 Статус ноды"
        echo "2) ⚡ Обновить ядро Xray"
        echo "3) 🔄 Перезагрузить Docker"
        echo "4) 🚪 Изменить SelfSNI порт"
        echo "5) ⚙️ Изменить порт ноды"
        echo "6) 🔑 Изменить SECRET_KEY"
        echo "7) 🗑️ УДАЛИТЬ ВСЁ"
        echo "8) 🚪 Выход"
        echo -e "${PURPLE}==============================${RESET}"
        read -r -p "Выбор: " act
        case "$act" in
            1) show_info ;;
            2) select_xray_version ;;
            3) docker compose -f "$CONFIG_FILE" restart && log "Docker ожил!" ;;
            4) read -r -p "Порт: " NP; sed -i "s/listen 127.0.0.1:[0-9]\+/listen 127.0.0.1:$NP/" "$NGINX_SITE" && systemctl restart nginx ;;
            5) read -r -p "Порт: " NP; sed -i "s/NODE_PORT=.*/NODE_PORT=$NP/" "$CONFIG_FILE" && docker compose -f "$CONFIG_FILE" up -d ;;
            6) read -r -p "Ключ: " NK; sed -i "s/SECRET_KEY=.*/SECRET_KEY=$NK/" "$CONFIG_FILE" && docker compose -f "$CONFIG_FILE" up -d ;;
            7) uninstall_all ;;
            8) exit 0 ;;
            *) echo "Ошибка!" ;;
        esac
    done
}

# --- ЗАПУСК ---
if [[ "$EUID" -ne 0 ]]; then echo "Root, please."; exit 1; fi

if [[ -f "$CONFIG_FILE" ]]; then
    main_menu
else
    install_process
fi
