# Alerting

Everything is defined in `monitoring-server/grafana/provisioning/alerting/`. Grafana loads it on startup:

| File | Content |
|---|---|
| `rules.yaml` | alert rules (groups `vm`, `containers`, `backups`) |
| `contact-points.yaml` | notification channel (Telegram) |
| `notification-policies.yaml` | routing, grouping and repeat intervals |

Provisioned rules cannot be edited in the Grafana UI. Change these files instead, then run `docker compose restart grafana`.

## Telegram

1. Create a bot with `@BotFather` and put its token in `TELEGRAM_BOT_TOKEN`.
2. Add the bot to the target group and send a message there. Then get the chat id from
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and put it in `TELEGRAM_CHAT_ID`. Group ids are negative.
3. In Grafana, open Alerting → Contact points → telegram and click **Test**.

> If vm3 cannot reach `api.telegram.org`, add another receiver (see below).

## Other channels

Add another receiver to `contact-points.yaml`. For example, email:

```yaml
      - uid: email-main
        type: email
        settings:
          addresses: ops@example.com
```

Email also needs SMTP settings, given as `GF_SMTP_*` environment variables in the grafana service.

Or a webhook:

```yaml
      - uid: webhook-main
        type: webhook
        settings:
          url: ${ALERT_WEBHOOK_URL}
```

## Separate channels for warning and critical

Create a second contact point, for example `telegram-critical` with another chat id.
Then, in `notification-policies.yaml`, change the `receiver` of the `severity = critical` route to it.

## Note about `$`

Grafana replaces `$VAR` expressions in provisioning files with environment variables.
For this reason the templates use `.Labels` instead of `$labels`, for example `{{ index .Labels "host" }}`.
