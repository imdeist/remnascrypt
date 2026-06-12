#!/bin/bash

# ==========================================
# КОНФИГУРАЦИЯ И СИСТЕМНЫЕ ПУТИ
# ==========================================
REPO_URL="https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh"
DIR="/opt/remnascrypt"
WEBROOT_DIR="/var/www/remnascrypt"
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf"
CONFIG_FILE="$DIR/docker-compose.yml"
SCRIPT_PATH="/usr/local/bin/remnascrypt"

# ==========================================
# ЦВЕТА И ЭСТЕТИКА (Строгий стандарт $'\033...')
# ==========================================
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

# ==========================================
# ФУНКЦИИ ВЫВОДА ЛОГОВ
# ==========================================
info() { echo -e "${CYAN}➜ ${RESET}${BOLD}$1${RESET}"; }
success() { echo -e "${GREEN}✔ ${RESET}${BOLD}$1${RESET}"; }
warn() { echo -e "${YELLOW}⚠ ${RESET}${BOLD}$1${RESET}"; }
error() { echo -e "${RED}✖ ${RESET}${BOLD}$1${RESET}"; }

# Отрисовка шапки скрипта (ширина подогнана строго под 52 символа рамки)
draw_banner() {
    clear
    echo -e "${MAGENTA}${BOLD}╭────────────────────────────────────────────────────╮"
    echo -e "│               R E M N A S C R Y P T                │"
    echo -e "│                 Node Manager v2.0                  │"
    echo -e "╰────────────────────────────────────────────────────╯${RESET}"
}

# ==========================================
# БЛОК УСТАНОВКИ И ЗАВИСИМОСТЕЙ
# ==========================================

check_deps() {
    local deps=(curl nginx certbot git jq unzip wget)
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
    echo -e "  ${RED}5.${RESET} Системные симлинки и команда вызова (remnascrypt)\n"
    
    read -r -p "Ты абсолютно уверен, что хочешь выжечь всё это? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then warn "Процесс удаления отменен."; sleep 1.5; return; fi

    info "Запущен процесс полной очистки сервера..."
    
    # Жесткое отключение интерактивных запросов apt
    export DEBIAN_FRONTEND=noninteractive

    if command -v docker &> /dev/null; then
        echo -e "   ${DIM}Остановка контейнеров и удаление Docker...${RESET}"
        if [[ -n "$(docker ps -aq 2>/dev/null)" ]]; then
            docker stop $(docker ps -aq) >/dev/null 2>&1
        fi
        apt-get purge -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker docker.io </dev/null>/dev/null 2>&1
        rm -rf /var/lib/docker /var/lib/containerd /etc/docker ~/.docker
    fi

    echo -e "   ${DIM}Удаление веб-сервера Nginx...${RESET}"
    systemctl stop nginx >/dev/null 2>&1
    apt-get purge -yq nginx nginx-common nginx-full </dev/null>/dev/null 2>&1
    rm -rf /etc/nginx /var/www/remnascrypt /var/log/nginx

    echo -e "   ${DIM}Удаление Certbot и SSL-сертификатов...${RESET}"
    apt-get purge -yq certbot python3-certbot-nginx </dev/null>/dev/null 2>&1
    rm -rf /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt

    echo -e "   ${DIM}Удаление локальных файлов и системных ярлыков...${RESET}"
    # Уничтожение директорий
    rm -rf "$DIR" "$WEBROOT_DIR"
    # Прямое удаление всех возможных алиасов и симлинков
    rm -f "/usr/local/bin/remnascrypt" "/usr/bin/remnascrypt" "/bin/remnascrypt"
    rm -f "/usr/local/bin/run.sh" "$SCRIPT_PATH"

    echo -e "   ${DIM}Финальная оптимизация системы...${RESET}"
    apt-get autoremove -yq </dev/null>/dev/null 2>&1
    apt-get autoclean -yq </dev/null>/dev/null 2>&1

    success "Система абсолютно чиста. Увидимся!"
    exit 0
}

# ==========================================
# БЛОК РАБОТЫ С ЯДРОМ И СТАТУСОМ
# ==========================================

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
        printf "  %-2s %s %s\n" "$((i+1)))" "$status" "$tag"
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
    
    cd "$DIR" && docker compose down && docker compose up -d >/dev/null 2>&1
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
    
    # Очистка старых html файлов в папке веб-сервера
    find "$WEBROOT_DIR" -maxdepth 1 -name "*.html" -delete
    
    if curl -fsSL "$RAW_URL/$selected_file" -o "$WEBROOT_DIR/index.html"; then
        systemctl reload nginx >/dev/null 2>&1
        success "Сайт-заглушка успешно обновлена!"
    else
        error "Ошибка скачивания файла $selected_file."
    fi
    sleep 2
}

show_info() {
    draw_banner
    info "Анализ конфигурации и статуса служб..."
    
    local domain=$(grep -oP "live/\K[^/]+" "$CONFIG_FILE" | head -1 || echo "Не найден")
    local node_ver=$(docker inspect remnascrypt --format '{{.Config.Image}}' 2>/dev/null | cut -d: -f2 || echo "Unknown")
    local xray_ver=$(docker exec remnascrypt xray -version 2>/dev/null | head -n 1 | awk '{print $3}' || echo "Не найдено")
    local port_sni=$(grep -oP 'listen 127.0.0.1:\K\d+' "$NGINX_SITE" 2>/dev/null || echo "Не найден")
    local port_node=$(grep -oP 'NODE_PORT=\K\d+' "$CONFIG_FILE" 2>/dev/null || echo "Не найден")
    local status_docker=$(docker inspect -f '{{.State.Running}}' remnascrypt 2>/dev/null)
    local status_nginx=$(systemctl is-active nginx)

    local txt_docker=$([[ "$status_docker" == "true" ]] && echo "РАБОТАЕТ" || echo "ОСТАНОВЛЕН")
    local clr_docker=$([[ "$status_docker" == "true" ]] && echo "$GREEN" || echo "$RED")

    local txt_nginx=$([[ "$status_nginx" == "active" ]] && echo "РАБОТАЕТ" || echo "ОСТАНОВЛЕН")
    local clr_nginx=$([[ "$status_nginx" == "active" ]] && echo "$GREEN" || echo "$RED")

    local pad_1=$((30 - ${#domain}))
    local pad_2=$((30 - ${#node_ver}))
    local pad_3=$((30 - ${#xray_ver}))
    local pad_4=$((30 - ${#port_sni}))
    local pad_5=$((30 - ${#port_node}))
    local pad_6=$((30 - ${#txt_docker}))
    local pad_7=$((30 - ${#txt_nginx}))

    clear
    draw_banner
    echo -e "${CYAN}╭────────────────────────────────────────────────────╮${RESET}"
    printf "${CYAN}│${RESET} 🌐 Домен:           ${BOLD}%s${RESET}%*s ${CYAN}│${RESET}\n" "$domain" "$pad_1" ""
    printf "${CYAN}│${RESET} 📦 Remnanode:       %s%*s ${CYAN}│${RESET}\n" "$node_ver" "$pad_2" ""
    printf "${CYAN}│${RESET} ⚡ Xray Core:       %s%*s ${CYAN}│${RESET}\n" "$xray_ver" "$pad_3" ""
    echo -e "${CYAN}├────────────────────────────────────────────────────┤${RESET}"
    printf "${CYAN}│${RESET} 🚪 SelfSNI Порт:    ${YELLOW}%s${RESET}%*s ${CYAN}│${RESET}\n" "$port_sni" "$pad_4" ""
    printf "${CYAN}│${RESET} ⚙️  Порт ноды:       ${YELLOW}%s${RESET}%*s ${CYAN}│${RESET}\n" "$port_node" "$pad_5" ""
    echo -e "${CYAN}├────────────────────────────────────────────────────┤${RESET}"
    printf "${CYAN}│${RESET} 🐳 Docker:          %s%s${RESET}%*s ${CYAN}│${RESET}\n" "$clr_docker" "$txt_docker" "$pad_6" ""
    printf "${CYAN}│${RESET} 🌐 Nginx:           %s%s${RESET}%*s ${CYAN}│${RESET}\n" "$clr_nginx" "$txt_nginx" "$pad_7" ""
    echo -e "${CYAN}╰────────────────────────────────────────────────────╯${RESET}"
    
    echo ""
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
}

# ==========================================
# БЛОК ПЕРВИЧНОЙ УСТАНОВКИ
# ==========================================

install_process() {
    draw_banner
    info "Инициализация мастера первичной установки"
    
    # Сбор стартовых данных
    read -r -p "🌐 Введите целевой домен: " DOMAIN
    read -r -p "🚪 Порт SelfSNI [9000]: " SPORT; SPORT="${SPORT:-9000}"
    read -r -p "⚙️  Порт ноды [2272]: " NODE_PORT; NODE_PORT="${NODE_PORT:-2272}"
    read -r -s -p "🔑 Установите SECRET_KEY: " SECRET_KEY; echo
    
    echo ""
    check_deps
    
    mkdir -p "$DIR" "$WEBROOT_DIR"
    
    # 1. Заглушка веб-сервера для верификации домена Certbot'ом
    info "Конфигурация временного веб-сервера для SSL проверки..."
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf
    systemctl restart nginx &>/dev/null
    
    # Выпуск бесплатного SSL-сертификата Let's Encrypt
    info "Генерация действительного SSL сертификата (Certbot)..."
    certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive &>/dev/null
    if [[ $? -ne 0 ]]; then
        error "Критическая ошибка выпуска SSL. Проверьте статус DNS A-записи домена!"
        exit 1
    fi
    success "SSL-сертификаты успешно получены и активированы!"
    
    # 2. Боевой отказоустойчивый конфиг Nginx (Сайт на 443 + Нода)
    info "Развертывание финальной конфигурации Nginx..."
    cat > "$NGINX_SITE" <<EOF
# Перенаправление HTTP -> HTTPS
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}

# Основной сайт-заглушка на порту 443
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root $WEBROOT_DIR;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    location / { try_files \$uri \$uri/ =404; }
}

# Защищенный локальный прокси-порт для ноды
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
    systemctl restart nginx &>/dev/null
    
    # 3. Генерация манифеста Docker Compose
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
    cd "$DIR" && docker compose up -d &>/dev/null
    
    # 4. Пропись глобальных алиасов управления в системе
    info "Создание глобальных команд вызова менеджера..."
    curl -fsSL "$REPO_URL" -o "$DIR/remnascrypt.sh" &>/dev/null
    chmod +x "$DIR/remnascrypt.sh"
    echo -e "#!/bin/bash\nbash $DIR/remnascrypt.sh" > "$DIR/run.sh"
    chmod +x "$DIR/run.sh"
    ln -sf "$DIR/run.sh" "$SCRIPT_PATH"
    
    echo ""
    success "ПРОЦЕСС УСТАНОВКИ УСПЕШНО ЗАВЕРШЕН!"
    echo -e "Вызывайте панель управления из любой точки системы командой: ${CYAN}${BOLD}remnascrypt${RESET}"
    exit 0
}
# ==========================================
# ГЛАВНОЕ МЕНЮ (Точка входа)
# ==========================================

main_menu() {
    while true; do
        draw_banner
        echo -e "${CYAN}╭────────────────────────────────────────────────────╮${RESET}"
        echo -e "${CYAN}│${RESET}  1) 📊 Статус                                      ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  2) ⚡ Обновить ядро Xray                          ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  3) 🔄 Перезагрузить Docker                        ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  4) 🚪 Изменить SelfSNI порт                       ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  5) ⚙️  Изменить порт ноды                          ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  6) 🔑 Изменить SECRET_KEY                         ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  7) 🌐 Выбрать cap                                 ${CYAN}│${RESET}"
        echo -e "${CYAN}├────────────────────────────────────────────────────┤${RESET}"
        echo -e "${CYAN}│${RESET}  8) 🗑️  Удалить                                     ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  9) 🚪 Выход                                       ${CYAN}│${RESET}"
        echo -e "${CYAN}╰────────────────────────────────────────────────────╯\n${RESET}"
        read -r -p " Выберите действие [1-9]: " act

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
            8) uninstall_all ;;
            9) clear; exit 0 ;;
            *) warn "Неверный ввод, выберите пункт от 1 до 9."; sleep 1 ;;
        esac
    done
}

if [[ "$EUID" -ne 0 ]]; then 
    echo -e "${RED}✖ Ошибка: Этот скрипт требует привилегий суперпользователя (root). Запустите через sudo.${RESET}"
    exit 1
fi

if [[ -f "$CONFIG_FILE" ]]; then 
    main_menu
else 
    install_process
fi
