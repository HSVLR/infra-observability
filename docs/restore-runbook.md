# Restore runbook

Order of recovery after a failure, as defined in the backup design document:

1. Create a new VM and install Docker.
2. Clone this repository, run `scripts/prepare-host.sh` and create `agent/.env` with the **same** `RESTIC_REPOSITORY` and `RESTIC_PASSWORD` as before.
3. Restore files (compose files, configs, certificates).
4. Start empty database containers with compatible versions.
5. Restore PostgreSQL and MongoDB.
6. Redis is a cache only, so starting an empty container is enough.
7. Restore MinIO objects, then recreate its users and bucket policies.
8. Start the applications and verify login, reads, writes and important data.
9. Run `docker compose up -d` in `agent/` so that the backup jobs are active again.

All commands below run on the target VM, inside `agent/`. `R` is shorthand for running restic in the backup-runner image:

```bash
cd agent
docker compose build backup-runner
R() { docker compose run --rm -T backup-runner restic "$@"; }

R snapshots                       # all snapshots
R snapshots --tag postgres        # postgres only
R ls latest --path /postgres-postgres-app.dump
```

> If the original VM is lost and the new host has a different name, add `--host vm1` to the filters.

## Files

```bash
docker compose run --rm -v /:/restore backup-runner \
  restic restore latest --tag files --target /restore/tmp/files-restore
# The files are in /tmp/files-restore/source/files/... on the host. Review them, then copy them into place.
```

## PostgreSQL

File names are `postgres-<container>-globals.sql` and `postgres-<container>-<db>.dump`.

```bash
C=postgres            # name of the new postgres container
DB=app

# 1. roles and tablespaces
R dump --path /postgres-$C-globals.sql latest /postgres-$C-globals.sql \
  | docker exec -i $C psql -U postgres -d postgres

# 2. each database
docker exec $C createdb -U postgres $DB
R dump --path /postgres-$C-$DB.dump latest /postgres-$C-$DB.dump \
  | docker exec -i $C pg_restore -U postgres -d $DB --exit-on-error

# check
docker exec $C psql -U postgres -d $DB -c '\dt'
```

To go back to a specific day, use a snapshot ID from `R snapshots --tag db:$DB` instead of `latest`.

## MongoDB

```bash
C=mongo
R dump --path /mongodb-$C.archive latest /mongodb-$C.archive \
  | docker exec -i $C sh -c 'mongorestore --archive --drop \
      -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
# If MONGO_OPLOG=true was used, add --oplogReplay.
```

## MinIO

The snapshot contains one folder per bucket under `/staging/minio/`. Users and bucket policies are not in the
backup; recreate them from your notes or compose files.

```bash
# 1. restore the buckets to a folder on the host
docker compose run --rm -v /:/restore backup-runner \
  restic restore latest --tag minio --target /restore/tmp/minio-restore

# 2. upload them into the new MinIO (each folder becomes a bucket)
docker compose run --rm -v /tmp/minio-restore/staging/minio:/restore:ro \
  -e RCLONE_CONFIG_MINIO_TYPE=s3 -e RCLONE_CONFIG_MINIO_PROVIDER=Minio \
  -e RCLONE_CONFIG_MINIO_ENDPOINT=http://host.docker.internal:9000 \
  -e RCLONE_CONFIG_MINIO_ACCESS_KEY_ID=<access-key> \
  -e RCLONE_CONFIG_MINIO_SECRET_ACCESS_KEY=<secret-key> \
  backup-runner sh -c 'for b in /restore/*/; do b=$(basename "$b"); rclone copy "/restore/$b" "minio:$b"; done'
```

> The MinIO server image is no longer published on Docker Hub. Keep a copy of the image you run today, so
> that you can start MinIO again on a new VM: `docker save <minio-image> | gzip > minio-image.tar.gz`
> (and store the file outside the VM, or include its folder in `FILES_SOURCE_HOST_DIR`).

## Directly on vm3

If vm1 or vm2 is unreachable, the repositories are still on vm3's disk. The `backup-maintenance` container can read all of them:

```bash
cd monitoring-server
docker compose exec backup-maintenance sh -c \
  'restic -r /repos/vm1 --password-file /secrets/vm1.pass snapshots'
```

## Keys

Without a repository's `RESTIC_PASSWORD`, its backups **cannot be decrypted**. Keep a copy outside vm1, vm2 and vm3, in a password manager or a safe offline place.
