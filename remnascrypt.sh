#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
REPO_URL="https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh"

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

# Проверка зависимостей
check_deps() {
    local deps=(curl nginx certbot git jq unzip)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "Установка зависимости: $dep..."
            apt update && apt install -y "$dep"
        fi
    done

    # Правильная установка Docker
    if ! command -v docker &> /dev/null; then
        log "Установка Docker..."
        curl -fsSL https://get.docker.com | bash
    fi
}

uninstall_all() {
    echo -e "\n${RED}⚠️  ВНИМАНИЕ: АБСОЛЮТНОЕ УДАЛЕНИЕ (DOCKER, NGINX, CERTBOT, ДАННЫЕ) ⚠️${RESET}"
    read -r -p "Ты уверен? Это удалит Docker Engine, Nginx, Certbot и ВСЕ файлы ноды (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then echo "Отмена."; return; fi

    # 1. Docker: Остановка всех контейнеров и удаление пакетов
    if command -v docker &> /dev/null; then
        log "Остановка всех контейнеров..."
        docker stop $(docker ps -aq) 2>/dev/null
        log "Удаление Docker..."
        apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker 2>/dev/null
        rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    fi

    # 2. Nginx: Удаление
    log "Удаление Nginx..."
    systemctl stop nginx 2>/dev/null
    apt purge -y nginx nginx-common nginx-full 2>/dev/null
    rm -rf /etc/nginx /var/www/remnascrypt /var/log/nginx

    # 3. Certbot: Удаление
    log "Удаление Certbot..."
    apt purge -y certbot python3-certbot-nginx 2>/dev/null
    rm -rf /etc/letsencrypt /var/lib/letsencrypt

    # 4. Файлы скрипта и бинарники
    log "Удаление файлов скрипта..."
    rm -rf "$DIR"
    rm -f "$SCRIPT_PATH"
    rm -f "/usr/local/bin/run.sh"

    # 5. Финальная очистка системы
    apt autoremove -y
    apt autoclean

    echo -e "${GREEN}✅ Всё удалено. Система чиста.${RESET}"
    exit 0
}

select_xray_version() {
    check_deps
    echo -e "\n${CYAN}🔍 Поиск версий Xray...${RESET}"
    local releases_json=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases")
    if [[ -z "$releases_json" ]]; then error "Ошибка сети или API GitHub"; return; fi
    
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
    log "Установка $tag..."
    
    mkdir -p "$DIR/xray"
    curl -L "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip" -o /tmp/xray.zip
    unzip -o /tmp/xray.zip -d "$DIR/xray" && chmod +x "$DIR/xray/xray" && rm /tmp/xray.zip
    
    if ! grep -q "\./xray/xray" "$CONFIG_FILE"; then
        sed -i '/volumes:/a \      - ./xray/xray:/usr/local/bin/xray' "$CONFIG_FILE"
    fi
    
    docker compose -f "$CONFIG_FILE" up -d && log "Ядро обновлено до $tag!"
}

show_info() {
    # Корректный парсинг домена через grep (ищем путь live/DOMAIN/)
    local domain=$(grep -oP "live/\K[^/]+" "$CONFIG_FILE" | head -1 || echo "Не найдено")
    
    # Получение версий
    local node_ver=$(docker inspect remnascrypt --format '{{.Config.Image}}' 2>/dev/null | cut -d: -f2 || echo "Unknown")
    local xray_ver=$(/usr/local/bin/xray -version 2>&1 | head -n 1 | awk '{print $3}' || echo "Не найдено")
    
    # Статусы
    local port_sni=$(grep -oP 'listen 127.0.0.1:\K\d+' "$NGINX_SITE" 2>/dev/null || echo "Не найдено")
    local port_node=$(grep -oP 'NODE_PORT=\K\d+' "$CONFIG_FILE" 2>/dev/null || echo "Не найдено")
    local status_docker=$(docker inspect -f '{{.State.Running}}' remnascrypt 2>/dev/null)
    local status_nginx=$(systemctl is-active nginx)

    echo -e "\n${PURPLE}=== СТАТУС НОДЫ ===${RESET}"
    printf "%-18s %s\n" "🌐 Домен:" "$domain"
    printf "%-18s %s\n" "📦 Remnanode:" "$node_ver"
    printf "%-18s %s\n" "⚡ Xray Core:" "$xray_ver"
    printf "%-18s %s\n" "🚪 SelfSNI порт:" "$port_sni"
    printf "%-18s %s\n" "⚙️ Порт ноды:" "$port_node"
    echo -e "🐳 Docker:        $( [[ "$status_docker" == "true" ]] && echo -e "${GREEN}РАБОТАЕТ${RESET}" || echo -e "${RED}ОСТАНОВЛЕН${RESET}" )"
    echo -e "🌐 Nginx:         $( [[ "$status_nginx" == "active" ]] && echo -e "${GREEN}РАБОТАЕТ${RESET}" || echo -e "${RED}ОСТАНОВЛЕН${RESET}" )"
    
    echo -e "\n-----------------------------------"
    read -n 1 -s -r -p "Нажми любую кнопку для возврата..."
}

install_process() {
    clear
    echo -e "${CYAN}🚀 WELCOME TO REMNASCRYPT INSTALLER 🚀${RESET}"
    read -r -p "Домен: " DOMAIN
    read -r -p "Порт SelfSNI [9000]: " SPORT; SPORT="${SPORT:-9000}"
    read -r -p "Порт ноды [2272]: " NODE_PORT; NODE_PORT="${NODE_PORT:-2272}"
    read -r -s -p "SECRET_KEY: " SECRET_KEY; echo
    
    check_deps
    mkdir -p "$DIR" "$WEBROOT_DIR"
    
    # 1. Базовый конфиг Nginx для получения SSL
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf
    systemctl restart nginx
    
    log "Получаю SSL сертификат..."
    certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive
    
    # 2. Финальный конфиг Nginx с SSL
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
    
    log "Создаю docker-compose..."
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
    
    curl -fsSL "$REPO_URL" -o "$DIR/remnascrypt.sh"
    chmod +x "$DIR/remnascrypt.sh"
    echo -e "#!/bin/bash\nbash $DIR/remnascrypt.sh" > "$DIR/run.sh"
    chmod +x "$DIR/run.sh"
    ln -sf "$DIR/run.sh" "$SCRIPT_PATH"
    
    log "✅ УСТАНОВКА ЗАВЕРШЕНА!"
}

# --- МЕНЮ ---
main_menu() {
    while true; do
        clear
        echo -e "${PURPLE}=== REMNASCRYPT MANAGER ===${RESET}"
        # Используем printf для фиксации ширины
        # %-3s — номер пункта (ширина 3 символа, выравнивание влево)
        # %s  — текст пункта
        printf "%-3s %s\n" "1)" "📊 Статус (подробно)"
        printf "%-3s %s\n" "2)" "⚡ Обновить ядро Xray"
        printf "%-3s %s\n" "3)" "🔄 Перезагрузить Docker"
        printf "%-3s %s\n" "4)" "🚪 Изменить SelfSNI порт"
        printf "%-3s %s\n" "5)" "⚙️ Изменить порт ноды"
        printf "%-3s %s\n" "6)" "🔑 Изменить SECRET_KEY"
        printf "%-3s %s\n" "7)" "🗑️ УДАЛИТЬ ВСЁ"
        printf "%-3s %s\n" "8)" "🚪 Выход"
        
        read -r -p "Выбор: " act
        case "$act" in
            1) show_info ;;
            2) select_xray_version ;;
            3) docker compose -f "$CONFIG_FILE" up -d && log "Docker перечитал конфиги!" ;;
            4) 
                read -r -p "Новый порт: " NP
                if [[ "$NP" =~ ^[0-9]+$ ]]; then
                    sed -i "s/listen 127.0.0.1:[0-9]\+/listen 127.0.0.1:$NP/" "$NGINX_SITE" && systemctl restart nginx && log "Порт изменен"
                else warn "Только цифры!"; fi ;;
            5) 
                read -r -p "Новый порт: " NP
                if [[ "$NP" =~ ^[0-9]+$ ]]; then
                    sed -i "s/NODE_PORT=.*/NODE_PORT=$NP/" "$CONFIG_FILE" && docker compose -f "$CONFIG_FILE" up -d && log "Порт ноды обновлен"
                else warn "Только цифры!"; fi ;;
            6) 
                read -r -p "Новый ключ: " NK
                if [[ -n "$NK" ]]; then
                    sed -i "s/SECRET_KEY=.*/SECRET_KEY=$NK/" "$CONFIG_FILE" && docker compose -f "$CONFIG_FILE" up -d && log "Ключ обновлен"
                else warn "Ключ не может быть пустым"; fi ;;
            7) uninstall_all ;;
            8) exit 0 ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

if [[ "$EUID" -ne 0 ]]; then echo "Root, please."; exit 1; fi
if [[ -f "$CONFIG_FILE" ]]; then main_menu; else install_process; fi
