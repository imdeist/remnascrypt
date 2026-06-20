#!/bin/bash

# ==============================================================================
# REMNASCRYPT MANAGER v2.0
# Автоматизированный скрипт для развертывания и управления нодой
# ==============================================================================

# --- КОНФИГУРАЦИЯ И СИСТЕМНЫЕ ПУТИ ---
REPO_URL="https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh"
DIR="/opt/remnascrypt"                                 # Основная директория ноды
WEBROOT_DIR="/var/www/remnascrypt"                     # Директория для фейк-сайта
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf" # Конфиг веб-сервера
CONFIG_FILE="$DIR/docker-compose.yml"                  # Конфиг Docker-контейнера
SCRIPT_PATH="/usr/local/bin/remnascrypt"               # Путь для системной команды

# --- ЦВЕТА И ЭСТЕТИКА (ANSI Escape-коды) ---
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
WHITE=$'\033[37m'

# --- ФУНКЦИИ ВЫВОДА ЛОГОВ ---
info() { echo -e "${CYAN}➜ ${RESET}${BOLD}$1${RESET}"; }
success() { echo -e "${GREEN}✔ ${RESET}${BOLD}$1${RESET}"; }
warn() { echo -e "${YELLOW}⚠ ${RESET}${BOLD}$1${RESET}"; }
error() { echo -e "${RED}✖ ${RESET}${BOLD}$1${RESET}"; }

# --- ОТРИСОВКА ЗАГОЛОВКА ---
draw_banner() {
    clear
    echo -e "${MAGENTA}${BOLD}╭────────────────────────────────────────────────────╮"
    echo -e "│               R E M N A S C R Y P T                │"
    echo -e "│                 Node Manager v2.0                  │"
    echo -e "╰────────────────────────────────────────────────────╯${RESET}"
}

# ==============================================================================
# СИСТЕМНЫЕ ФУНКЦИИ И УТИЛИТЫ
# ==============================================================================

check_deps() {
    local deps=(curl nginx certbot git jq unzip wget nano)
    info "Проверка системных зависимостей..."
    
    export DEBIAN_FRONTEND=noninteractive
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "   ${DIM}Установка пакета: $dep...${RESET}"
            apt-get update >/dev/null 2>&1
            apt-get install -yq "$dep" >/dev/null 2>&1
        fi
    done

    if ! command -v docker &> /dev/null; then
        echo -e "   ${DIM}Установка Docker Engine...${RESET}"
        curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
    fi
    success "Все зависимости успешно проверены и установлены!"
}

uninstall_all() {
    draw_banner
    echo -e "${RED}${BOLD}⚠️  ВНИМАНИЕ: АБСОЛЮТНОЕ УДАЛЕНИЕ СИСТЕМЫ ⚠️${RESET}"
    echo -e "${DIM}Будут безвозвратно удалены следующие компоненты:${RESET}"
    echo -e "  ${RED}1.${RESET} Docker Engine, все контейнеры, образы и сети"
    echo -e "  ${RED}2.${RESET} Nginx веб-сервер и все его конфигурации"
    echo -e "  ${RED}3.${RESET} Certbot, логи и выпущенные SSL-сертификаты"
    echo -e "  ${RED}4.${RESET} Рабочие директории (/opt/remnascrypt, /var/www/remnascrypt)"
    echo -e "  ${RED}5.${RESET} Системные симлинки и команда вызова (remnascrypt)"
    echo -e "  ${RED}6.${RESET} Оптимизация сети (BBR)\n"
    
    read -r -p "Ты абсолютно уверен, что хочешь выжечь всё это? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then warn "Процесс удаления отменен."; sleep 1.5; return; fi

    info "Запущен процесс полной очистки сервера..."
    export DEBIAN_FRONTEND=noninteractive

    # Шаг 1: Docker
    if command -v docker &> /dev/null; then
        echo -e "   ${DIM}Остановка контейнеров и удаление Docker...${RESET}"
        if [[ -n "$(docker ps -aq 2>/dev/null)" ]]; then
            docker stop $(docker ps -aq) >/dev/null 2>&1
        fi
        apt-get purge -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker docker.io </dev/null>/dev/null 2>&1
        rm -rf /var/lib/docker /var/lib/containerd /etc/docker ~/.docker
    fi

    # Шаг 2: Nginx
    echo -e "   ${DIM}Удаление веб-сервера Nginx...${RESET}"
    systemctl stop nginx >/dev/null 2>&1
    apt-get purge -yq nginx nginx-common nginx-full </dev/null>/dev/null 2>&1
    rm -rf /etc/nginx /var/www/remnascrypt /var/log/nginx

    # Шаг 3: Certbot
    echo -e "   ${DIM}Удаление Certbot и SSL-сертификатов...${RESET}"
    apt-get purge -yq certbot python3-certbot-nginx </dev/null>/dev/null 2>&1
    rm -rf /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt

    # Шаг 4: Настройки сети
    echo -e "   ${DIM}Откат сетевых настроек (BBR)...${RESET}"
    rm -f /etc/sysctl.d/99-vpn-optim.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
    sysctl --system >/dev/null 2>&1

    # Шаг 5: Файлы и кэш
    echo -e "   ${DIM}Удаление локальных файлов и очистка кэша APT...${RESET}"
    rm -rf "$DIR" "$WEBROOT_DIR"
    rm -f "/usr/local/bin/remnascrypt" "/usr/bin/remnascrypt" "/bin/remnascrypt"
    rm -f "/usr/local/bin/run.sh" "$SCRIPT_PATH"
    apt-get autoremove -yq </dev/null>/dev/null 2>&1
    apt-get autoclean -yq </dev/null>/dev/null 2>&1

    success "Система абсолютно чиста. Увидимся!"
    exit 0
}

update_script() {
    draw_banner
    info "Загрузка последней версии скрипта из репозитория..."
    if curl -fsSL "$REPO_URL" -o "$DIR/remnascrypt.sh"; then
        chmod +x "$DIR/remnascrypt.sh"
        success "Скрипт успешно обновлен!"
        sleep 1.5
        # Перезагрузка скрипта в памяти
        exec bash "$DIR/remnascrypt.sh"
    else
        error "Ошибка при скачивании обновления. Проверьте соединение."
        sleep 2
    fi
}

# ==============================================================================
# УПРАВЛЕНИЕ КОМПОНЕНТАМИ НОДЫ
# ==============================================================================

select_xray_version() {
    draw_banner
    check_deps
    info "Запрос актуальных версий Xray с серверов GitHub..."
    
    local releases_json=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases")
    if [[ -z "$releases_json" ]]; then error "Ошибка сети или лимит запросов к GitHub API."; sleep 2; return; fi
    
    mapfile -t versions < <(echo "$releases_json" | jq -r '.[0:10] | .[] | "\(.tag_name)|\(.prerelease)"')
    
    echo -e "\n${BOLD}Доступные версии для установки:${RESET}"
    for i in "${!versions[@]}"; do
        IFS='|' read -r tag pre <<< "${versions[$i]}"
        local status="${GREEN}[STABLE]${RESET}"
        [[ "$pre" == "true" ]] && status="${YELLOW}[BETA]  ${RESET}"
        printf "  %-2s %-10s %s\n" "$((i+1)))" "$tag" "$status"
    done
    
    echo ""
    read -r -p "Выберите номер версии [1-10] (0 - отмена): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt 10 ]; then return; fi
    
    IFS='|' read -r tag pre <<< "${versions[$choice-1]}"
    info "Скачивание и интеграция ядра $tag..."

    rm -rf "$DIR/xray"
    mkdir -p "$DIR/xray"
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip" -o /tmp/xray.zip
    unzip -q -o /tmp/xray.zip -d "$DIR/xray" && chmod +x "$DIR/xray/xray" && rm /tmp/xray.zip
    
    if ! grep -q "\./xray/xray" "$CONFIG_FILE"; then
        sed -i '/volumes:/a \      - ./xray/xray:/usr/local/bin/xray' "$CONFIG_FILE"
    fi
    
    cd "$DIR" && docker compose down >/dev/null 2>&1 && docker compose up -d >/dev/null 2>&1
    success "Ядро Xray успешно обновлено до версии $tag!"
    sleep 2
}

select_template() {
    draw_banner
    info "Запрос доступных шаблонов из репозитория capsite..."
    
    local API_URL="https://api.github.com/repos/imdeist/capsite/contents/caps"
    local RAW_URL="https://raw.githubusercontent.com/imdeist/capsite/main/caps"
    
    local files_json=$(curl -s --max-time 10 "$API_URL")
    if [[ -z "$files_json" ]] || echo "$files_json" | grep -q "API rate limit"; then 
        error "Ошибка сети или лимит запросов к GitHub API."
        sleep 2
        return
    fi

    mapfile -t templates < <(echo "$files_json" | jq -r '.[]?.name' | grep "\.html$" | sort -V)
    
    if [ ${#templates[@]} -eq 0 ]; then
        warn "HTML шаблоны не найдены в репозитории!"
        sleep 2
        return
    fi

    echo -e "\n${BOLD}Доступные заглушки:${RESET}"
    for i in "${!templates[@]}"; do 
        printf "  %-2s %s\n" "$((i+1)))" "${templates[$i]}"
    done
    
    echo ""
    read -r -p "Выберите номер [1-${#templates[@]}] (0 - отмена): " choice
    if [[ "$choice" -eq 0 ]]; then return; fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#templates[@]}" ]; then
        warn "Неверный выбор. Отмена операции."
        sleep 1.5
        return
    fi

    local selected_file="${templates[$choice-1]}"
    info "Загрузка и установка шаблона: $selected_file..."
    
    find "$WEBROOT_DIR" -maxdepth 1 -name "*.html" -delete
    
    if curl -fsSL "$RAW_URL/$selected_file" -o "$WEBROOT_DIR/index.html"; then
        systemctl reload nginx >/dev/null 2>&1
        success "Сайт-заглушка успешно обновлена!"
    else
        error "Ошибка скачивания файла $selected_file."
    fi
    sleep 2
}

toggle_network_optim() {
    draw_banner
    if [[ -f "/etc/sysctl.d/99-vpn-optim.conf" ]]; then
        info "Откат сетевых настроек на стандартные..."
        rm -f /etc/sysctl.d/99-vpn-optim.conf
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
        sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
        sysctl --system >/dev/null 2>&1
        success "Оптимизация BBR отключена."
    else
        info "Включение оптимизации сети (BBR, TCP буферы)..."
        cat > /etc/sysctl.d/99-vpn-optim.conf <<EOF
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 5000
EOF
        sysctl -p /etc/sysctl.d/99-vpn-optim.conf >/dev/null 2>&1
        success "Сетевые параметры ядра оптимизированы!"
    fi
    sleep 1.5
}

# ==============================================================================
# ПАНЕЛЬ ИНФОРМАЦИИ (ДАШБОРД)
# ==============================================================================

show_info() {
    draw_banner
    info "Анализ конфигурации и статуса служб..."
    
    local domain=$(grep -oP "live/\K[^/]+" "$CONFIG_FILE" | head -1 || echo "Не найден")
    local node_ver=""
    local pkg_ver=$(docker exec remnascrypt sh -c 'cat /app/package.json 2>/dev/null || cat package.json 2>/dev/null' | grep -m 1 '"version":' | awk -F'"' '{print $4}')
    
    if [[ -n "$pkg_ver" ]]; then
        node_ver="v$pkg_ver"
    else
        local build_date=$(docker inspect remnascrypt --format '{{.Created}}' 2>/dev/null | cut -d'T' -f1)
        [[ -n "$build_date" ]] && node_ver="build $build_date" || node_ver="Unknown"
    fi
    
    local raw_xray=$(docker exec remnascrypt xray -version 2>/dev/null | head -n 1 | awk '{print $2}')
    local xray_ver=$([[ -n "$raw_xray" ]] && echo "v$raw_xray" || echo "Не найдено")
    
    local port_sni=$(grep -oP 'listen 127.0.0.1:\K\d+' "$NGINX_SITE" 2>/dev/null || echo "Не найден")
    local port_node=$(grep -oP 'NODE_PORT=\K\d+' "$CONFIG_FILE" 2>/dev/null || echo "Не найден")
    
    local status_docker=$(docker inspect -f '{{.State.Running}}' remnascrypt 2>/dev/null)
    local status_nginx=$(systemctl is-active nginx)

    local txt_docker=$([[ "$status_docker" == "true" ]] && echo -e "${GREEN}РАБОТАЕТ${RESET}" || echo -e "${RED}ОСТАНОВЛЕН${RESET}")
    local txt_nginx=$([[ "$status_nginx" == "active" ]] && echo -e "${GREEN}РАБОТАЕТ${RESET}" || echo -e "${RED}ОСТАНОВЛЕН${RESET}")

    clear
    draw_banner
    echo -e " 🌐 Домен:           ${BOLD}$domain${RESET}"
    echo -e " 📦 Remnanode:       ${BOLD}$node_ver${RESET}"
    echo -e " ⚡ Xray Core:       ${BOLD}$xray_ver${RESET}"
    echo -e " -----------------------------------"
    echo -e " 🚪 SelfSNI Порт:    ${YELLOW}$port_sni${RESET}"
    echo -e " ⚙️  Порт ноды:       ${YELLOW}$port_node${RESET}"
    echo -e " -----------------------------------"
    echo -e " 🐳 Docker:          $txt_docker"
    echo -e " 🌐 Nginx:           $txt_nginx"
    echo -e ""
    
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
}

# ==============================================================================
# ПРОЦЕСС ПЕРВИЧНОЙ УСТАНОВКИ
# ==============================================================================

install_process() {
    draw_banner
    info "Инициализация мастера первичной установки"
    
    read -r -p "🌐 Введите целевой домен: " DOMAIN
    read -r -p "🚪 Порт SelfSNI [9000]: " SPORT; SPORT="${SPORT:-9000}"
    read -r -p "⚙️  Порт ноды [2272]: " NODE_PORT; NODE_PORT="${NODE_PORT:-2272}"
    read -r -s -p "🔑 Установите SECRET_KEY: " SECRET_KEY; echo
    
    echo ""
    check_deps
    
    mkdir -p "$DIR" "$WEBROOT_DIR"

    info "Конфигурация временного веб-сервера для SSL проверки..."
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf
    systemctl restart nginx >/dev/null 2>&1
    
    info "Генерация действительного SSL сертификата (Certbot)..."
    certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error "Критическая ошибка выпуска SSL. Проверьте статус DNS A-записи домена!"
        exit 1
    fi
    success "SSL-сертификаты успешно получены и активированы!"
    
    info "Развертывание финальной конфигурации Nginx..."
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root $WEBROOT_DIR;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    location / { try_files \$uri \$uri/ =404; }
}

server {
    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    real_ip_header proxy_protocol; set_real_ip_from 127.0.0.1;
    
    location / { return 404; }
}
EOF
    systemctl restart nginx >/dev/null 2>&1
    
    info "Сборка контейнера Remnascrypt через Docker Compose..."
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
    cd "$DIR" && docker compose up -d >/dev/null 2>&1
    
    info "Создание глобальных команд вызова менеджера..."
    curl -fsSL "$REPO_URL" -o "$DIR/remnascrypt.sh" >/dev/null 2>&1
    chmod +x "$DIR/remnascrypt.sh"
    echo -e "#!/bin/bash\nbash $DIR/remnascrypt.sh" > "$DIR/run.sh"
    chmod +x "$DIR/run.sh"
    ln -sf "$DIR/run.sh" "$SCRIPT_PATH"
    
    echo ""
    success "ПРОЦЕСС УСТАНОВКИ УСПЕШНО ЗАВЕРШЕН!"
    echo -e "Вызывайте панель управления из любой точки системы командой: ${CYAN}${BOLD}remnascrypt${RESET}"
    exit 0
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ (МАРШРУТИЗАЦИЯ)
# ==============================================================================

main_menu() {
    while true; do
        draw_banner
        
        # Динамический статус BBR
        local bbr_status="${RED}[ВЫКЛ]${RESET}"
        if [[ -f "/etc/sysctl.d/99-vpn-optim.conf" ]]; then
            bbr_status="${GREEN}[ВКЛ]${RESET}"
        fi

        echo -e "  1)  📊 Статус"
        echo -e "  2)  ⚡ Обновить ядро Xray"
        echo -e "  3)  🔄 Перезагрузить Docker"
        echo -e "  4)  🚪 Изменить SelfSNI порт"
        echo -e "  5)  ⚙️  Изменить порт ноды"
        echo -e "  6)  🔑 Изменить SECRET_KEY"
        echo -e "  7)  🌐 Выбрать cap"
        echo -e "  8)  🚀 Оптимизация сети (BBR) $bbr_status"
        echo -e "  9)  📥 Обновить скрипт"
        echo -e "  10) ${RED}🗑️  Удалить ноду${RESET}"
        echo -e "  0)  🚪 Выход\n"
        
        read -r -p " Выберите действие [0-10]: " act

        case "$act" in
            1) show_info ;;
            2) select_xray_version ;;
            3) 
                info "Перезапуск контейнера приложений..."
                cd "$DIR" && docker compose restart >/dev/null 2>&1
                success "Все службы успешно перезапущены!"
                sleep 1.5
                ;;
            4) 
                draw_banner
                read -r -p " Введите новый порт SelfSNI: " NP
                if [[ "$NP" =~ ^[0-9]+$ ]]; then
                    sed -i "s/listen 127.0.0.1:[0-9]\+/listen 127.0.0.1:$NP/" "$NGINX_SITE"
                    systemctl restart nginx >/dev/null 2>&1
                    success "Порт SelfSNI успешно изменен на $NP"
                else warn "Ошибка: Вводить можно исключительно цифры!"; fi
                sleep 2
                ;;
            5) 
                draw_banner
                read -r -p " Введите новый внутренний порт ноды: " NP
                if [[ "$NP" =~ ^[0-9]+$ ]]; then
                    sed -i "s/NODE_PORT=.*/NODE_PORT=$NP/" "$CONFIG_FILE"
                    info "Применение конфигурации и рестарт ноды..."
                    cd "$DIR" && docker compose up -d >/dev/null 2>&1
                    success "Порт ноды успешно изменен на $NP"
                else warn "Ошибка: Вводить можно исключительно цифры!"; fi
                sleep 2
                ;;
            6) 
                draw_banner
                read -r -p " Введите новый SECRET_KEY: " NK
                if [[ -n "$NK" ]]; then
                    sed -i "s/SECRET_KEY=.*/SECRET_KEY=$NK/" "$CONFIG_FILE"
                    info "Перезапуск контейнера с новым секретным ключом..."
                    cd "$DIR" && docker compose up -d >/dev/null 2>&1
                    success "Секретный ключ авторизации успешно обновлен!"
                else warn "Ошибка: Ключ безопасности не может быть пустым!"; fi
                sleep 2
                ;;
            7) select_template ;;
            8) toggle_network_optim ;;
            9) update_script ;;
            10) uninstall_all ;;
            0) clear; exit 0 ;;
            *) warn "Неверный ввод, выберите пункт от 0 до 10."; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# ТОЧКА ВХОДА
# ==============================================================================

if [[ "$EUID" -ne 0 ]]; then 
    echo -e "${RED}✖ Ошибка: Этот скрипт требует привилегий суперпользователя (root). Запустите через sudo.${RESET}"
    exit 1
fi

if [[ -f "$CONFIG_FILE" ]]; then 
    main_menu
else 
    install_process
fi
