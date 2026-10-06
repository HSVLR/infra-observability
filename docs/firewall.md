# Firewall و امنیت شبکه

| مقصد | پورت | فقط از |
|---|---|---|
| vm1، vm2، vm3 | 9100 (node-exporter) | vm3 |
| vm1، vm2، vm3 | 9338 (cAdvisor) | vm3 |
| vm3 | 8000 (rest-server) | vm1، vm2 |
| vm3 | 3000 (Grafana) | شبکه‌ی ادمین‌ها / VPN |
| vm3 | 9090 (Prometheus) | فقط localhost (SSH tunnel) |

## نکته‌ی مهم: Docker و ufw

پورت‌هایی که Docker با `ports:` publish می‌کند مستقیم در iptables (زنجیره‌ی `DOCKER`) باز می‌شوند و **قوانین ufw روی آن‌ها اعمال نمی‌شود**.
برای همین:

1. در `.env` پورت‌ها را به **IP خصوصی** bind کنید:
   - `agent/.env` ← `CADVISOR_BIND=10.0.0.11`
   - `monitoring-server/.env` ← `REST_SERVER_BIND=10.0.0.13` و در صورت نیاز `GRAFANA_BIND`
2. برای محدود کردن مبدأ، از زنجیره‌ی `DOCKER-USER` استفاده کنید. مثال روی vm1 (cAdvisor فقط از vm3):

```bash
iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 9338 --ctdir ORIGINAL ! -s 10.0.0.13 -j DROP
```

node-exporter با `network_mode: host` اجرا می‌شود، پس ufw معمولی روی آن کار می‌کند:

```bash
ufw allow from 10.0.0.13 to any port 9100 proto tcp
```

روی vm3، Prometheus داخل شبکه‌ی Docker است و node-exporter خود vm3 را از طریق IP خصوصی vm3 scrape می‌کند؛
اگر ufw فعال است، ترافیک شبکه‌ی Docker را هم مجاز کنید:

```bash
ufw allow from 172.16.0.0/12 to any port 9100 proto tcp
```

## TLS برای rest-server (توصیه‌شده)

رمز rest-server و داده‌ها (داده‌ها خودشان توسط restic رمز شده‌اند) روی HTTP ساده منتقل می‌شوند. برای TLS با certificate self-signed:

```bash
# روی vm3
cd monitoring-server/rest-server
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout tls.key -out tls.crt -subj "/CN=vm3" \
  -addext "subjectAltName=IP:10.0.0.13"

# monitoring-server/.env
REST_SERVER_EXTRA_OPTIONS=--tls --tls-cert /etc/rest-server/tls.crt --tls-key /etc/rest-server/tls.key
```

روی vm1/vm2: فایل `tls.crt` را در `agent/backup/rest-server.crt` کپی کنید، در `agent/compose.yaml` به backup-runner اضافه کنید
(`- ./backup/rest-server.crt:/etc/backup/rest-server.crt:ro`) و در `agent/.env`:

```
RESTIC_REPOSITORY=rest:https://vm1:...@10.0.0.13:8000/vm1/
RESTIC_CACERT=/etc/backup/rest-server.crt
```
