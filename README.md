# 🚀 VPS Bootstrap Script (Ubuntu 24.04)

Автоматический скрипт для **первичной настройки VPS** на Ubuntu 24.04.  
Ориентирован на **неопытных пользователей**: минимум вопросов и безопасные настройки по умолчанию.

---

## ✨ Что делает `bootstrap.sh`

После запуска скрипт **поэтапно**:

- 👤 создаёт нового пользователя и добавляет его в группу `sudo`;
- 🔑 добавляет **публичный SSH-ключ** новому пользователю;
- 🔐 настраивает SSH:
  - меняет порт SSH (по умолчанию `4422`);
  - отключает вход под `root`;
  - отключает парольную аутентификацию;
  - включает вход по SSH-ключу;
- 🛡️ включает и настраивает:
  - `UFW` (firewall);
  - `fail2ban`;
  - `Docker`;
  - панель `3x-ui` (Docker-образ из репозитория `mhsanaei/3x-ui`);
  - `Telemt` proxy в Docker Compose (официальный образ `ghcr.io/telemt/telemt:latest`);
  - автоматический `nftables` limiter для входящих SYN к контейнеру Telemt;
  - полезные alias в `~/.bash_aliases` нового пользователя;
- 🧾 выводит итоговое резюме с новыми параметрами доступа;
- 📄 пишет лог установки в `/var/log/bootstrap_start2.log`.

> Скрипт настроен на запуск с минимумом вопросов.  
> По умолчанию включены UFW, fail2ban, Docker, 3x-ui, Telemt и добавление alias.

---

## ✅ Требования

- **Ubuntu 24.04**
- Вы уже подключены к серверу по SSH **под пользователем `root`**
- На сервере есть доступ в интернет

---

## ⚡ Быстрый старт

Запустите на сервере:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/birdset/vps-bootstrap/main/bootstrap.sh)
```

Скрипт запросит:

- имя нового пользователя;
- публичный SSH-ключ (одной строкой);
- сайт для `TELEMT_TLS_DOMAIN` (по умолчанию `petrovich.ru`).

После завершения выдаст команду для входа вида:

```bash
ssh -p 4422 <user>@<IP_СЕРВЕРА>
```

---

## 🧩 Что изменяется на сервере

Основные изменения:

- SSH перенастраивается (порт, root login, пароль);
- включается `UFW` и открываются:
  - новый SSH-порт;
  - `22/tcp` и `443/tcp` (по умолчанию);
  - дополнительные порты `2053/tcp` и `20553/tcp`;
  - порт Telemt (по умолчанию `1243/tcp`);
- ставится `fail2ban`;
- ставится `Docker`, `docker compose` plugin и `nftables`;
- поднимается контейнер панели `3x-ui` (`ghcr.io/mhsanaei/3x-ui:latest`);
- создаётся конфигурация Telemt в `/opt/telemt/config/config.toml`;
- поднимается Telemt контейнер `telemt-proxy` через `/opt/telemt/docker-compose.yml`;
- создаются скрипты настройки лимитера:
  - `/usr/local/sbin/telemt-in-syn-limit.sh`;
  - `/usr/local/sbin/telemt-in-syn-watch.sh`;
- включается systemd service `telemt-in-syn-watch.service`;
- добавляются alias в `~/.bash_aliases` нового пользователя.

Telemt использует официальный Docker-образ `ghcr.io/telemt/telemt:latest`. Внешний порт сервера по умолчанию `1243`, внутри контейнера Telemt слушает `443`.

---

## ⚙️ Автоматические настройки Telemt

В конфиг Telemt добавляются базовые настройки из инструкции `telemt-tune`:

```toml
[general]
tg_connect = 10
client_mss_bulk = "1400"

[timeouts]
client_handshake = 15
client_keepalive = 60
```

Для Docker-контейнера `telemt-proxy` также настраивается inbound SYN limiter через `nftables`:

- таблица: `inet telemt_limit`;
- chain: `forward`;
- контейнерный IP берётся автоматически через `docker inspect`;
- правило применяется к `tcp dport 443` внутри контейнера;
- лимит: `1/second`, `burst 1`, `timeout 60s`;
- watcher service обновляет правило, если Docker выдаст контейнеру новый IP.

Проверка после установки:

```bash
systemctl status telemt-in-syn-watch.service --no-pager
nft list chain inet telemt_limit forward
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' telemt-proxy
```

---

## ♻️ Откат всех изменений (`unbootstrap.sh`)

Если нужно **полностью удалить** внесённые изменения и вернуться к состоянию,
когда на сервере есть только `root`, используйте `unbootstrap.sh`.

### ▶️ Запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/birdset/vps-bootstrap/main/unbootstrap.sh)
```

Скрипт:

- 🗑️ удаляет созданного пользователя;
- 🔧 восстанавливает конфигурацию SSH (из бэкапа, если он есть);
- 🧹 отключает и удаляет UFW, fail2ban и Docker;
- 🧯 отключает `telemt-in-syn-watch.service`, удаляет scripts и таблицу `inet telemt_limit`;
- 🐳 удаляет контейнеры `telemt-proxy` и `3x-ui`;
- 📁 удаляет директории данных `Telemt` (`/opt/telemt`) и `3x-ui` (`/etc/x-ui`, `/usr/local/x-ui`);
- 📄 удаляет логи bootstrap.

Если запускать не от root — скрипт **временно включает root login**, попросит установить пароль и перезапустится от root.

### 👥 Если пользователей несколько

Можно указать имя пользователя явно:

```bash
bash unbootstrap.sh --user <имя>
```

---

## 📚 Логи

- Лог установки: `/var/log/bootstrap_start2.log`
- Лог отката: `/var/log/unbootstrap.log`
