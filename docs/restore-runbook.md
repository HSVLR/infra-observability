# Runbook بازیابی (Restore)

ترتیب بازیابی در زمان خرابی، مطابق سند بکاپ:

1. ساخت VM جدید و نصب Docker
2. clone این مخزن، `scripts/prepare-host.sh` و ساخت `agent/.env` با **همان** `RESTIC_REPOSITORY` و `RESTIC_PASSWORD`
3. restore فایل‌ها (compose، config، certificate)
4. بالا آوردن کانتینرهای دیتابیس با نسخه‌ی سازگار (خالی)
5. restore PostgreSQL و MongoDB
6. Redis: فقط cache است؛ کانتینر خالی بالا بیاید کافی است
7. restore MinIO و policyها
8. بالا آوردن applicationها و بررسی login / خواندن / نوشتن / داده‌های مهم
9. `docker compose up -d` در `agent/` تا jobهای بکاپ دوباره فعال شوند

همه‌ی دستورهای زیر روی VM مقصد و داخل پوشه‌ی `agent/` اجرا می‌شوند. `R` کوتاه‌شده‌ی اجرای restic در ایمیج backup-runner است:

```bash
cd agent
docker compose build backup-runner
R() { docker compose run --rm -T backup-runner restic "$@"; }

R snapshots                       # همه
R snapshots --tag postgres        # فقط postgres
R ls latest --path /postgres-postgres-app.dump
```

> اگر VM اصلی از دست رفته و اسم host جدید فرق دارد، فیلترها را با `--host vm1` بزنید.

## فایل‌ها

```bash
docker compose run --rm -v /:/restore backup-runner \
  restic restore latest --tag files --target /restore/tmp/files-restore
# فایل‌ها در /tmp/files-restore/source/files/... روی host هستند؛ بررسی و کپی کنید.
```

## PostgreSQL

نام فایل‌ها: `postgres-<container>-globals.sql` و `postgres-<container>-<db>.dump`.

```bash
C=postgres            # نام کانتینر postgres جدید
DB=app

# ۱. roleها و tablespaceها
R dump --path /postgres-$C-globals.sql latest /postgres-$C-globals.sql \
  | docker exec -i $C psql -U postgres -d postgres

# ۲. هر دیتابیس
docker exec $C createdb -U postgres $DB
R dump --path /postgres-$C-$DB.dump latest /postgres-$C-$DB.dump \
  | docker exec -i $C pg_restore -U postgres -d $DB --exit-on-error

# بررسی
docker exec $C psql -U postgres -d $DB -c '\dt'
```

برای برگشت به یک روز مشخص به‌جای `latest` شناسه‌ی snapshot را از `R snapshots --tag db:$DB` بردارید.

## MongoDB

```bash
C=mongo
R dump --path /mongodb-$C.archive latest /mongodb-$C.archive \
  | docker exec -i $C sh -c 'mongorestore --archive --drop \
      -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
# اگر MONGO_OPLOG=true بوده: --oplogReplay هم اضافه کنید.
```

## MinIO

```bash
# ۱. بازگرداندن mirror به staging روی host
docker compose run --rm -v /:/restore backup-runner \
  restic restore latest --tag minio --target /restore/tmp/minio-restore

# ۲. آپلود به MinIO جدید
docker run --rm --network host -v /tmp/minio-restore/staging/minio:/m minio/mc sh -c '
  mc alias set dst http://127.0.0.1:9000 ACCESS SECRET &&
  for b in /m/data/*; do mc mb -p dst/$(basename $b) && mc mirror $b dst/$(basename $b); done'

# ۳. متادیتا و IAM (فایل‌های zip در /m/meta)
#   mc admin cluster bucket import dst /m/meta/<...>-bucket-metadata.zip
#   mc admin cluster iam import   dst /m/meta/<...>-iam-info.zip
```

## مستقیم روی vm3

اگر VMها در دسترس نیستند، repoها روی دیسک vm3 هستند و کانتینر `backup-maintenance` به همه دسترسی دارد:

```bash
cd monitoring-server
docker compose exec backup-maintenance sh -c \
  'restic -r /repos/vm1 --password-file /secrets/vm1.pass snapshots'
```

## کلیدها

بدون `RESTIC_PASSWORD` هر repo، بکاپ‌ها **قابل رمزگشایی نیستند**. یک نسخه باید خارج از vm1/vm2/vm3 (password manager یا جای امن آفلاین) باشد.
