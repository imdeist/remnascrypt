#!/bin/bash

# ==========================================
# КОНФИГУРАЦИЯ И ПУТИ
# ==========================================
REPO_URL="https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh"
DIR="/opt/remnascrypt"
WEBROOT_DIR="/var/www/remnascrypt"
NGINX_SITE="/etc/nginx/sites-available/remnascrypt.conf"
CONFIG_FILE="$DIR/docker-compose.yml"
SCRIPT_PATH="/usr/local/bin/remnascrypt"

# ==========================================
# ЦВЕТА И ВИЗУАЛ (ANSI Escape Codes)
# ==========================================
ESC="\033["
RESET="${ESC}0m"
BOLD="${ESC}1m"
DIM="${ESC}2m"
RED="${ESC}31m"
GREEN="${ESC}32m"
YELLOW="${ESC}33m"
BLUE="${ESC}34m"
MAGENTA="${ESC}35m"
CYAN="${ESC}36m"
WHITE="${ESC}37m"

# ==========================================
# ФУНКЦИИ ВЫВОДА (Для красивых логов)
# ==========================================
# Выводит информационное сообщение с синей стрелочкой
info() { echo -e "${CYAN}➜ ${RESET}${BOLD}$1${RESET}"; }
# Выводит сообщение об успехе с зеленой галочкой
success() { echo -e "${GREEN}✔ ${RESET}${BOLD}$1${RESET}"; }
# Выводит предупреждение с желтым значком
warn() { echo -e "${YELLOW}⚠ ${RESET}${BOLD}$1${RESET}"; }
# Выводит критическую ошибку с красным крестиком
error() { echo -e "${RED}✖ ${RESET}${BOLD}$1${RESET}"; }

# Отрисовка красивого заголовка
draw_banner() {
    clear
    echo -e "${MAGENTA}${BOLD}"
    echo " ╭──────────────────────────────────────────╮"
    echo " │          R E M N A S C R Y P T           │"
    echo " │            Node Manager v2.0             │"
    echo " ╰──────────────────────────────────────────╯"
    echo -e "${RESET}"
}

# ==========================================
# БЛОК УСТАНОВКИ И ПРОВЕРКИ
# ==========================================

# Функция проверки и установки нужных пакетов
check_deps() {
    local deps=(curl nginx certbot git jq unzip)
    info "Проверка системных зависимостей..."
    
    # Идем по массиву пакетов. Если чего-то нет — ставим тихо (без вывода портянок apt)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "   ${DIM}Установка: $dep...${RESET}"
            apt update &>/dev/null && apt install -y "$dep" &>/dev/null
        fi
    done

    # Установка Docker, если его нет в системе
    if ! command -v docker &> /dev/null; then
        echo -e "   ${DIM}Установка Docker Engine...${RESET}"
        curl -fsSL https://get.docker.com | bash &>/dev/null
    fi
    success "Все зависимости установлены!"
}

# Функция полной очистки системы от следов скрипта
uninstall_all() {
    draw_banner
    echo -e "${RED}⚠️  ВНИМАНИЕ: АБСОЛЮТНОЕ УДАЛЕНИЕ ⚠️${RESET}"
    echo -e "${DIM}Это действие удалит Docker Engine, Nginx, Certbot и ВСЕ файлы ноды.${RESET}"
    read -r -p "Вы уверены? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then warn "Удаление отменено."; return; fi

    info "Запущен процесс полного удаления..."

    # 1. Убиваем и сносим Docker
    if command -v docker &> /dev/null; then
        echo -e "   ${DIM}Удаление контейнеров и Docker...${RESET}"
        docker stop $(docker ps -aq) &>/dev/null
        apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker &>/dev/null
        rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    fi

    # 2. Сносим веб-сервер
    echo -e "   ${DIM}Удаление Nginx...${RESET}"
    systemctl stop nginx &>/dev/null
    apt purge -y nginx nginx-common nginx-full &>/dev/null
    rm -rf /etc/nginx /var/www/remnascrypt /var/log/nginx

    # 3. Сносим сертификаты
    echo -e "   ${DIM}Удаление Certbot...${RESET}"
    apt purge -y certbot python3-certbot-nginx &>/dev/null
    rm -rf /etc/letsencrypt /var/lib/letsencrypt

    # 4. Сносим файлы самого проекта
    echo -e "   ${DIM}Удаление файлов и бинарников...${RESET}"
    rm -rf "$DIR" "$SCRIPT_PATH" "/usr/local/bin/run.sh"

    # 5. Чистим хвосты системы
    echo -e "   ${DIM}Финальная очистка системы...${RESET}"
    apt autoremove -y &>/dev/null
    apt autoclean &>/dev/null

    success "Система полностью очищена. До свидания!"
    exit 0
}

# ==========================================
# БЛОК УПРАВЛЕНИЯ ЯДРОМ И СТАТУСОМ
# ==========================================

# Обновление Xray (с красивым выводом версий)
select_xray_version() {
    draw_banner
    check_deps
    info "Запрос доступных версий Xray с GitHub..."
    
    # Получаем JSON релизов, ограничиваем время 10 секундами
    local releases_json=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases")
    if [[ -z "$releases_json" ]]; then error "Ошибка сети или лимит запросов API GitHub"; return; fi
    
    # Парсим JSON: берем 10 последних, вытаскиваем тег и статус пререлиза
    mapfile -t versions < <(echo "$releases_json" | jq -r '.[0:10] | .[] | "\(.tag_name)|\(.prerelease)"')
    
    echo -e "\n${BOLD}Доступные версии:${RESET}"
    # Красиво форматируем список версий
    for i in "${!versions[@]}"; do
        IFS='|' read -r tag pre <<< "${versions[$i]}"
        local status="${GREEN}[STABLE]${RESET}"
        [[ "$pre" == "true" ]] && status="${YELLOW}[BETA]  ${RESET}"
        printf "  %-2s %s %s\n" "$((i+1)))" "$status" "$tag"
    done
    
    echo ""
    read -r -p "Выберите версию [1-10] (0 - отмена): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt 10 ]; then return; fi
    
    # Установка выбранной версии
    IFS='|' read -r tag pre <<< "${versions[$choice-1]}"
    info "Скачивание и установка $tag..."
    
    mkdir -p "$DIR/xray"
    # Тихо качаем и распаковываем
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip" -o /tmp/xray.zip
    unzip -q -o /tmp/xray.zip -d "$DIR/xray" && chmod +x "$DIR/xray/xray" && rm /tmp/xray.zip
    
    # Добавляем проброс бинарника в докер, если его там еще нет
    if ! grep -q "\./xray/xray" "$CONFIG_FILE"; then
        sed -i '/volumes:/a \      - ./xray/xray:/usr/local/bin/xray' "$CONFIG_FILE"
    fi
    
    # Перезапускаем контейнер тихо
    cd "$DIR" && docker compose up -d &>/dev/null
    success "Ядро Xray успешно обновлено до версии $tag!"
    sleep 2
}

# Дашборд состояния ноды
show_info() {
    draw_banner
    info "Сбор данных о системе..."
    
    # Ищем домен в конфиге докера
    local domain=$(grep -oP "live/\K[^/]+" "$CONFIG_FILE" | head -1 || echo "Не найдено")
    
    # Версии
    local node_ver=$(docker inspect remnascrypt --format '{{.Config.Image}}' 2>/dev/null | cut -d: -f2 || echo "Unknown")
    local xray_ver=$(docker exec remnascrypt xray -version 2>/dev/null | head -n 1 | awk '{print $3}' || echo "Не найдено")
    
    # Порты
    local port_sni=$(grep -oP 'listen 127.0.0.1:\K\d+' "$NGINX_SITE" 2>/dev/null || echo "Не найдено")
    local port_node=$(grep -oP 'NODE_PORT=\K\d+' "$CONFIG_FILE" 2>/dev/null || echo "Не найдено")
    
    # Статусы служб
    local status_docker=$(docker inspect -f '{{.State.Running}}' remnascrypt 2>/dev/null)
    local status_nginx=$(systemctl is-active nginx)

    # Красивые плашки статуса
    local str_docker=$([[ "$status_docker" == "true" ]] && echo -e "${GREEN}РАБОТАЕТ${RESET}" || echo -e "${RED}ОСТАНОВЛЕН${RESET}")
    local str_nginx=$([[ "$status_nginx" == "active" ]] && echo -e "${GREEN}РАБОТАЕТ${RESET}" || echo -e "${RED}ОСТАНОВЛЕН${RESET}")

    # Вывод дашборда с рамками
    clear
    echo -e "${CYAN}╭──────────────────────────────────────────────╮"
    echo -e "│             ${BOLD}С Т А Т У С   Н О Д Ы${RESET}${CYAN}            │"
    echo -e "├──────────────────────────────────────────────┤${RESET}"
    printf "│ %-18s %-35s │\n" "🌐 Домен:" "${BOLD}$domain${RESET}"
    printf "│ %-18s %-35s │\n" "📦 Remnanode:" "$node_ver"
    printf "│ %-18s %-35s │\n" "⚡ Xray Core:" "$xray_ver"
    echo -e "${CYAN}├──────────────────────────────────────────────┤${RESET}"
    printf "│ %-18s %-35s │\n" "🚪 SelfSNI Порт:" "${YELLOW}$port_sni${RESET}"
    printf "│ %-18s %-35s │\n" "⚙️  Порт ноды:" "${YELLOW}$port_node${RESET}"
    echo -e "${CYAN}├──────────────────────────────────────────────┤${RESET}"
    printf "│ %-18s %-35s │\n" "🐳 Docker:" "$str_docker"
    printf "│ %-18s %-35s │\n" "🌐 Nginx:" "$str_nginx"
    echo -e "${CYAN}╰──────────────────────────────────────────────╯${RESET}"
    
    echo ""
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
}

# ==========================================
# БЛОК ПЕРВИЧНОЙ УСТАНОВКИ
# ==========================================

install_process() {
    draw_banner
    info "Запуск мастера первичной настройки"
    
    # Сбор данных от пользователя
    read -r -p "🌐 Введите ваш домен: " DOMAIN
    read -r -p "🚪 Порт SelfSNI [9000]: " SPORT; SPORT="${SPORT:-9000}"
    read -r -p "⚙️  Порт ноды [2272]: " NODE_PORT; NODE_PORT="${NODE_PORT:-2272}"
    read -r -s -p "🔑 Введите SECRET_KEY: " SECRET_KEY; echo
    
    echo ""
    check_deps
    
    # Создаем директории
    mkdir -p "$DIR" "$WEBROOT_DIR"
    
    # 1. Заглушка Nginx для получения SSL-сертификата
    info "Настройка веб-сервера для получения SSL..."
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80; server_name $DOMAIN; root $WEBROOT_DIR;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/remnascrypt.conf
    systemctl restart nginx &>/dev/null
    
    # Запрашиваем SSL-сертификат (тихо)
    info "Генерация SSL сертификата Certbot..."
    certbot certonly --webroot -w "$WEBROOT_DIR" -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive &>/dev/null
    if [[ $? -ne 0 ]]; then
        error "Не удалось получить SSL-сертификат. Проверьте A-запись домена!"
        exit 1
    fi
    success "SSL сертификат получен!"
    
    # 2. Финальный конфиг Nginx (Сайт на 443, нода на локальном порту)
    info "Генерация боевого конфигурационного файла Nginx..."
    cat > "$NGINX_SITE" <<EOF
# Перенаправление с HTTP (80) на HTTPS (443)
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

# Внутренний прокси для ноды
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
    
    # 3. Настройка Docker Compose
    info "Развертывание Docker-контейнера Remnascrypt..."
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
    
    # 4. Создание ярлыков управления
    info "Создание системных ярлыков..."
    curl -fsSL "$REPO_URL" -o "$DIR/remnascrypt.sh" &>/dev/null
    chmod +x "$DIR/remnascrypt.sh"
    echo -e "#!/bin/bash\nbash $DIR/remnascrypt.sh" > "$DIR/run.sh"
    chmod +x "$DIR/run.sh"
    ln -sf "$DIR/run.sh" "$SCRIPT_PATH"
    
    echo ""
    success "УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
    echo -e "Для вызова меню управления введите команду: ${CYAN}${BOLD}remnascrypt${RESET}"
    exit 0
}

# ==========================================
# ГЛАВНОЕ МЕНЮ (Точка входа)
# ==========================================

main_menu() {
    while true; do
        draw_banner
        # Рисуем красивое меню с использованием box-drawing символов
        echo -e "${CYAN}╭──────────────────────────────────────────╮${RESET}"
        printf "${CYAN}│${RESET} %-4s %-35s ${CYAN}│${RESET}\n" "1)" "📊 Статус (подробно)"
        printf "${CYAN}│${RESET} %-4s %-35s ${CYAN}│${RESET}\n" "2)" "⚡ Обновить ядро Xray"
        printf "${CYAN}│${RESET} %-4s %-35s ${CYAN}│${RESET}\n" "3)" "🔄 Перезагрузить службы (Docker)"
        printf "${CYAN}│${RESET} %-4s %-35s ${CYAN}│${RESET}\n" "4)" "🚪 Изменить SelfSNI порт"
        printf "${CYAN}│${RESET} %-4s %-35s ${CYAN}│${RESET}\n" "5)" "⚙️  Изменить порт ноды"
        printf "${CYAN}│${RESET} %-4s %-35s ${CYAN}│${RESET}\n" "6)" "🔑 Изменить SECRET_KEY"
        echo -e "${CYAN}├──────────────────────────────────────────┤${RESET}"
        printf "${CYAN}│${RESET} ${RED}%-4s %-35s${RESET} ${CYAN}│${RESET}\n" "7)" "🗑️  УДАЛИТЬ ВСЁ"
        printf "${CYAN}│${RESET} %-4s %-35s ${CYAN}│${RESET}\n" "8)" "🚪 Выход"
        echo -e "${CYAN}╰──────────────────────────────────────────╯${RESET}"
        echo ""
        read -r -p " Выберите действие: " act

        case "$act" in
            1) show_info ;;
            2) select_xray_version ;;
            3) 
                info "Перезапуск контейнера..."
                cd "$DIR" && docker compose restart &>/dev/null
                success "Службы успешно перезапущены!"
                sleep 1.5
                ;;
            4) 
                draw_banner
                read -r -p " Введите новый порт SelfSNI: " NP
                if [[ "$NP" =~ ^[0-9]+$ ]]; then
                    # Точечно меняем порт локального прокси
                    sed -i "s/listen 127.0.0.1:[0-9]\+/listen 127.0.0.1:$NP/" "$NGINX_SITE"
                    systemctl restart nginx &>/dev/null
                    success "Порт SelfSNI успешно обновлен на $NP"
                else warn "Ошибка: Порт должен состоять только из цифр!"; fi
                sleep 2
                ;;
            5) 
                draw_banner
                read -r -p " Введите новый порт ноды: " NP
                if [[ "$NP" =~ ^[0-9]+$ ]]; then
                    sed -i "s/NODE_PORT=.*/NODE_PORT=$NP/" "$CONFIG_FILE"
                    info "Перезапуск с новыми параметрами..."
                    cd "$DIR" && docker compose up -d &>/dev/null
                    success "Порт ноды обновлен на $NP"
                else warn "Ошибка: Порт должен состоять только из цифр!"; fi
                sleep 2
                ;;
            6) 
                draw_banner
                read -r -p " Введите новый SECRET_KEY: " NK
                if [[ -n "$NK" ]]; then
                    sed -i "s/SECRET_KEY=.*/SECRET_KEY=$NK/" "$CONFIG_FILE"
                    info "Перезапуск с новыми параметрами..."
                    cd "$DIR" && docker compose up -d &>/dev/null
                    success "Секретный ключ успешно обновлен!"
                else warn "Ошибка: Ключ не может быть пустым"; fi
                sleep 2
                ;;
            7) uninstall_all ;;
            8) clear; exit 0 ;;
            *) warn "Неверный выбор, попробуйте еще раз."; sleep 1 ;;
        esac
    done
}

# ==========================================
# ТОЧКА ВХОДА (Запуск)
# ==========================================

# Проверка прав суперпользователя (root)
if [[ "$EUID" -ne 0 ]]; then 
    echo -e "${RED}✖ Ошибка: Скрипт необходимо запускать от имени root (sudo).${RESET}"
    exit 1
fi

# Если есть файл конфигурации, считаем, что нода установлена, и кидаем в меню.
# Иначе запускаем мастер первичной установки.
if [[ -f "$CONFIG_FILE" ]]; then 
    main_menu
else 
    install_process
fi
