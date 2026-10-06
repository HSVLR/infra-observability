# Setup guide: vm3 (monitoring and backup server)

This guide brings up the whole server side on vm3, step by step:
Prometheus, Grafana with alerting, the blackbox exporter, the restic rest-server and the backup maintenance jobs.
It also runs the agent stack on vm3 so that vm3 monitors itself.

When you finish, vm3 is ready and waiting for vm1 and vm2. Connecting them is covered in step 12.

Throughout this guide:

| VM | Role | Private IP (example) |
|---|---|---|
| vm1 | application VM | `46.62.220.45` |
| vm2 | application VM | `95.216.190.53` |
| vm3 | monitoring + backup server | `77.42.20.237` |

Replace these IPs with your real ones everywhere.

---

## 0. Requirements

**Hardware for vm3.** The monitoring stack is small. Most of the disk goes to backups.

| Resource | Minimum | Notes |
|---|---|---|
| CPU | 2 vCPU | |
| RAM | 4 GB | Prometheus + Grafana + restic prune |
| Disk for the OS and Prometheus | 30 GB | 30 days of metrics for 3 VMs is a few GB |
| Disk for backups (`/srv/restic`) | ≥ 2× the size of all data being backed up | ideally a separate disk |

**Network.**
- vm3 → vm1/vm2 on TCP 9100 and 9338 (scraping), plus ICMP (ping)
- vm1/vm2 → vm3 on TCP 8000 (backups)
- your workstation → vm3 on TCP 3000 (Grafana) and 22 (SSH)
- vm3 → internet: Docker Hub, `gcr.io`, `github.com`, `dl.min.io` (image build) and `api.telegram.org` (alerts)

**Access.** A user with `sudo` on vm3.

---

## 1. Install Docker

Skip this step if `docker compose version` already works.

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
# log out and back in, then:
docker version
docker compose version     # must be v2.x
```

Also install the small tools used below:

```bash
sudo apt-get update && sudo apt-get install -y git openssl curl jq
```

## 2. (Recommended) Mount a dedicated backup disk

If vm3 has a separate disk for backups, mount it on `/srv/restic` so that backups cannot fill up the OS disk.
For example, with a new empty disk `/dev/sdb`:

```bash
sudo mkfs.ext4 -L restic /dev/sdb
sudo mkdir -p /srv/restic
echo 'LABEL=restic /srv/restic ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mount -a
df -h /srv/restic
```

> **Warning:** `mkfs` erases the disk. Check the device name with `lsblk` first.

If you use a different path, set `RESTIC_DATA_HOST_DIR` in step 6 accordingly.

## 3. Get the code

```bash
sudo mkdir -p /opt/infra-observability
sudo chown "$USER": /opt/infra-observability
git clone <REPO_URL> /opt/infra-observability
cd /opt/infra-observability
```

All further commands run from `/opt/infra-observability` unless stated otherwise.

## 4. Prepare host directories

```bash
sudo scripts/prepare-host.sh --server
```

This creates:
- `/var/lib/node-exporter/textfile`: metrics written by the container-health collector and the backup jobs
- `/srv/restic`: restic repositories (mode 0700)
- `monitoring-server/rest-server/htpasswd`: empty for now, filled in step 7

## 5. Configure the scrape targets

Edit the files in `monitoring-server/prometheus/targets/` and replace the example IPs:

| File | Content |
|---|---|
| `node.yml` | node-exporter on vm1, vm2, vm3 (port 9100) |
| `cadvisor.yml` | cAdvisor on vm1, vm2, vm3 (port 9338) |
| `icmp.yml` | ping targets: vm1, vm2 |
| `http.yml` | optional HTTP health endpoints of your services |

Keep the `host` labels (`vm1`, `vm2`, `vm3`). The dashboards and alerts depend on them.

Example `http.yml`, if your API on vm1 has a health endpoint:

```yaml
- targets: ["http://46.62.220.45:8080/health"]
  labels: { host: vm1, service: api }
```

## 6. Configure the server `.env`

```bash
cp monitoring-server/.env.example monitoring-server/.env
chmod 600 monitoring-server/.env
vim monitoring-server/.env
```

Set at least the following:

| Variable | Value |
|---|---|
| `GRAFANA_ADMIN_PASSWORD` | a strong password (`openssl rand -base64 18`) |
| `GRAFANA_ROOT_URL` | `http://77.42.20.237:3000` (or your DNS name) |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | see [alerting.md](alerting.md#telegram) |
| `REST_SERVER_BIND` | `77.42.20.237` (vm3's private IP; see [firewall.md](firewall.md)) |
| `RESTIC_DATA_HOST_DIR` | `/srv/restic` unless you changed it in step 2 |
| `RESTORE_TESTS` | which dumps the monthly restore test checks (see below) |
| `RESTORE_PG_IMAGE`, `RESTORE_MONGO_IMAGE` | the same major versions as production |

`RESTORE_TESTS` lists one entry per dump, separated by spaces:

```
<repo>/postgres/<container>/<database>
<repo>/mongodb/<container>
```

For example, if vm1 runs a postgres container called `postgres` with database `app`, and vm2 runs a mongo container called `mongo`:

```
RESTORE_TESTS=vm1/postgres/postgres/app vm2/mongodb/mongo
```

You can leave it at the example value now and correct it once you know the container names on vm1/vm2.

## 7. Create restic credentials for vm1 and vm2

Run this once per VM that will send backups to vm3:

```bash
scripts/add-restic-user.sh vm1 77.42.20.237
scripts/add-restic-user.sh vm2 77.42.20.237
```

Each run does three things:
- adds a user to `monitoring-server/rest-server/htpasswd`; that user can only reach its own repository `/<name>/`
- writes the repository encryption key to `monitoring-server/restic/passwords/<name>.pass`, which vm3 needs for prune/check/restore-test
- prints two lines for that VM's `agent/.env`:

```
RESTIC_REPOSITORY=rest:http://vm1:<http-password>@77.42.20.237:8000/vm1/
RESTIC_PASSWORD=<repository-key>
```

Then:
1. Save both outputs somewhere safe. You need them in step 12.
2. **Store every `RESTIC_PASSWORD` outside vm1/vm2/vm3**, for example in a password manager. If vm3 dies together with this key, the backups cannot be decrypted.

> The repository name must equal the `HOST_NAME` that the VM will use in its `agent/.env`. The restore test relies on this.

## 8. (Optional) Enable TLS on rest-server

Without TLS, the rest-server HTTP password travels in clear text inside your private network. The backup data itself is always encrypted by restic.
To enable TLS, follow [firewall.md → TLS for rest-server](firewall.md#tls-for-rest-server-recommended) now, before step 9.

## 9. Start the server stack

```bash
cd /opt/infra-observability/monitoring-server
docker compose up -d --build
docker compose ps
```

The first run builds the `backup-runner` image (restic, docker CLI, MinIO client, supercronic), which takes a minute or two.
All five services should be `running`:

```
prometheus  grafana  blackbox-exporter  rest-server  backup-maintenance
```

If one keeps restarting, check its logs with `docker compose logs <service>`. See also [Troubleshooting](#troubleshooting).

## 10. Start the agent stack on vm3

vm3 monitors itself with the same agent stack as vm1/vm2, but without the backup runner.

```bash
cd /opt/infra-observability
cp agent/.env.example agent/.env
chmod 600 agent/.env
vim agent/.env
```

Set:

```
HOST_NAME=vm3
COMPOSE_PROFILES=
CADVISOR_BIND=77.42.20.237
CRITICAL_CONTAINERS=prometheus,grafana,rest-server
```

`COMPOSE_PROFILES` must be **empty** on vm3, so that backup-runner is not started.
`CRITICAL_CONTAINERS` uses the real container names, which you can see with `docker ps --format '{{.Names}}'`.
Compose names them like `observability-server-prometheus-1`. Use those full names.

```bash
cd agent
docker compose up -d
docker compose ps        # node-exporter, cadvisor, container-health
```

## 11. Firewall on vm3

Allow only what is needed. Details and the reasons are in [firewall.md](firewall.md).

```bash
sudo ufw allow OpenSSH
sudo ufw allow from <admin-network> to any port 3000 proto tcp      # Grafana
sudo ufw allow from 172.16.0.0/12 to any port 9100 proto tcp        # Prometheus container → node-exporter on vm3
sudo ufw enable

```

rest-server (8000) and cAdvisor (9338) are Docker-published ports, so ufw does not filter them.
Restrict them in the `DOCKER-USER` chain instead. Each `-I DOCKER-USER 1` inserts at the top, so the
DROP rule is added first and the allow rules end up above it:

```bash
M="-p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport"

# rest-server: only vm1 and vm2
sudo iptables -I DOCKER-USER 1 $M 8000 -j DROP
sudo iptables -I DOCKER-USER 1 $M 8000 -s 95.216.190.53 -j RETURN
sudo iptables -I DOCKER-USER 1 $M 8000 -s 46.62.220.45 -j RETURN

# cAdvisor on vm3: only the local Prometheus container (Docker networks)
sudo iptables -I DOCKER-USER 1 $M 9338 ! -s 172.16.0.0/12 -j DROP

sudo iptables -L DOCKER-USER -n --line-numbers
```

Make the rules persistent, for example with `sudo apt-get install iptables-persistent && sudo netfilter-persistent save`.

## 12. Verify vm3

Run these checks on vm3.

**Grafana**

```bash
curl -s http://127.0.0.1:3000/api/health      # "database": "ok"
```

Open `http://77.42.20.237:3000` and log in with `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`. Then check:
- *Connections → Data sources → Prometheus → Test* shows a success message
- *Dashboards → Infrastructure* contains **VM Overview**, **Docker Containers** and **Backups**
- *Alerting → Alert rules* lists the groups `vm`, `containers` and `backups`
- *Alerting → Contact points → telegram → Test* delivers a message to Telegram

**Prometheus targets**

Prometheus listens on localhost only:

```bash
curl -s http://127.0.0.1:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.labels.host)\t\(.health)\t\(.lastError)"'
```

Expected at this point:

| job | vm3 | vm1 / vm2 |
|---|---|---|
| prometheus, rest-server | up | — |
| node, cadvisor | up | **down** until their agents run |
| blackbox-icmp | — | up (ping works) |

From your workstation, you can open the Prometheus UI through an SSH tunnel:
`ssh -L 9090:127.0.0.1:9090 vm3`, then browse to `http://localhost:9090`.

**rest-server**

```bash
docker compose -f monitoring-server/compose.yaml logs rest-server | tail
# expect: "Authentication enabled", "Append only mode enabled", "Private repositories enabled"
```

**Container health metrics**

```bash
cat /var/lib/node-exporter/textfile/container_health.prom | head
```

**Maintenance scheduler**

```bash
docker compose -f monitoring-server/compose.yaml logs backup-maintenance | head
# supercronic lists the jobs from maintenance/crontab
```

Until vm1/vm2 have initialised their repositories, the maintenance jobs log `repository /repos/vm1 not found` and fail.
Finish step 13 before the first scheduled run at 04:30. Otherwise you get "Backup job failed" alerts for those jobs.

## 13. Connect vm1 and vm2

On **each** of vm1 and vm2, as root or with sudo:

```bash
# Docker as in step 1, code as in step 3, then:
cd /opt/infra-observability
sudo scripts/prepare-host.sh

cp agent/.env.example agent/.env
chmod 600 agent/.env
vim agent/.env
```

| Variable | vm1 example |
|---|---|
| `HOST_NAME` | `vm1` (same as the repository name from step 7) |
| `COMPOSE_PROFILES` | `backup` |
| `CADVISOR_BIND` | `46.62.220.45` |
| `CRITICAL_CONTAINERS` | the important containers on this VM |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD` | output of step 7 for this VM |
| `PG_CONTAINERS` | postgres container names on this VM, or empty |
| `MONGO_CONTAINERS`, `MONGO_OPLOG` | mongo container names, or empty |
| `MINIO_URL`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | e.g. `http://host.docker.internal:9000`, or empty |
| `FILES_SOURCE_HOST_DIR` | the directory with compose files and configs, e.g. `/opt` |

Then start the stack and run the first backups:

```bash
sudo ufw allow from 77.42.20.237 to any port 9100 proto tcp
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 9338 --ctdir ORIGINAL ! -s 77.42.20.237 -j DROP

cd agent
docker compose build
docker compose run --rm backup-runner restic-init       # creates /srv/restic/vm1 on vm3
docker compose up -d

# first backup of every configured job
for j in postgres mongodb minio files; do docker compose exec backup-runner run-job $j; done
docker compose exec backup-runner restic snapshots
```

Jobs whose settings are empty print `not configured on this host, skipping`.

## 14. Final verification on vm3

Back on vm3:

```bash
cd /opt/infra-observability/monitoring-server

ls /srv/restic                                   # vm1  vm2

# run each maintenance job once instead of waiting for the schedule
for r in vm1 vm2; do
  docker compose exec backup-maintenance run-job stats "$r"
  docker compose exec backup-maintenance run-job prune "$r"
  docker compose exec backup-maintenance run-job --max-age 691200 check "$r"
  docker compose exec backup-maintenance run-job --max-age 2764800 restore-test "$r"
done
```

Every job ends with `finished in …s`. Then confirm in Grafana:
- all Prometheus targets are **up** (step 12 command)
- **VM Overview** shows vm1, vm2 and vm3
- **Docker Containers** shows the containers of all three VMs
- **Backups** shows every job with status **ok**

Finally, run the acceptance tests from the [README](../README.md#4-tests-and-acceptance-from-the-design-document).
For example, stop a critical container on vm1 and check that "Container down" and then "Resolved" arrive in Telegram.

---

## Updating

```bash
cd /opt/infra-observability && git pull

cd monitoring-server && docker compose up -d --build     # vm3
cd ../agent && docker compose up -d --build              # every VM
```

| Change | What to run |
|---|---|
| `prometheus/targets/*.yml` | nothing, picked up automatically |
| `prometheus/prometheus.yml` | `curl -X POST http://127.0.0.1:9090/-/reload` |
| Grafana provisioning, dashboards or alert rules | `docker compose restart grafana` |
| `maintenance/crontab` or `backup/crontab` | `docker compose restart backup-maintenance` (vm3) or `docker compose restart backup-runner` (vm1/vm2) |
| new VM to back up | step 7 for it, then add `stats/prune/check/restore-test` lines to `maintenance/crontab` |

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `grafana` exits with `set GRAFANA_ADMIN_PASSWORD` | `.env` missing or the variable is empty |
| `rest-server` restarts and logs about the htpasswd file | `monitoring-server/rest-server/htpasswd` does not exist. Run `scripts/prepare-host.sh --server` |
| restic: `401 Unauthorized` | wrong user or password in `RESTIC_REPOSITORY`, or rest-server was not restarted after `add-restic-user.sh` |
| restic: `403 Forbidden` on `/vm1/` | the URL path does not start with the user name (private repos) |
| restic: `wrong password or no key found` | `RESTIC_PASSWORD` does not match the key in `restic/passwords/<vm>.pass` |
| node/cadvisor target `down` with "context deadline exceeded" | firewall on vm1/vm2, or `CADVISOR_BIND` uses a different IP than `targets/cadvisor.yml` |
| node target of **vm3 itself** down | ufw blocks the Docker network. Allow `172.16.0.0/12` to port 9100 (step 11) |
| `blackbox-icmp` always fails | ICMP blocked between vm3 and vm1/vm2 |
| `prune` fails with "repository is already locked" | a client backup was still running. Move the client schedule earlier, or check for a stuck backup |
| Telegram test fails | wrong token or chat id, or vm3 cannot reach `api.telegram.org`. Use another receiver ([alerting.md](alerting.md)) |
| No "Backup stale" alert although a job never ran | a job that has never run exports no metric. Run every job once manually (steps 13–14) |
