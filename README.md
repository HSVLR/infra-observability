# infra-observability

مانیتورینگ، Alerting و بکاپ برای VMها، به‌صورت **as code**.
پیاده‌سازی بر اساس دو سند طراحی [Monitoring & Alerting.html](Monitoring%20&%20Alerting.html) و [backup-automation.html](backup-automation.html) است.

## معماری

```
            vm1                                vm2
 ┌──────────────────────────┐      ┌──────────────────────────┐
 │ سرویس‌ها (Postgres، Mongo، │      │ سرویس‌ها (Postgres، Mongo، │
 │ MinIO، Redis، app، ...)    │      │ MinIO، Redis، app، ...)    │
 │                           │      │                            │
 │ agent/                    │      │ agent/                     │
 │  node-exporter   :9100 ◄──┼──┐┌──┼─► node-exporter   :9100     │
 │  cadvisor        :9338 ◄──┼──┤├──┼─► cadvisor        :9338     │
 │  container-health         │  ││  │   container-health         │
 │  backup-runner ───────────┼─┐││┌─┼── backup-runner            │
 └──────────────────────────┘ │││││ └──────────────────────────┘
          restic (append-only)│││││ scrape
                              ▼│││▼
 ┌───────────────────────────────────────────────────────────────┐
 │ vm3  monitoring-server/                                        │
 │   rest-server :8000  ─►  /srv/restic/{vm1,vm2}  (دیسک vm3)      │
 │   backup-maintenance: prune · check · stats · restore-test     │
 │   prometheus  ◄── node / cadvisor / blackbox / rest-server     │
 │   grafana :3000  ─►  Dashboard + Alert ─► Telegram             │
 │   blackbox-exporter: ping و HTTP health از بیرون vm1/vm2        │
 │ + agent/ (برای متریک‌های خود vm3)                              │
 └───────────────────────────────────────────────────────────────┘
```

چون مانیتورینگ روی VM جداگانه است، اگر vm1 یا vm2 کامل از کار بیفتد، Alert «Target down» و «Probe failed» از vm3 ارسال می‌شود
(همان «نکته درباره خرابی کامل VM» در سند مانیتورینگ).

### بکاپ

| سرویس | روش | زمان‌بندی | نگهداری |
|---|---|---|---|
| PostgreSQL | `pg_dumpall --globals-only` (roleها) + `pg_dump -Fc` برای هر دیتابیس | روزانه ۰۱:۰۰ | ۳۰ روزانه، ۸ هفتگی، ۶ ماهانه |
| MongoDB | `mongodump --archive` (+ `--oplog` اگر replica set باشد) | روزانه ۰۱:۲۰ | همان |
| MinIO | `mc mirror` به staging محلی + export متادیتای bucketها و IAM | روزانه ۰۱:۴۰ | همان |
| فایل‌ها | compose، config، certificateها از `FILES_SOURCE_HOST_DIR` | روزانه ۰۳:۰۰ | همان |
| Redis | **بکاپ نمی‌شود** — فقط cache است | — | — |

- dumpها با `docker exec` داخل خود کانتینر دیتابیس گرفته می‌شوند، پس نسخه‌ی `pg_dump` / `mongodump` همیشه با سرور یکی است و رمز دیتابیس در این پروژه نیست.
- خروجی مستقیم (stream) وارد restic می‌شود؛ فایل موقت روی دیسک ساخته نمی‌شود. restic رمزنگاری، فشرده‌سازی، deduplication و checksum را انجام می‌دهد.
- rest-server در حالت **append-only** و **private-repos** است: vm1 فقط به `/vm1/` دسترسی دارد و نمی‌تواند snapshotها را پاک کند. اگر vm1 هک شود، بکاپ‌هایش سالم می‌مانند. پاک‌کردن بر اساس retention فقط روی خود vm3 انجام می‌شود.
- هر job وضعیتش را به‌صورت متریک (`backup_last_status`، `backup_last_success_timestamp_seconds`، مدت، حجم) ثبت می‌کند و برای «ناموفق» و «قدیمی شدن بکاپ» Alert وجود دارد.
- ماهی یک‌بار `restore-test` آخرین dumpها را در کانتینر موقت restore و بررسی می‌کند. بکاپی که restore آن تست نشده باشد، قابل اعتماد نیست.

### Alertها (Grafana-managed، بدون Alertmanager)

| Alert | شرط | مدت | شدت |
|---|---|---|---|
| CPU high | > ۸۵٪ | ۱۰ دقیقه | warning |
| Memory low | RAM آزاد < ۱۵٪ | ۱۰ دقیقه | warning |
| Disk almost full | > ۸۰٪ | ۱۵ دقیقه | warning |
| Disk critical | > ۹۰٪ | ۵ دقیقه | critical |
| Target down | `up == 0` | ۳ دقیقه | critical |
| Probe failed | ping / HTTP health از vm3 | ۳ دقیقه | critical |
| Container down | کانتینر critical متوقف یا حذف شده | ۲ دقیقه | critical |
| Container unhealthy | healthcheck ناموفق | ۲ دقیقه | critical |
| Container health collector stale | collector گزارش نمی‌دهد | ۵ دقیقه | warning |
| Backup job failed | آخرین اجرا ناموفق | فوری | critical |
| Backup stale | آخرین موفقیت قدیمی‌تر از `--max-age` | فوری | critical |

پیام Recovery هم ارسال می‌شود. Alertها بر اساس `alertname` و `host` گروه می‌شوند تا خرابی یک VM سیل پیام نسازد.

## ساختار پروژه

```
agent/                     روی همه‌ی VMها (vm1، vm2 و vm3)
  compose.yaml             node-exporter، cadvisor، container-health، backup-runner
  .env.example
  backup/crontab           زمان‌بندی بکاپ‌ها
  backup/files-exclude.txt
  health-collector/        وضعیت running/healthy کانتینرها → متریک
monitoring-server/         فقط روی vm3
  compose.yaml             prometheus، grafana، blackbox، rest-server، backup-maintenance
  .env.example
  prometheus/              prometheus.yml و targets/*.yml (IPها اینجا)
  grafana/provisioning/    datasource، dashboard provider، alert rules، contact point، policy
  grafana/dashboards/      VM Overview، Docker Containers، Backups
  blackbox/
  maintenance/crontab      prune / check / stats / restore-test
  rest-server/htpasswd     (ساخته می‌شود، در git نیست)
  restic/passwords/        کلید repoها برای vm3 (در git نیست)
images/backup-runner/      ایمیج مشترک: restic + docker-cli + mc + supercronic و jobها
scripts/                   prepare-host.sh، add-restic-user.sh
docs/                      restore runbook، firewall، alerting
```

## راه‌اندازی

پیش‌نیاز روی هر سه VM: Docker و Docker Compose v2، و clone همین مخزن (مثلاً در `/opt/infra-observability`).
در مثال‌ها IPهای خصوصی `10.0.0.11` (vm1)، `10.0.0.12` (vm2) و `10.0.0.13` (vm3) فرض شده‌اند.

### ۱. vm3 — سرور مانیتورینگ و بکاپ

```bash
sudo scripts/prepare-host.sh --server

# IP واقعی VMها
vim monitoring-server/prometheus/targets/*.yml

cp monitoring-server/.env.example monitoring-server/.env
vim monitoring-server/.env          # رمز Grafana، Telegram، REST_SERVER_BIND، RESTORE_TESTS

# برای هر VM که بکاپ می‌گیرد: کاربر rest-server + کلید repo
scripts/add-restic-user.sh vm1 10.0.0.13
scripts/add-restic-user.sh vm2 10.0.0.13
# خروجی (RESTIC_REPOSITORY / RESTIC_PASSWORD) را نگه دارید برای مرحله ۲
# و RESTIC_PASSWORD را جایی خارج از VMها (password manager) ذخیره کنید.

(cd monitoring-server && docker compose up -d --build)

# agent برای متریک‌های خود vm3 (بدون backup-runner)
cp agent/.env.example agent/.env
vim agent/.env                      # HOST_NAME=vm3 و COMPOSE_PROFILES= (خالی)
(cd agent && docker compose up -d)
```

### ۲. vm1 و vm2

```bash
sudo scripts/prepare-host.sh

cp agent/.env.example agent/.env
vim agent/.env
#   HOST_NAME=vm1
#   RESTIC_REPOSITORY / RESTIC_PASSWORD  ← خروجی add-restic-user.sh
#   PG_CONTAINERS / MONGO_CONTAINERS / MINIO_URL  ← سرویس‌هایی که روی همین VM هستند
#   CRITICAL_CONTAINERS                  ← کانتینرهایی که باید Alert بدهند
#   CADVISOR_BIND                        ← IP خصوصی همین VM

cd agent
docker compose build
docker compose run --rm backup-runner restic-init     # ساخت repo روی vm3 (یک‌بار)
docker compose up -d

# اولین بکاپ دستی و بررسی
docker compose exec backup-runner run-job postgres
docker compose exec backup-runner restic snapshots
```

jobهایی که در `.env` خالی‌اند (مثلاً `MONGO_CONTAINERS=` روی VMی که Mongo ندارد) خودکار رد می‌شوند و متریک/Alert ندارند.

### ۳. Firewall

پورت‌های 9100 و 9338 روی vm1/vm2 فقط از vm3، و پورت 8000 روی vm3 فقط از vm1/vm2 باز باشد.
**پورت‌های publish‌شده‌ی Docker از ufw عبور می‌کنند** — جزئیات در [docs/firewall.md](docs/firewall.md).

### ۴. تست و پذیرش (از سند طراحی)

- [ ] Grafana باز می‌شود و datasource Prometheus سبز است
- [ ] در `Status → Targets` پرومتئوس همه‌ی targetها UP هستند
- [ ] داشبورد VM Overview برای vm1، vm2، vm3 CPU / RAM / Disk نشان می‌دهد
- [ ] داشبورد Docker Containers کانتینرها و وضعیت healthشان را نشان می‌دهد
- [ ] در Grafana → Alerting → Contact points، روی telegram «Test» بزنید و پیام برسد
- [ ] یک کانتینر critical را stop کنید ← Alert «Container down» بعد از ~۲ دقیقه، و بعد از start پیام Resolved
- [ ] مصرف CPU بالا (`stress-ng --cpu 0 --timeout 15m`) روی محیط تست ← Alert «CPU high»
- [ ] node-exporter یک VM را stop کنید ← «Target down»
- [ ] داشبورد Backups برای همه‌ی jobها «ok» نشان می‌دهد
- [ ] `docker compose exec backup-maintenance run-job --max-age 2764800 restore-test vm1` روی vm3 موفق است
- [ ] Alertها تکراری و بیش از حد ارسال نمی‌شوند

## کارهای روزمره

```bash
# اجرای دستی هر job (vm1/vm2)
docker compose exec backup-runner run-job postgres|mongodb|minio|files

# اجرای دستی روی vm3
docker compose exec backup-maintenance run-job prune vm1
docker compose exec backup-maintenance run-job check vm1
docker compose exec backup-maintenance run-job restore-test vm1

# لاگ‌ها
docker compose logs -f backup-runner

# بعد از تغییر targets/*.yml نیازی به restart نیست. بعد از تغییر prometheus.yml:
curl -X POST http://127.0.0.1:9090/-/reload
```

بازیابی در زمان خرابی: [docs/restore-runbook.md](docs/restore-runbook.md)

## مراحل بعدی (خارج از فاز اول)

- مانیتورینگ بیرونی **خود vm3** (مثلاً یک healthcheck ساده از سرویس خارجی/VM دیگر روی Grafana) — اگر vm3 بیفتد، هیچ Alertی ارسال نمی‌شود.
- کپی دوم بکاپ‌ها خارج از vm3 (`restic copy` یا rsync به یک S3/MinIO دیگر). الان یک خرابی دیسک vm3 همه‌ی بکاپ‌ها را می‌برد.
- TLS برای rest-server (راهنما در docs/firewall.md).
- PITR برای PostgreSQL (آرشیو WAL، مثلاً با pgBackRest/WAL-G).
- postgres_exporter / mongodb_exporter، Loki برای لاگ، Alertmanager، مانیتورینگ SSL certificate.
