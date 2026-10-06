#!/usr/bin/env bash
# Run on vm3. Create the credentials for a VM that will back up to vm3:
#   - an htpasswd user for rest-server (can only access /<name>/, append-only)
#   - the repository encryption password, stored for vm3's maintenance jobs
# Prints the lines to put into agent/.env on that VM.
#
#   scripts/add-restic-user.sh vm1 [vm3-private-ip]
set -Eeuo pipefail

name=${1:?usage: $0 <vm-name> [vm3-ip]}
vm3_ip=${2:-<VM3_IP>}
[[ $name =~ ^[a-z0-9-]+$ ]] || { echo "name must match [a-z0-9-]+" >&2; exit 1; }

root=$(cd "$(dirname "$0")/.." && pwd)
htpasswd_file=$root/monitoring-server/rest-server/htpasswd
pass_file=$root/monitoring-server/restic/passwords/$name.pass

touch "$htpasswd_file"
if grep -q "^$name:" "$htpasswd_file"; then
  echo "user '$name' already exists in $htpasswd_file" >&2
  exit 1
fi
[[ -e $pass_file ]] && { echo "$pass_file already exists" >&2; exit 1; }

http_pass=$(openssl rand -hex 24)
repo_pass=$(openssl rand -hex 32)

docker run --rm httpd:2.4-alpine htpasswd -nbB "$name" "$http_pass" | sed '/^$/d' >> "$htpasswd_file"
chmod 0644 "$htpasswd_file"
(umask 077 && printf '%s' "$repo_pass" > "$pass_file")

cat <<MSG
User '$name' created. Restart rest-server to be sure it is picked up:
  (cd monitoring-server && docker compose restart rest-server)

Put these lines into agent/.env on $name:

RESTIC_REPOSITORY=rest:http://$name:$http_pass@$vm3_ip:8000/$name/
RESTIC_PASSWORD=$repo_pass

!! Also store RESTIC_PASSWORD in your password manager, OFF these VMs.
   Without it the backups cannot be decrypted.
MSG
