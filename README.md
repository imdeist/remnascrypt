# remnascrypt

> Быстрый скрипт для установки SelfSNI, выпуска сертификатов Let's Encrypt и запуска `remnawave/node` на Debian/Ubuntu с возможностью обновления ядра Xray.

[Официальная документация Remnawave](https://docs.rw/)

[Репозиторий remnawave/node](https://github.com/remnawave/node)

---

## Что нового (Xray Core)

Теперь скрипт позволяет опционально установить кастомную версию ядра **Xray-core**. При запуске скрипт предложит ввести версию (например, `26.5.9`).

* Если вы введете версию — скрипт скачает, распакует и пробросит это ядро в контейнер.
* Если оставите поле пустым — будет использоваться стандартное ядро, встроенное в образ ноды.

---

## Описание

Этот репозиторий содержит установочный скрипт `remnascrypt.sh`, который автоматизирует подготовку сервера:

* Установка всех необходимых зависимостей (Docker, Nginx, Certbot).
* Валидация домена и доступности портов.
* Выпуск SSL-сертификатов Let's Encrypt (`HTTP-01` challenge).
* Настройка Nginx с поддержкой Proxy Protocol для корректной работы с нодой.
* Гибкая конфигурация `docker-compose.yml` (монтирование сертификатов и опциональное монтирование Xray).
* Сетевая оптимизация (BBR).

---

## Что спросит скрипт

Во время выполнения скрипт запросит:

1. **Доменное имя:** (A-запись должна указывать на IP сервера).
2. **Порт для ноды RemnaNode:** (По умолчанию `2272`).
3. **SECRET_KEY:** (Ключ, созданный в панели управления Remnawave).
4. **Версия ядра xray:** (Оставьте поле пустым, если хотите использовать версию по умолчанию из образа).

---

## Универсальное монтирование

Для обеспечения работоспособности на любом домене, скрипт использует статическое монтирование сертификатов в `docker-compose.yml`:

```yaml
volumes:
  - '/etc/letsencrypt/live/$DOMAIN/fullchain.pem:/etc/letsencrypt/live/fullchain.pem:ro'
  - '/etc/letsencrypt/live/$DOMAIN/privkey.pem:/etc/letsencrypt/live/privkey.pem:ro'
  - '/etc/letsencrypt/archive:/etc/letsencrypt/archive:ro'
  # Дополнительно, если выбрана версия Xray:
  - ./xray/xray:/usr/local/bin/xray

```

Это позволяет вам использовать одни и те же пути в настройках ноды вне зависимости от имени домена.

---

## Быстрый запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/imdeist/remnascrypt/main/remnascrypt.sh)

```

---

## Что устанавливается

* **Системные:** `curl`, `nginx`, `certbot`, `git`, `dnsutils`, `ca-certificates`, `gnupg`, `lsb-release`, `unzip`.
* **Контейнеризация:** `docker`, `docker-compose-plugin`.
* **Сеть:** Настройка `sysctl` для включения **BBR** и увеличения лимитов TCP-буферов.

---

## Проверка после установки

Посмотреть логи ноды:

```bash
docker compose -f /opt/remnanode/docker-compose.yml logs -f remnanode

```

Проверить версию Xray внутри контейнера (если вы её монтировали):

```bash
docker exec remnanode /usr/local/bin/xray version

```

---

## Полезные ссылки

* [Remnawave Docs](https://docs.rw/)
* [Xray-core Releases](https://github.com/XTLS/Xray-core/releases)
* [Let's Encrypt](https://letsencrypt.org/)
