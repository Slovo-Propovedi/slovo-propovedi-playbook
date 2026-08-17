# Миграция VPS: 92.63.103.147 → 95.215.56.235 (август 2026)

<sup>Runbook миграции продакшена · stop-and-migrate · согласованный простой</sup>

Runbook для оператора. Все команды выполняются вручную с ноутбука оператора;
root-доступ по SSH есть на обоих серверах. Команды можно копировать как есть.

## Контекст

Перенос продакшена со старого VPS **92.63.103.147** (Ubuntu) на новый
**95.215.56.235** (Debian 13, чистый сервер). Стратегия — **stop-and-migrate**
с согласованным простоем: на время окна сервисы останавливаются, данные
переносятся, DNS переключается в конце.

| Что | Старый VPS | Новый VPS |
| --- | --- | --- |
| Адрес | `92.63.103.147` | `95.215.56.235` |
| ОС | Ubuntu | Debian 13 (чистый сервер) |
| Роль после миграции | резерв (для отката) | прод |

**Что переносится:** данные приложений и инфра-сервисов (БД, MinIO, сертификаты
Traefik).

**Что не переносится:** Forgejo и CI-раннер живут отдельно на
`git.lightnode.ru` — там обновляются только секреты.

**Архитектура:**

- **Приложения** — `slovo-backend` (NestJS), `slovo-frontend` (SPA),
  `slovo-docs` (Swagger UI). Деплой тегом `v*` через Forgejo Actions: SSH
  `root@VPS`, распаковка исходников в `/slovo/<app>/container-src`, запуск
  `scripts/vps-deploy.sh` (идемпотентный, self-provisioning; образы собираются
  на VPS через buildx, registry нет).
- **Инфра-сервисы** — traefik, postgres, pgbouncer, minio, adminer. Управляются
  **этим плейбуком** через systemd (`slovo-*.service`).

**DNS** — у внешнего провайдера; A-записи переключаются в самом конце (Фаза 1,
шаг 9).

## Обзор фаз

| Фаза | Что делаем | Простой? |
| --- | --- | --- |
| Фаза 0 — подготовка | SSH-ключ, inventory, репетиция плейбука, предсинк MinIO, TTL | нет |
| Фаза 1 — окно миграции | stop, дамп БД, дельта MinIO, restore, сертификаты, редеплой, DNS, приёмка | да |
| Откат | старт сервисов на старом VPS + DNS обратно | по необходимости |

---

## Фаза 0 — подготовка (без простоя)

Всё из этой фазы можно и нужно делать заранее, до согласованного окна.

### 0.1 SSH-ключ — используем существующую пару ed25519

**Новая пара не создаётся.** Используем уже существующую
`~/.ssh/id_ed25519`, чей публичный ключ уже является ключом Forgejo на старом
VPS.

Публичный ключ:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICPMHH/h31R0hh7jxlvGTMq/8Q2O8MStlpVZl0t8DjaW egoreast@egoreast-laptop
```

**1. Проверка соответствия локального приватного ключа** — вывод должен
совпасть с публичным ключом выше:

```bash
ssh-keygen -y -f ~/.ssh/id_ed25519
```

**2. Проверка, что это ключ Forgejo на старом VPS:**

```bash
ssh root@92.63.103.147 'cat /root/.ssh/authorized_keys'
```

Публичный ключ из п. 1 должен присутствовать в выводе.

**3. Установка ключа на новый VPS:**

```bash
ssh root@95.215.56.235 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICPMHH/h31R0hh7jxlvGTMq/8Q2O8MStlpVZl0t8DjaW egoreast@egoreast-laptop" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
```

**4. Проверка входа на новый VPS:**

```bash
ssh -i ~/.ssh/id_ed25519 root@95.215.56.235 'uname -a'
```

> [!IMPORTANT]
> Секрет Forgejo **`VPS_SSH_PRIVATE_KEY` не меняется** — приватный ключ тот же.
> Меняется только **`VPS_HOST`** (см. Фаза 1, шаг 6).
>
> Если локального приватного ключа нет (или он не совпадает с Forgejo-ключом) —
> сгенерировать **отдельную пару только для локального ansible**
> (`ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_new` и прописать её в
> `ansible_ssh_private_key_file` или через `ssh-agent`). Forgejo-секрет при
> этом не трогать.

### 0.2 inventory

`inventory/` — **отдельный git-репозиторий** (в этом плейбуке он подключён
подкаталогом; `.gitignore` исключает его из основного репо).

1. В `inventory/hosts` поменять адрес хоста:

   ```diff
   -slovo-propovedi.ru ansible_host=92.63.103.147 ansible_user=root
   +slovo-propovedi.ru ansible_host=95.215.56.235 ansible_user=root
   ```

2. Закоммитить изменение в inventory-репозиторий:

   ```bash
   cd ~/playbooks/slovo-propovedi-playbook/inventory
   git add hosts
   git commit -m "chore: switch ansible_host to new VPS 95.215.56.235"
   git push
   ```

> [!NOTE]
> В `host_vars/` лежат зашифрованные vault-переменные. Они не меняются —
> пароли БД/MinIO и прочие секреты остаются теми же (см. Фаза 1, шаг 6).

### 0.3 Репетиция плейбука на новом VPS

Прогоняем плейбук на чистом сервере ДО окна миграции. Это создаст все
инфра-сервисы, базу и юзера `slovo` с теми же vault-паролями, что и на старом
VPS.

```bash
cd ~/playbooks/slovo-propovedi-playbook
just roles && just setup-all
```

Vault-пароль спросят (используется `--ask-vault-pass`).

> [!NOTE]
> **Известная проблема:** рецепт `setup-all` в `justfile` ссылается на тег
> `ensure-slovo-users-created` удалённой роли. При ошибке запускать напрямую,
> без `just`:
>
> ```bash
> ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start --ask-vault-pass
> ```

> [!IMPORTANT]
> **Риск совместимости:** pinned galaxy-роли (например, `geerlingguy.docker`
> 8.0.0) официально поддерживают Debian ≤ 12, а новый VPS — Debian 13.
> Поэтому репетиция **обязательна ДО окна**. Если роль падает:
>
> - **(а)** поднять версию роли в `requirements.yml` (и закоммитить),
> - **(б)** поставить Docker руками до прогона плейбука,
> - **(в)** крайний случай — переустановить VPS на Debian 12.

**Проверка после репетиции** — все сервисы должны быть `active`:

```bash
ssh root@95.215.56.235 'systemctl is-active slovo-traefik slovo-postgres slovo-pgbouncer slovo-minio slovo-adminer'
```

Ожидаемый вывод — `active` для каждого из пяти сервисов.

### 0.4 Предсинк MinIO (самые тяжёлые данные — аудио)

Аудио — самый большой объём данных, поэтому копируем их заранее. Используем
`tar`-pipe (rsync не используется). **Без `--numeric-ids`**: uid/gid юзера
`slovo` на серверах разные, маппинг идёт по имени.

```bash
ssh root@92.63.103.147 'cd /slovo/minio && tar cf - data' | ssh root@95.215.56.235 'cd /slovo/minio && tar xf -'
ssh root@95.215.56.235 'chown -R slovo:slovo /slovo/minio/data'
```

В окне миграции догоним дельту (Фаза 1, шаг 3 — те же tar-pipe команды).

### 0.5 Прочее

- **Снизить TTL всех A-записей до 300** у DNS-провайдера (чтобы переключение
  в Фазе 1 сработало быстро).
- **Проверить, где лежат секреты Forgejo:** на уровне орги `Slovo_Propovedi`
  или на трёх репозиториях по отдельности (backend/admin/docs) — от этого
  зависит число правок на шаге 6 Фазы 1.

### Чек-лист Фазы 0

- [ ] 0.1 Приватный ключ совпадает с публичным (`ssh-keygen -y`)
- [ ] 0.1 Ключ Forgejo подтверждён на старом VPS
- [ ] 0.1 Ключ установлен на новый VPS, вход работает
- [ ] 0.2 `inventory/hosts` → `95.215.56.235`, коммит в inventory-репо
- [ ] 0.3 Плейбук отработал на новом VPS, 5 сервисов — `active`
- [ ] 0.4 Предсинк MinIO выполнен, `chown -R slovo:slovo` выполнен
- [ ] 0.5 TTL всех A-записей = 300
- [ ] 0.5 Известно, где лежат секреты Forgejo (орга/репо)

---

## Фаза 1 — окно миграции (простой)

Начинаем после согласованного времени простоя. Команды даны в порядке
выполнения; не пропускать шаги.

### 1. Стоп приложений на старом VPS

Postgres **оставляем работать** — он нужен для дампа на следующем шаге.

```bash
ssh root@92.63.103.147 'systemctl stop slovo-backend slovo-frontend slovo-docs slovo-adminer slovo-pgbouncer slovo-minio slovo-traefik'
```

### 2. Дамп БД

```bash
ssh root@92.63.103.147 'docker exec slovo-postgres pg_dump -U slovo slovo' | gzip > ~/slovo-db.sql.gz
ssh root@92.63.103.147 'systemctl stop slovo-postgres'
```

Дамп сохраняется на ноутбуке оператора — после миграции хранить его как
бэкап (см. «Риски и примечания»).

### 3. Финальная дельта MinIO

Догоняем данные, записанные после предсинка. Те же tar-pipe команды, что в
Фазе 0, шаг 0.4:

```bash
ssh root@92.63.103.147 'cd /slovo/minio && tar cf - data' | ssh root@95.215.56.235 'cd /slovo/minio && tar xf -'
ssh root@95.215.56.235 'chown -R slovo:slovo /slovo/minio/data'
```

### 4. Восстановление БД на новом VPS

Плейбук (Фаза 0.3) уже создал базу и юзера `slovo` с теми же vault-паролями.

```bash
ssh root@95.215.56.235 'docker exec slovo-postgres psql -U slovo -d slovo -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"'
gunzip -c ~/slovo-db.sql.gz | ssh root@95.215.56.235 'docker exec -i slovo-postgres psql -U slovo -d slovo -v ON_ERROR_STOP=1'
```

> [!NOTE]
> `ON_ERROR_STOP=1` остановит восстановление при первой ошибке — не игнорировать
> сообщения об ошибках, при них разбираться до продолжения.

### 5. Сертификаты Traefik

Переносим Let's Encrypt-аккаунт и сертификаты со старого VPS, чтобы не ждать
перевыпуска.

```bash
ssh root@92.63.103.147 'cat /slovo/traefik/ssl/acme.json' | ssh root@95.215.56.235 'cat > /slovo/traefik/ssl/acme.json && chmod 600 /slovo/traefik/ssl/acme.json && systemctl restart slovo-traefik'
```

### 6. Секреты Forgejo

Меняется **только `VPS_HOST`** (в репозиториях backend/admin/docs или на орге
`Slovo_Propovedi` — см. Фаза 0.5):

- `VPS_HOST` = `95.215.56.235`
- `VPS_SSH_PRIVATE_KEY` — **не трогаем**
- `VPS_SSH_USER` — **не трогаем**
- Остальные секреты (JWT, пароли БД/MinIO) — **не меняются**, vault те же.

### 7. Редеплой приложений

Перезапустить последний release-workflow в UI Forgejo (секреты читаются при
запуске) или push новых патч-тегов `v*` (backend, frontend, docs).

> [!IMPORTANT]
> Плейбук (Фаза 0.3) должен быть прогнан **ДО** редеплоя. Лейблы бэкенда
> ссылаются на middleware `slovo-rate-limit@file`, который есть только у
> Traefik из плейбука — fallback-Traefik v3.4 из deploy-скрипта его **не
> имеет**.

### 8. Проверка до переключения DNS

Проверяем новый VPS напрямую, подменяя резолвинг через `--resolve`:

```bash
curl --resolve api.slovo-propovedi.ru:443:95.215.56.235 https://api.slovo-propovedi.ru/health
curl --resolve admin-app.slovo-propovedi.ru:443:95.215.56.235 -I https://admin-app.slovo-propovedi.ru
curl --resolve docs.slovo-propovedi.ru:443:95.215.56.235 -I https://docs.slovo-propovedi.ru/openAPI.yaml
```

- `/health` должен ответить `200` с телом от нового бэкенда.
- `-I` должен вернуть `HTTP/2 200` (или `301/302` на HTTPS) для админки и docs.

### 9. DNS

Переключить A-записи на `95.215.56.235` у внешнего провайдера:

| A-запись |
| --- |
| `slovo-propovedi.ru` |
| `www` |
| `api` |
| `admin-app` |
| `docs` |
| `minio-api` |
| `minio-console` |
| `adminer` |

Всего **8 записей**. После изменения дождаться распространения (TTL = 300,
см. Фаза 0.5).

### 10. Приёмка

- [ ] Логин в админку (`admin-app.slovo-propovedi.ru`)
- [ ] Список проповедей отображается
- [ ] **Воспроизведение аудио** — пресайнед URL MinIO, частая жертва миграций
- [ ] Adminer (`adminer.slovo-propovedi.ru`) — вход в БД работает
- [ ] Swagger UI (`docs.slovo-propovedi.ru`) — openAPI.yaml отдаётся

### Чек-лист Фазы 1

- [ ] 1. Приложения на старом VPS остановлены (postgres — работает)
- [ ] 2. Дамп БД на ноутбуке (`~/slovo-db.sql.gz`), postgres остановлен
- [ ] 3. Дельта MinIO догнана, `chown` выполнен
- [ ] 4. БД восстановлена без ошибок (`ON_ERROR_STOP=1`)
- [ ] 5. `acme.json` перенесён, `slovo-traefik` перезапущен
- [ ] 6. В Forgejo изменён только `VPS_HOST`
- [ ] 7. Приложения редеплоены (после плейбука!)
- [ ] 8. Проверка `--resolve` прошла на всех трёх доменах
- [ ] 9. 8 A-записей переключены на `95.215.56.235`
- [ ] 10. Приёмка пройдена (включая воспроизведение аудио)

---

## Откат

Старый VPS **не выключать и не чистить несколько дней** — это единственный
полный бэкап.

Откат = запустить сервисы на старом VPS + вернуть DNS:

```bash
ssh root@92.63.103.147 'systemctl start slovo-traefik slovo-pgbouncer slovo-postgres slovo-minio slovo-adminer slovo-backend slovo-frontend slovo-docs'
```

Затем переключить 8 A-записей обратно на `92.63.103.147`.

> [!WARNING]
> Данные, записанные на новый VPS после переключения DNS, при откате
> теряются (принятое решение). Сертификаты `acme.json` на старом VPS остались
> на месте.

---

## Риски и примечания

- **uid/gid юзера `slovo` различаются между серверами** — tar без
  `--numeric-ids`, маппинг по имени. При сомнениях после любого переноса
  выполнять `chown -R slovo:slovo /slovo/minio/data`.
- **Debian 13 vs galaxy-роли** — pinned роли поддерживают Debian ≤ 12; при
  падении см. Фаза 0.3 (поднять версию / Docker руками / Debian 12).
- **Порядок критичен:** плейбук → редеплой приложений. Бэкенд зависит от
  middleware `slovo-rate-limit@file`, который есть только у playbook-Traefik.
- **PgBouncer слушает 5432** (не 6432), пул — `transaction`.
- **`edoburu/pgbouncer:latest`** — плавающий тег; после переустановки может
  приехать другая версия образа.
- **Бэкап-автоматизации нет** — дамп из окна (`~/slovo-db.sql.gz`) хранить
  отдельно; это единственная копия схемы и данных на момент миграции.