# Firewall and network security

| Destination | Port | Allowed from |
|---|---|---|
| vm1, vm2, vm3 | 9100 (node-exporter) | vm3 |
| vm1, vm2, vm3 | 9338 (cAdvisor) | vm3 |
| vm3 | 8000 (rest-server) | vm1, vm2 |
| vm3 | 3000 (Grafana) | admin network / VPN |
| vm3 | 9090 (Prometheus) | localhost only (SSH tunnel) |

## Important: Docker and ufw

Ports that Docker publishes with `ports:` are opened directly in iptables (the `DOCKER` chain).
**ufw rules do not apply to them.** Therefore:

1. Bind published ports to the **private IP** in `.env`:
   - `agent/.env`: `CADVISOR_BIND=46.62.220.45`
   - `monitoring-server/.env`: `REST_SERVER_BIND=77.42.20.237`, and `GRAFANA_BIND` if needed
2. Restrict the allowed sources in the `DOCKER-USER` chain. Each `-I DOCKER-USER 1` inserts at the top,
   so add the DROP rule first and the allow (`RETURN`) rules after it.

On vm1 and vm2, allow cAdvisor from vm3 only:

```bash
sudo iptables -I DOCKER-USER 1 -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 9338 ! -s 77.42.20.237 -j DROP
```

On vm3, allow rest-server from vm1 and vm2 only, and cAdvisor from the local Prometheus container only:

```bash
M="-p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport"
sudo iptables -I DOCKER-USER 1 $M 8000 -j DROP
sudo iptables -I DOCKER-USER 1 $M 8000 -s 95.216.190.53 -j RETURN
sudo iptables -I DOCKER-USER 1 $M 8000 -s 46.62.220.45 -j RETURN
sudo iptables -I DOCKER-USER 1 $M 9338 ! -s 172.16.0.0/12 -j DROP
```

Make the rules persistent, for example with `iptables-persistent` (`sudo netfilter-persistent save`).

node-exporter runs with `network_mode: host`, so normal ufw rules apply to it:

```bash
sudo ufw allow from 77.42.20.237 to any port 9100 proto tcp
```

On vm3, Prometheus runs inside a Docker network and scrapes vm3's own node-exporter through vm3's private IP.
If ufw is enabled, also allow the Docker networks:

```bash
sudo ufw allow from 172.16.0.0/12 to any port 9100 proto tcp
```

## TLS for rest-server (recommended)

Without TLS, the rest-server password travels over plain HTTP. The backup data is still encrypted by restic.
To use TLS with a self-signed certificate:

```bash
# on vm3
cd monitoring-server/rest-server
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout tls.key -out tls.crt -subj "/CN=vm3" \
  -addext "subjectAltName=IP:77.42.20.237"

# monitoring-server/.env
REST_SERVER_EXTRA_OPTIONS=--tls --tls-cert /etc/rest-server/tls.crt --tls-key /etc/rest-server/tls.key
```

Then restart rest-server: `docker compose up -d rest-server`.

On vm1 and vm2:
1. Copy `tls.crt` to `agent/backup/rest-server.crt`.
2. Mount it into backup-runner in `agent/compose.yaml`:
   `- ./backup/rest-server.crt:/etc/backup/rest-server.crt:ro`
3. Update `agent/.env`:

```
RESTIC_REPOSITORY=rest:https://vm1:...@77.42.20.237:8000/vm1/
RESTIC_CACERT=/etc/backup/rest-server.crt
```
