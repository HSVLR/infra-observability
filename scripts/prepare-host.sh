#!/usr/bin/env bash
# Run once (as root) on every VM before "docker compose up".
# Creates the host directories the stacks bind-mount.
#
#   sudo scripts/prepare-host.sh            # vm1 / vm2
#   sudo scripts/prepare-host.sh --server   # vm3
set -Eeuo pipefail

install -d -m 0755 /var/lib/node-exporter/textfile
install -d -m 0700 /var/lib/backup-staging/minio

if [[ ${1:-} == --server ]]; then
  install -d -m 0700 /srv/restic
  touch "$(dirname "$0")/../monitoring-server/rest-server/htpasswd"
fi
echo "done"
