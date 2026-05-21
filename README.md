# remnascrypt

> Быстрый скрипт для установки SelfSNI, выпуска сертификатов Let's Encrypt и запуска `remnawave/node` на Debian/Ubuntu.

[Официальная документация Remnawave](https://docs.rw/)  
[Репозиторий remnawave/node](https://github.com/remnawave/node)

---

## Описание

Этот репозиторий содержит установочный скрипт `remnascrypt.sh`.

Скрипт автоматически:

- устанавливает необходимые зависимости
- определяет внешний IPv4-адрес сервера
- проверяет A-запись домена и сравнивает её с внешним IP сервера
- проверяет доступность портов `80`, `443`, порта SelfSNI и порта ноды
- загружает кастомную заглушку `index.html` из репозитория GitHub
- выпускает сертификат Let's Encrypt через `certbot` по схеме `HTTP-01 webroot`
- настраивает nginx для работы SelfSNI
- создаёт `docker-compose.yml` для `remnawave/node`
- запускает контейнер ноды

---

## Перед установкой

Перед запуском скрипта необходимо сначала создать новую ноду в панели Remnawave.

В панели откройте:

`Nodes` → `Management` → `+`

При создании ноды укажите:

- `IP/Domain` — IP-адрес сервера или домен сервера
- `Node Port` — порт ноды, который вы позже укажете при запуске скрипта
- `SECRET_KEY` — скопируйте из панели, он потребуется скрипту для запуска ноды

После создания ноды сохраните `SECRET_KEY`.

---

## Требования

Перед запуском убедитесь, что:

- используется Debian или Ubuntu
- домен уже направлен на IP вашего сервера через A-запись
- порт `443` свободен
- порт SelfSNI свободен, если вы указываете кастомный через `--selfsni-port`
- выбранный порт ноды свободен
- запуск выполняется от `root`
- сервер имеет доступ в интернет
- порт `80` доступен извне для прохождения проверки Let's Encrypt по `HTTP-01`

> Примечание: если порт `80` уже занят **nginx**, это не проблема, так как скрипт сам настраивает nginx для `webroot`-проверки. Но режим установки без 80/tcp в текущей версии не поддерживается.

---

## Быстрый запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh)
```

---

## Аргументы

Скрипт поддерживает следующий рабочий аргумент:

```bash
--selfsni-port <порт>
```

Также существует зарезервированный, но отключённый аргумент:

```bash
--without-80
```

### `--selfsni-port`

Позволяет указать локальный порт SelfSNI.

По умолчанию используется:

```bash
9000
```

Пример запуска:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh) --selfsni-port 9443
```

### `--without-80`

Флаг присутствует только как заглушка совместимости, но в текущей версии скрипта **отключён**.

Причина: выпуск сертификата реализован через `certbot --webroot`, а значит требуется обычный `HTTP-01` доступ по `80/tcp`.

---

## Что спросит скрипт

Во время выполнения скрипт запросит:

1. Доменное имя
2. Порт для ноды RemnaNode
3. `SECRET_KEY` для ноды

Порт ноды должен совпадать с тем, который был указан при создании ноды в панели Remnawave.

---

## Что устанавливается

Скрипт устанавливает следующие компоненты:

- `curl`
- `nginx`
- `certbot`
- `git`
- `dnsutils`
- `ca-certificates`
- `gnupg`
- `lsb-release`

При необходимости дополнительно устанавливаются:

- `docker`
- `docker-compose-plugin`

> `docker compose` используется в формате Compose v2 plugin, то есть через команду `docker compose`, а не через старую отдельную утилиту `docker-compose`.

---

## Что создаёт и использует скрипт

После успешного выполнения будут созданы и использованы следующие пути:

```text
/var/www/remnascrypt
/var/www/remnascrypt/index.html
/etc/nginx/sites-available/remnascrypt.conf
/etc/nginx/sites-enabled/remnascrypt.conf
/opt/remnanode
/opt/remnanode/docker-compose.yml
/etc/letsencrypt/live/ВАШ_ДОМЕН/fullchain.pem
/etc/letsencrypt/live/ВАШ_ДОМЕН/privkey.pem
```

---

## Кастомная заглушка сайта

Текущая версия скрипта не генерирует HTML через heredoc внутри bash.

Вместо этого она скачивает файл:

```text
https://raw.githubusercontent.com/imdeist/remnascrypt/main/index.html
```

и сохраняет его как:

```text
/var/www/remnascrypt/index.html
```

Это позволяет редактировать заглушку прямо в репозитории без изменения логики установочного скрипта.[web:36][web:39]

---

## Пример `docker-compose.yml`

Скрипт формирует файл такого вида:

```yaml
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
      - NODE_PORT=2272
      - SECRET_KEY=your_secret_key
    volumes:
      - '/etc/letsencrypt:/etc/letsencrypt:ro'
```

---

## Примеры запуска

### Стандартная установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh)
```

### Установка с кастомным портом SelfSNI

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh) --selfsni-port 9443
```

---

## Что делает скрипт по шагам

1. Проверяет запуск от `root`
2. Проверяет, что ОС — Debian или Ubuntu
3. Проверяет аргументы запуска
4. Запрашивает домен, порт ноды и `SECRET_KEY`
5. Определяет внешний IPv4-адрес сервера
6. Устанавливает зависимости
7. Проверяет A-запись домена
8. Проверяет свободные порты
9. Создаёт каталог webroot
10. Скачивает кастомный `index.html` из репозитория GitHub
11. Создаёт временный HTTP-конфиг nginx для `webroot`
12. Выпускает сертификат Let's Encrypt через `HTTP-01`
13. Применяет финальный nginx-конфиг для SelfSNI
14. Устанавливает Docker и Compose plugin при необходимости
15. Создаёт `docker-compose.yml`
16. Запускает контейнер `remnawave/node`

---

## Результат после установки

После завершения скрипт выводит:

- домен
- SelfSNI порт
- порт ноды
- путь к сертификату
- путь к ключу
- значение `Dest`
- значение `SNI`
- путь к `docker-compose.yml`

Пример вывода:

```text
Домен: example.com
SelfSNI порт: 9000
Порт ноды: 2272
Сертификат: /etc/letsencrypt/live/example.com/fullchain.pem
Ключ: /etc/letsencrypt/live/example.com/privkey.pem
Dest: 127.0.0.1:9000
SNI: example.com
Docker compose: /opt/remnanode/docker-compose.yml
```

---

## Проверка после установки

Проверить контейнер:

```bash
docker ps | grep remnanode
```

Посмотреть логи:

```bash
docker compose -f /opt/remnanode/docker-compose.yml logs -f remnanode
```

Проверить конфигурацию nginx:

```bash
nginx -t
```

Проверить статус nginx:

```bash
systemctl status nginx
```

Проверить наличие сертификатов:

```bash
ls -la /etc/letsencrypt/live/your-domain/
```

Проверить таймер автообновления сертификатов:

```bash
systemctl status certbot.timer
```

> В Debian/Ubuntu пакет `certbot` обычно создаёт и активирует `systemd`-таймер для автоматического продления сертификатов.[web:34][web:31]

---

## Возможные проблемы

### Домен не указывает на сервер

Если A-запись домена не совпадает с внешним IP сервера, скрипт завершится с ошибкой.

### Не удалось скачать `index.html`

Скрипт загружает заглушку напрямую с `raw.githubusercontent.com`, поэтому сервер должен иметь доступ к GitHub, а файл должен существовать по указанному пути.[web:33][web:36]

### Порт `443` занят

Если порт `443` уже используется, установка будет остановлена.

### Порт SelfSNI занят

Если указанный SelfSNI порт уже используется, скрипт завершится с ошибкой и попросит выбрать другой.

### Порт ноды занят

Если указанный `Node Port` уже используется, скрипт завершится с ошибкой.

### Порт `80` недоступен

В текущей версии сертификат выпускается через `HTTP-01 webroot`, поэтому порт `80/tcp` должен быть доступен для Let's Encrypt.

### Не работает `docker compose`

На Debian и Ubuntu Compose v2 обычно ставится как plugin для команды `docker compose`, поэтому при его отсутствии скрипт устанавливает пакет `docker-compose-plugin`.[web:32]

### Nginx не принимает конфиг с `http2 on;`

В текущей версии скрипта для совместимости с Debian 12 / nginx 1.22 используется синтаксис:

```nginx
listen 127.0.0.1:9000 ssl http2;
```

Это сделано специально для совместимости со старыми пакетами nginx, где директива `http2 on;` ещё не поддерживается.

### Нода не подключается к панели

Проверьте, что при создании ноды в панели был указан тот же `Node Port`, который вы ввели в скрипте, и что `SECRET_KEY` был скопирован без изменений.

---

## Полезные ссылки

- [Remnawave Docs](https://docs.rw/)
- [remnawave/node](https://github.com/remnawave/node)
- [Let's Encrypt](https://letsencrypt.org/)
- [Certbot](https://certbot.eff.org/)
