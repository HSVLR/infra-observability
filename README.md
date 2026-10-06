# infra-observability

Monitoring, alerting and backups for our VMs, as code.
The implementation follows the two design documents [Monitoring & Alerting.html](Monitoring%20&%20Alerting.html) and [backup-automation.html](backup-automation.html).

## Architecture

```
             vm1                                 vm2
 ┌────────────────────────────┐      ┌────────────────────────────┐
 │ services (Postgres, Mongo, │      │ services (Postgres, Mongo, │
 │ MinIO, Redis, apps, ...)   │      │ MinIO, Redis, apps, ...)   │
 │                            │      │                            │
 │ agent/                     │      │ agent/                     │
 │  node-exporter   :9100 ◄───┼──┐┌──┼─► node-exporter   :9100    │
 │  cadvisor        :9338 ◄───┼──┤├──┼─► cadvisor        :9338    │
 │  container-health          │  ││  │   container-health         │
 │  backup-runner ────────────┼─┐││┌─┼── backup-runner            │
 └────────────────────────────┘ │││││└────────────────────────────┘
          restic (append-only)  │││││ scrape
                                ▼│││▼
 ┌─────────────────────────────────────────────────────────────────┐
 │ vm3  monitoring-server/                                         │
 │   rest-server :8000  ─►  /srv/restic/{vm1,vm2}  (vm3 local disk)│
 │   backup-maintenance: prune · check · stats · restore-test      │
 │   prometheus  ◄── node / cadvisor / blackbox / rest-server      │
 │   grafana :3000  ─►  dashboards + alerts ─► Telegram            │
 │   blackbox-exporter: ping + HTTP health of vm1/vm2 from outside │
 │ + agent/ (metrics of vm3 itself)                                │
 └─────────────────────────────────────────────────────────────────┘
```

Monitoring runs on a separate VM. If vm1 or vm2 goes down completely, vm3 still sends the "Target down" and "Probe failed" alerts.
The monitoring design document raises this risk in its note about a full VM outage.

### Backups

| Service | Method | Schedule | Retention |
|---|---|---|---|
| PostgreSQL | `pg_dumpall --globals-only` (roles) + `pg_dump -Fc` per database | daily 01:00 | 30 daily, 8 weekly, 6 monthly |
| MongoDB | `mongodump --archive` (+ `--oplog` on a replica set) | daily 01:20 | same |
| MinIO | `mc mirror` to a local staging dir + bucket metadata and IAM export | daily 01:40 | same |
| Files | compose files, configs, certificates from `FILES_SOURCE_HOST_DIR` | daily 03:00 | same |
| Redis | **not backed up**, cache only | — | — |

- Dumps run inside the database container itself (`docker exec`). The `pg_dump` / `mongodump` version therefore always matches the server, and no database credentials are stored in this project.
- Dumps are streamed straight into restic, with no temporary files on disk. Restic handles encryption, compression, deduplication and checksums.
- rest-server runs in **append-only** and **private-repos** mode. vm1 can only access `/vm1/` and cannot delete snapshots, so a compromised VM cannot destroy its own backups. Retention and pruning happen only on vm3.
- Every job exports its result as metrics (`backup_last_status`, `backup_last_success_timestamp_seconds`, duration, bytes added). Alerts fire for failed jobs and for stale backups.
- Once a month, `restore-test` restores the latest dumps into temporary containers and checks them. A backup whose restore has never been tested cannot be trusted.

### Alerts (Grafana-managed, no Alertmanager)

| Alert | Condition | For | Severity |
|---|---|---|---|
| CPU high | > 85% | 10m | warning |
| Memory low | available RAM < 15% | 10m | warning |
| Disk almost full | > 80% | 15m | warning |
| Disk critical | > 90% | 5m | critical |
| Target down | `up == 0` | 3m | critical |
| Probe failed | ping / HTTP health check from vm3 | 3m | critical |
| Container down | critical container stopped or removed | 2m | critical |
| Container unhealthy | healthcheck failing | 2m | critical |
| Container health collector stale | collector stopped reporting | 5m | warning |
| Backup job failed | last run failed | immediately | critical |
| Backup stale | last success older than `--max-age` | immediately | critical |

Recovery ("resolved") messages are sent too. Alerts are grouped by `alertname` and `host`, so one VM outage does not flood the channel.

## Repository layout

```
agent/                     runs on every VM (vm1, vm2 and vm3)
  compose.yaml             node-exporter, cadvisor, container-health, backup-runner
  .env.example
  backup/crontab           backup schedule
  backup/files-exclude.txt
  health-collector/        container running/healthy state → metrics
monitoring-server/         vm3 only
  compose.yaml             prometheus, grafana, blackbox, rest-server, backup-maintenance
  .env.example
  prometheus/              prometheus.yml and targets/*.yml (VM IPs go here)
  grafana/provisioning/    datasource, dashboard provider, alert rules, contact point, policy
  grafana/dashboards/      VM Overview, Docker Containers, Backups
  blackbox/
  maintenance/crontab      prune / check / stats / restore-test
  rest-server/htpasswd     (generated, not in git)
  restic/passwords/        repository keys for vm3 (not in git)
images/backup-runner/      shared image: restic + docker-cli + mc + supercronic, and the jobs
scripts/                   prepare-host.sh, add-restic-user.sh
docs/                      setup guide, restore runbook, firewall, alerting
```

## Setup

**Step-by-step guide for vm3 (and connecting vm1/vm2): [docs/setup-vm3.md](docs/setup-vm3.md).** The short version follows.

Prerequisites on all three VMs: Docker with Compose v2, and a clone of this repository (for example in `/opt/infra-observability`).
The examples use the private IPs `10.0.0.11` (vm1), `10.0.0.12` (vm2) and `10.0.0.13` (vm3).

### 1. vm3: monitoring and backup server

```bash
sudo scripts/prepare-host.sh --server

# set the real VM IPs
vim monitoring-server/prometheus/targets/*.yml

cp monitoring-server/.env.example monitoring-server/.env
vim monitoring-server/.env          # Grafana password, Telegram, REST_SERVER_BIND, RESTORE_TESTS

# one rest-server user + repository key per VM that backs up
scripts/add-restic-user.sh vm1 10.0.0.13
scripts/add-restic-user.sh vm2 10.0.0.13
# keep the printed RESTIC_REPOSITORY / RESTIC_PASSWORD for step 2,
# and store RESTIC_PASSWORD outside the VMs (password manager).

(cd monitoring-server && docker compose up -d --build)

# agent for vm3's own metrics (without backup-runner)
cp agent/.env.example agent/.env
vim agent/.env                      # HOST_NAME=vm3 and COMPOSE_PROFILES= (empty)
(cd agent && docker compose up -d)
```

### 2. vm1 and vm2

```bash
sudo scripts/prepare-host.sh

cp agent/.env.example agent/.env
vim agent/.env
#   HOST_NAME=vm1
#   RESTIC_REPOSITORY / RESTIC_PASSWORD  ← output of add-restic-user.sh
#   PG_CONTAINERS / MONGO_CONTAINERS / MINIO_URL  ← services running on this VM
#   CRITICAL_CONTAINERS                  ← containers that must raise alerts
#   CADVISOR_BIND                        ← this VM's private IP

cd agent
docker compose build
docker compose run --rm backup-runner restic-init     # create the repository on vm3 (once)
docker compose up -d

# first manual backup and check
docker compose exec backup-runner run-job postgres
docker compose exec backup-runner restic snapshots
```

Jobs that are empty in `.env` are skipped automatically and export no metrics or alerts. For example, `MONGO_CONTAINERS=` on a VM without MongoDB skips the MongoDB job.

### 3. Firewall

Ports 9100 and 9338 on vm1/vm2 should be reachable from vm3 only, and port 8000 on vm3 from vm1/vm2 only.
**Ports published by Docker bypass ufw.** See [docs/firewall.md](docs/firewall.md).

### 4. Tests and acceptance (from the design document)

- [ ] Grafana opens and the Prometheus datasource is healthy
- [ ] All targets are UP in Prometheus `Status → Targets`
- [ ] The VM Overview dashboard shows CPU / RAM / disk for vm1, vm2, vm3
- [ ] The Docker Containers dashboard shows containers and their health
- [ ] Grafana → Alerting → Contact points → telegram → **Test** delivers a message
- [ ] Stopping a critical container raises "Container down" after ~2 minutes; starting it again sends "Resolved"
- [ ] High CPU load (`stress-ng --cpu 0 --timeout 15m`) on a test environment raises "CPU high"
- [ ] Stopping node-exporter on a VM raises "Target down"
- [ ] The Backups dashboard shows "ok" for every job
- [ ] `docker compose exec backup-maintenance run-job --max-age 2764800 restore-test vm1` succeeds on vm3
- [ ] Alerts are not repeated excessively

## Day-to-day operations

```bash
# run a job manually (vm1/vm2)
docker compose exec backup-runner run-job postgres|mongodb|minio|files

# run maintenance manually (vm3)
docker compose exec backup-maintenance run-job prune vm1
docker compose exec backup-maintenance run-job check vm1
docker compose exec backup-maintenance run-job restore-test vm1

# logs
docker compose logs -f backup-runner

# targets/*.yml are reloaded automatically. After editing prometheus.yml:
curl -X POST http://127.0.0.1:9090/-/reload
```

Disaster recovery: [docs/restore-runbook.md](docs/restore-runbook.md)

## Next steps (out of phase 1)

- External monitoring of **vm3 itself**, for example a simple health check from an outside service or another VM against Grafana. If vm3 goes down, no alerts are sent at all.
- A second copy of the backups outside vm3 (`restic copy` or rsync to another S3/MinIO). Today a vm3 disk failure loses every backup.
- TLS for rest-server (guide in docs/firewall.md).
- PITR for PostgreSQL (WAL archiving, e.g. pgBackRest or WAL-G).
- postgres_exporter / mongodb_exporter, Loki for logs, Alertmanager, SSL certificate monitoring.
