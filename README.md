# remnascrypt

Скрипты для быстрой установки SelfSNI, выпуска сертификатов Let's Encrypt и запуска `remnawave/node` на Debian/Ubuntu.

## Описание

Этот репозиторий содержит установочный скрипт `remnascrypt.sh`.

Скрипт позволяет автоматически:

- проверить запуск от `root`
- проверить, что система — Debian или Ubuntu
- установить необходимые зависимости
- проверить A-запись домена и внешний IP сервера
- проверить доступность портов `443`, `80` и порта ноды
- выпустить сертификат Let's Encrypt через `certbot`
- настроить nginx под SelfSNI
- создать `docker-compose.yml` для `remnawave/node`
- запустить контейнер ноды

## Перед установкой

Перед запуском скрипта необходимо сначала создать новую ноду в панели Remnawave. В официальной инструкции по установке Remnawave Node сказано, что нода сначала добавляется в панели через раздел `Nodes` → `Management`, где нужно заполнить форму и обратить внимание на поле `Node Port`. [web:1]

При создании ноды в панели укажите:

- `IP/Domain` — IP-адрес сервера или домен сервера
- `Node Port` — порт ноды, который вы позже укажете при запуске скрипта
- `SECRET_KEY` — скопируйте из панели, он потребуется скрипту для запуска ноды

После создания ноды сохраните или скопируйте `SECRET_KEY`. Для Remnawave Node сейчас используются два основных параметра: `NODE_PORT` и `SECRET_KEY`. [web:8][web:127][web:128]

## Требования

Перед запуском убедитесь, что:

- у вас Debian или Ubuntu
- домен уже направлен на IP вашего сервера через A-запись
- порт `443` свободен
- порт `80` свободен
- выбранный порт ноды свободен
- запуск выполняется от `root`
- сервер имеет доступ в интернет

## Быстрый запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh)
```

## Аргументы

Скрипт поддерживает следующие аргументы:

```bash
--selfsni-port <порт>
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

Флаг зарезервирован, но в текущей версии установщика не поддерживается.

Текущая версия скрипта выпускает сертификат через `http-01`, поэтому для установки нужен свободный порт `80`.

## Что спросит скрипт

Во время выполнения скрипт запросит:

1. Доменное имя
2. Порт для ноды RemnaNode
3. `SECRET_KEY` для ноды

Порт ноды должен совпадать с тем, который был указан при создании ноды в панели Remnawave. `SECRET_KEY` также нужно брать из панели ноды. [web:1][web:8]

## Что устанавливается

Скрипт устанавливает следующие компоненты:

- `curl`
- `nginx`
- `certbot`
- `python3-certbot-nginx`
- `git`
- `dnsutils`
- `ca-certificates`
- `docker`
- `docker-compose-plugin`

## Что создаёт скрипт

После успешного выполнения будут созданы и использованы следующие пути:

```text
/opt/remnanode
/opt/remnanode/docker-compose.yml
/etc/nginx/sites-enabled/sni.conf
/etc/letsencrypt/live/ВАШ_ДОМЕН/fullchain.pem
/etc/letsencrypt/live/ВАШ_ДОМЕН/privkey.pem
/var/www/html
```

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

## Примеры запуска

### Стандартная установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh)
```

### Установка с кастомным портом SelfSNI

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh) --selfsni-port 9443
```

## Что делает скрипт по шагам

1. Проверяет запуск от `root`
2. Проверяет, что ОС — Debian или Ubuntu
3. Проверяет аргументы запуска
4. Запрашивает домен, порт ноды и `SECRET_KEY`
5. Получает внешний IP сервера
6. Проверяет A-запись домена
7. Проверяет свободные порты
8. Устанавливает зависимости
9. Скачивает случайный шаблон сайта
10. Выпускает сертификат Let's Encrypt через `http-01`
11. Настраивает nginx для SelfSNI
12. Устанавливает Docker и Docker Compose plugin
13. Создаёт `docker-compose.yml`
14. Запускает контейнер `remnawave/node`

## Результат после установки

После завершения скрипт выводит:

- путь к сертификату
- путь к ключу
- значение `Dest`
- значение `SNI`
- путь к `docker-compose.yml`

Пример вывода:

```text
Сертификат: /etc/letsencrypt/live/example.com/fullchain.pem
Ключ: /etc/letsencrypt/live/example.com/privkey.pem
В качестве Dest укажите: 127.0.0.1:9000
В качестве SNI укажите: example.com
Docker compose: /opt/remnanode/docker-compose.yml
```

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

Проверить наличие сертификатов:

```bash
ls -la /etc/letsencrypt/live/your-domain/
```

## Возможные проблемы

### Домен не указывает на сервер

Если A-запись домена не совпадает с внешним IP сервера, скрипт завершится с ошибкой.

### Порт `443` занят

Если порт `443` уже используется, выпуск сертификата и работа SelfSNI будут невозможны.

### Порт `80` занят

В текущей версии скрипта сертификат выпускается через `http-01`, поэтому порт `80` должен быть свободен.

### Не работает `docker compose`

На Debian и Ubuntu Compose v2 часто ставится как plugin для команды `docker compose`, поэтому иногда нужен отдельный пакет `docker-compose-plugin`.

### Нода не подключается к панели

Проверьте, что при создании ноды в панели был указан тот же `Node Port`, который вы ввели в скрипте, и что `SECRET_KEY` был скопирован без изменений. В инструкции Remnawave Node отдельно указано, что поле `Node Port` используется для внутренних API-запросов от панели к ноде. [web:1]
