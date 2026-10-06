# Alerting

همه‌چیز در `monitoring-server/grafana/provisioning/alerting/` تعریف شده و Grafana هنگام start آن را بارگذاری می‌کند:

| فایل | محتوا |
|---|---|
| `rules.yaml` | قوانین Alert (گروه‌های vm، containers، backups) |
| `contact-points.yaml` | کانال ارسال (Telegram) |
| `notification-policies.yaml` | مسیریابی، گروه‌بندی و فاصله‌ی تکرار |

قوانین provision‌شده در UI قابل ویرایش نیستند؛ تغییرات را در همین فایل‌ها بدهید و `docker compose restart grafana` کنید.

## Telegram

1. با `@BotFather` یک bot بسازید و token را در `TELEGRAM_BOT_TOKEN` بگذارید.
2. bot را به گروه موردنظر اضافه کنید، یک پیام بفرستید و chat id را از
   `https://api.telegram.org/bot<TOKEN>/getUpdates` بردارید (برای گروه‌ها منفی است) ← `TELEGRAM_CHAT_ID`.
3. در Grafana → Alerting → Contact points → telegram → **Test**.

> اگر vm3 به api.telegram.org دسترسی ندارد، یک receiver دیگر اضافه کنید.

## کانال‌های دیگر

به `contact-points.yaml` یک receiver دیگر اضافه کنید، مثلاً:

```yaml
      - uid: email-main
        type: email
        settings:
          addresses: ops@example.com
```

(برای email تنظیمات SMTP را با متغیرهای `GF_SMTP_*` در compose بدهید.)

```yaml
      - uid: webhook-main
        type: webhook
        settings:
          url: ${ALERT_WEBHOOK_URL}
```

## کانال جدا برای Warning و Critical

یک contact point دوم بسازید (مثلاً `telegram-critical` با chat id دیگر) و در `notification-policies.yaml`
`receiver` مسیر `severity = critical` را به آن تغییر دهید.

## نکته درباره‌ی `$`

Grafana در فایل‌های provisioning عبارت‌های `$VAR` را با متغیرهای محیطی جایگزین می‌کند؛
برای همین در templateها به‌جای `$labels` از `.Labels` استفاده شده است (`{{ index .Labels "host" }}`).
