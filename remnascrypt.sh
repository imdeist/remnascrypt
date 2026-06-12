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

# Проверка и тихая установка пакетов
check_deps() {
    local deps=(curl nginx certbot git jq unzip)
    info "Проверка системных зависимостей..."
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "   ${DIM}Установка пакета: $dep...${RESET}"
            apt update &>/dev/null && apt install -y "$dep" &>/dev/null
        fi
    done

    # Установка Docker Engine, если отсутствует
    if ! command -v docker &> /dev/null; then
        echo -e "   ${DIM}Установка Docker Engine...${RESET}"
        curl -fsSL https://get.docker.com | bash &>/dev/null
    fi
    success "Все зависимости успешно проверены и установлены!"
}

# Полное удаление всех компонентов системы
uninstall_all() {
    draw_banner
    echo -e "${RED}${BOLD}⚠️  ВНИМАНИЕ: АБСОЛЮТНОЕ УДАЛЕНИЕ СИСТЕМЫ ⚠️${RESET}"
    echo -e "${DIM}Это действие безвозвратно удалит Docker Engine, Nginx, Certbot и все данные ноды.${RESET}\n"
    read -r -p "Ты уверен, что хочешь продолжить? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then warn "Процесс удаления отменен."; sleep 1.5; return; fi

    info "Запущен процесс полной очистки сервера..."

    # Остановка и снос Docker пакетов
    if command -v docker &> /dev/null; then
        echo -e "   ${DIM}Остановка контейнеров и удаление Docker...${RESET}"
        docker stop $(docker ps -aq) &>/dev/null
        apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker &>/dev/null
        rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    fi

    # Полное удаление Nginx конфигураций и директорий
    echo -e "   ${DIM}Удаление веб-сервера Nginx...${RESET}"
    systemctl stop nginx &>/dev/null
    apt purge -y nginx nginx-common nginx-full &>/dev/null
    rm -rf /etc/nginx /var/www/remnascrypt /var/log/nginx

    # Удаление SSL сертификатов Let's Encrypt
    echo -e "   ${DIM}Удаление Certbot и SSL-сертификатов...${RESET}"
    apt purge -y certbot python3-certbot-nginx &>/dev/null
    rm -rf /etc/letsencrypt /var/lib/letsencrypt

    # Удаление рабочих папок скрипта и системных симлинков
    echo -e "   ${DIM}Удаление локальных файлов и ярлыков...${RESET}"
    rm -rf "$DIR" "$SCRIPT_PATH" "/usr/local/bin/run.sh"

    # Очистка кэша пакетов apt
    echo -e "   ${DIM}Финальная оптимизация системы...${RESET}"
    apt autoremove -y &>/dev/null
    apt autoclean &>/dev/null

    success "Система абсолютно чиста. Увидимся!"
    exit 0
}

# ==========================================
# БЛОК РАБОТЫ С ЯДРОМ И СТАТУСОМ
# ==========================================

# Смена/Обновление версии ядра Xray
select_xray_version() {
    draw_banner
    check_deps
    info "Запрос актуальных версий Xray с серверов GitHub..."
    
    # Получаем список релизов (таймаут 10 сек)
    local releases_json=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases")
    if [[ -z "$releases_json" ]]; then error "Ошибка сети или лимит запросов к GitHub API."; sleep 2; return; fi
    
    # Парсим последние 10 версий (выделяем тег и признак пререлиза)
    mapfile -t versions < <(echo "$releases_json" | jq -r '.[0:10] | .[] | "\(.tag_name)|\(.prerelease)"')
    
    echo -e "\n${BOLD}Доступные версии для установки:${RESET}"
    for i in "${!versions[@]}"; do
        IFS='|' read -r tag pre <<< "${versions[$i]}"
        local status="${GREEN}[STABLE]${RESET}"
        [[ "$pre" == "true" ]] && status="${YELLOW}[BETA]  ${RESET}"
        # Вывод теперь обрабатывает цвета корректно
        printf "  %-2s %s %s\n" "$((i+1)))" "$status" "$tag"
    done
    
    echo ""
    read -r -p "Выберите номер версии [1-10] (0 - отмена): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt 10 ]; then return; fi
    
    IFS='|' read -r tag pre <<< "${versions[$choice-1]}"
    info "Скачивание и интеграция ядра $tag..."
    
    mkdir -p "$DIR/xray"
    # Тихо скачиваем zip архивы и распаковываем бинарник
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip" -o /tmp/xray.zip
    unzip -q -o /tmp/xray.zip -d "$DIR/xray" && chmod +x "$DIR/xray/xray" && rm /tmp/xray.zip
    
    # Монтируем бинарник в контейнер через volumes, если записи еще нет
    if ! grep -q "\./xray/xray" "$CONFIG_FILE"; then
        sed -i '/volumes:/a \      - ./xray/xray:/usr/local/bin/xray' "$CONFIG_FILE"
    fi
    
    # Пересобираем контейнер с новым ядром
    cd "$DIR" && docker compose up -d &>/dev/null
    success "Ядро Xray успешно обновлено до версии $tag!"
    sleep 2
}

# Панель мониторинга (Дашборд статуса ноды)
show_info() {
    draw_banner
    info "Анализ конфигурации и статуса служб..."
    
    # Считываем текущий рабочий домен из путей сертификатов
    local domain=$(grep -oP "live/\K[^/]+" "$CONFIG_FILE" | head -1 || echo "Не найден")
    
    # Запрос версий компонентов
    local node_ver=$(docker inspect remnascrypt --format '{{.Config.Image}}' 2>/dev/null | cut -d: -f2 || echo "Unknown")
    local xray_ver=$(docker exec remnascrypt xray -version 2>/dev/null | head -n 1 | awk '{print $3}' || echo "Не найдено")
    
    # Парсинг портов из конфигов Nginx и Compose
    local port_sni=$(grep -oP 'listen 127.0.0.1:\K\d+' "$NGINX_SITE" 2>/dev/null || echo "Не найден")
    local port_node=$(grep -oP 'NODE_PORT=\K\d+' "$CONFIG_FILE" 2>/dev/null || echo "Не найден")
    
    # Проверка активности процессов
    local status_docker=$(docker inspect -f '{{.State.Running}}' remnascrypt 2>/dev/null)
    local status_nginx=$(systemctl is-active nginx)

    # Чистый текст статусов служб для математического расчета ширины строки
    local txt_docker=$([[ "$status_docker" == "true" ]] && echo "РАБОТАЕТ" || echo "ОСТАНОВЛЕН")
    local clr_docker=$([[ "$status_docker" == "true" ]] && echo "$GREEN" || echo "$RED")

    local txt_nginx=$([[ "$status_nginx" == "active" ]] && echo "РАБОТАЕТ" || echo "ОСТАНОВЛЕН")
    local clr_nginx=$([[ "$status_nginx" == "active" ]] && echo "$GREEN" || echo "$RED")

    # Вычисление динамических пробелов. Базовая ширина контента = 30 символов.
    local pad_1=$((30 - ${#domain}))
    local pad_2=$((30 - ${#node_ver}))
    local pad_3=$((30 - ${#xray_ver}))
    local pad_4=$((30 - ${#port_sni}))
    local pad_5=$((30 - ${#port_node}))
    local pad_6=$((30 - ${#txt_docker}))
    local pad_7=$((30 - ${#txt_nginx}))

    # Отрисовка идеально ровного дашборда
    clear
    echo -e "${CYAN}╭────────────────────────────────────────────────────╮"
    echo -e "│             ${BOLD}С Т А Т У С   С И С Т Е М Ы${RESET}${CYAN}            │"
    echo -e "├────────────────────────────────────────────────────┤${RESET}"
    printf "│ 🌐 Домен:           ${BOLD}%s${RESET}%*s │\n" "$domain" "$pad_1" ""
    printf "│ 📦 Remnanode:       %s%*s │\n" "$node_ver" "$pad_2" ""
    printf "│ ⚡ Xray Core:       %s%*s │\n" "$xray_ver" "$pad_3" ""
    echo -e "${CYAN}├────────────────────────────────────────────────────┤${RESET}"
    printf "│ 🚪 SelfSNI Порт:    ${YELLOW}%s${RESET}%*s │\n" "$port_sni" "$pad_4" ""
    printf "│ ⚙️  Порт ноды:      ${YELLOW}%s${RESET}%*s │\n" "$port_node" "$pad_5" ""
    echo -e "${CYAN}├────────────────────────────────────────────────────┤${RESET}"
    printf "│ 🐳 Docker:          %s%s${RESET}%*s │\n" "$clr_docker" "$txt_docker" "$pad_6" ""
    printf "│ 🌐 Nginx:           %s%s${RESET}%*s │\n" "$clr_nginx" "$txt_nginx" "$pad_7" ""
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
        # Отрисовка меню с жестко фиксированными пробелами (pixel-perfect дизайн под эмодзи)
        echo -e "${CYAN}╭────────────────────────────────────────────────────╮${RESET}"
        echo -e "${CYAN}│${RESET}  1) 📊 Статус (подробно)                          ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  2) ⚡ Обновить ядро Xray                         ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  3) 🔄 Перезагрузить службы (Docker)             ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  4) 🚪 Изменить SelfSNI порт                      ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  5) ⚙️  Изменить порт ноды                        ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  6) 🔑 Изменить SECRET_KEY                        ${CYAN}│${RESET}"
        echo -e "${CYAN}├────────────────────────────────────────────────────┤${RESET}"
        echo -e "${CYAN}│${RESET}  7) ${RED}🗑️  УДАЛИТЬ ВСЁ${RESET}                               ${CYAN}│${RESET}"
        echo -e "${CYAN}│${RESET}  8) 🚪 Выход                                      ${CYAN}│${RESET}"
        echo -e "${CYAN}╰────────────────────────────────────────────────────╯${RESET}\n"
        read -r -p " Выберите действие [1-8]: " act

        case "$act" in
            1) show_info ;;
            2) select_xray_version ;;
            3) 
                info "Перезапуск контейнера приложений..."
                cd "$DIR" && docker compose restart &>/dev/null
                success "Все службы успешно перезапущены!"
                sleep 1.5
                ;;
            4) 
                draw_banner
                read -r -p " Введите новый порт SelfSNI: " NP
                if [[ "$NP" =~ ^[0-9]+$ ]]; then
                    # Точечная замена порта локального прокси
                    sed -i "s/listen 127.0.0.1:[0-9]\+/listen 127.0.0.1:$NP/" "$NGINX_SITE"
                    systemctl restart nginx &>/dev/null
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
                    cd "$DIR" && docker compose up -d &>/dev/null
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
                    cd "$DIR" && docker compose up -d &>/dev/null
                    success "Секретный ключ авторизации успешно обновлен!"
                else warn "Ошибка: Ключ безопасности не может быть пустым!"; fi
                sleep 2
                ;;
            7) uninstall_all ;;
            8) clear; exit 0 ;;
            *) warn "Неверный ввод, выберите пункт от 1 до 8."; sleep 1 ;;
        esac
    done
}

# ==========================================
# ПРОВЕРКА ПРАВ И СТАРТ СКРИПТА
# ==========================================

# Проверка на права Суперпользователя (Root)
if [[ "$EUID" -ne 0 ]]; then 
    echo -e "${RED}✖ Ошибка: Этот скрипт требует привилегий суперпользователя (root). Запустите через sudo.${RESET}"
    exit 1
fi

# Если compose-файл существует — нода уже развернута. Открываем меню.
# Иначе запускаем мастер установки с нуля.
if [[ -f "$CONFIG_FILE" ]]; then 
    main_menu
else 
    install_process
fi
