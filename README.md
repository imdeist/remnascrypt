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
- предлагает на выбор визуальное оформление (лендинг) для вашего сервера из динамической коллекции [capsite](https://github.com/imdeist/capsite)
- выпускает сертификат Let's Encrypt через `certbot` по схеме `HTTP-01 webroot`
- настраивает nginx для работы SelfSNI
- опционально устанавливает кастомное ядро Xray
- создаёт `docker-compose.yml` для `remnawave/node`
- оптимизирует скорость подключения
- запускает контейнер ноды

---

## Кастомизация внешнего вида

При запуске скрипт автоматически подключается к [репозиторию с шаблонами](https://github.com/imdeist/capsite) и выводит список доступных визуальных оформлений (лендингов). Вы можете выбрать понравившийся вариант, и скрипт автоматически скачает и установит его как `index.html` на ваш сервер. Это позволяет брендировать ваш узел буквально в один клик.

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

### `--selfsni-port`

Позволяет указать локальный порт SelfSNI (по умолчанию `9000`).

Пример:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh) --selfsni-port 8484

```

---

## Что спросит скрипт

Во время выполнения скрипт запросит:

1. **Доменное имя**
2. **Порт для ноды RemnaNode**
3. **SECRET_KEY** для ноды
4. **Версия ядра Xray:** (оставьте поле пустым для использования стандартного ядра из образа, либо введите версию, например `26.5.9`).
5. **Выбор дизайна:** номер из списка доступных шаблонов лендинга.

---

## Что устанавливается

Скрипт устанавливает следующие компоненты:
`curl`, `nginx`, `certbot`, `git`, `dnsutils`, `ca-certificates`, `gnupg`, `lsb-release`, `unzip`, `jq` (для обработки списка шаблонов), а также `docker` и `docker-compose-plugin`.

---

## Что создаёт и использует скрипт

После успешного выполнения будут созданы:

* `/var/www/remnascrypt/` — webroot для сертификатов и выбранного лендинга
* `/opt/remnanode/` — рабочая директория ноды
* `/opt/remnanode/docker-compose.yml` — конфигурация контейнера
* `/opt/remnanode/xray/` — (опционально) установленное ядро Xray

---

## Пример `docker-compose.yml`

Скрипт формирует файл с универсальным монтированием сертификатов и (если выбрано) ядра Xray:

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
      - '/etc/letsencrypt/live/$DOMAIN/fullchain.pem:/etc/letsencrypt/live/fullchain.pem:ro'
      - '/etc/letsencrypt/live/$DOMAIN/privkey.pem:/etc/letsencrypt/live/privkey.pem:ro'
      - '/etc/letsencrypt/archive:/etc/letsencrypt/archive:ro'
      - ./xray/xray:/usr/local/bin/xray

```

---

## Что делает скрипт по шагам

1. Проверка `root` и ОС.
2. Ввод параметров и (опционально) загрузка версии Xray.
3. Установка зависимостей.
4. Проверка DNS и доступности портов.
5. **Выбор и загрузка дизайна лендинга.**
6. Настройка Nginx и выпуск сертификата через `certbot`.
7. Установка Docker.
8. Генерация `docker-compose.yml` и применение оптимизаций ядра (BBR).
9. Запуск контейнера.

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

Проверить версию Xray (если устанавливали):

```bash
docker exec remnanode /usr/local/bin/xray version

```

---

## Возможные проблемы

* **Домен не указывает на сервер:** Скрипт завершится с ошибкой.
* **Порты заняты:** Если 443 или указанные порты заняты, установка прервется.
* **Нода не подключается:** Убедитесь, что `SECRET_KEY` верный, а `Node Port` соответствует настройкам в панели Remnawave.

---

## Полезные ссылки

* [Remnawave Docs](https://docs.rw/)
* [remnawave/node](https://github.com/remnawave/node)
* [Коллекция шаблонов Capsite](https://www.google.com/url?sa=E&source=gmail&q=https://github.com/imdeist/capsite)
* [Let's Encrypt](https://letsencrypt.org/)
* [Certbot](https://certbot.eff.org/)

```

```
