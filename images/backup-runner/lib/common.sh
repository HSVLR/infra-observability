# shellcheck shell=bash
# Shared helpers for run-job and the job scripts in jobs/.

JOBS_DIR=/usr/local/lib/backup/jobs
METRICS_DIR=${METRICS_DIR:-/textfile}
RESTIC_HOST=${RESTIC_HOST:-${HOST_NAME:-$(hostname)}}
export RESTIC_HOST

log() { printf '%s [%s] %s\n' "$(date -Iseconds)" "${JOB:-backup}/${REPO:-}" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_env() {
  local v
  for v; do [[ -n ${!v:-} ]] || die "environment variable $v is not set"; done
}

# Split a "a b,c" style list into words.
words() { tr ',' ' ' <<<"${1:-}"; }

# Read restic --json output on stdin and record data_added of the summary.
record_summary() {
  jq --unbuffered -r 'select(.message_type == "summary") | .data_added' \
    | while read -r n; do echo "$n" >> "${ADDED_FILE:-/dev/null}"; done
}

# restic_stdin <filename> <tag>... -- <command> [args...]
# Stream a command's stdout into a snapshot (no temporary file on disk).
# restic fails the snapshot if the command exits non-zero.
restic_stdin() {
  local name=$1; shift
  local tags=()
  while [[ $1 != -- ]]; do tags+=(--tag "$1"); shift; done
  shift
  log "snapshot $name"
  restic backup --host "$RESTIC_HOST" --json "${tags[@]}" \
    --stdin-filename "$name" --stdin-from-command -- "$@" | record_summary
}

# restic_paths <tag> [restic args...] <path>...
restic_paths() {
  local tag=$1; shift
  log "snapshot $*"
  restic backup --host "$RESTIC_HOST" --json --tag "$tag" "$@" | record_summary
}

# Use one of the local repositories on vm3 (/repos/<name>, key in /secrets/<name>.pass).
use_local_repo() {
  local repo=$1
  [[ -d /repos/$repo ]] || die "repository /repos/$repo not found"
  [[ -f /secrets/$repo.pass ]] || die "password file /secrets/$repo.pass not found"
  export RESTIC_REPOSITORY=/repos/$repo RESTIC_PASSWORD_FILE=/secrets/$repo.pass
  unset RESTIC_PASSWORD
}

# Atomically write a .prom file for node-exporter's textfile collector.
write_prom() {
  local file=$1 tmp
  tmp=$(mktemp "$METRICS_DIR/.tmp.XXXXXX")
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$METRICS_DIR/$file"
}

# write_job_metrics <status 0|1> <start> <end> <bytes_added> <max_age>
write_job_metrics() {
  local status=$1 start=$2 end=$3 added=$4 max_age=$5
  local file="backup_${JOB}_${REPO}.prom" last_success=0
  local l="backup_job=\"$JOB\",repo=\"$REPO\""

  if ((status)); then
    last_success=$end
  elif [[ -f $METRICS_DIR/$file ]]; then
    last_success=$(awk '/^backup_last_success_timestamp_seconds/ {print $2}' "$METRICS_DIR/$file")
    last_success=${last_success:-0}
  fi

  write_prom "$file" <<EOF
# HELP backup_last_status 1 if the last run of the job succeeded, 0 otherwise.
# TYPE backup_last_status gauge
backup_last_status{$l} $status
# HELP backup_last_run_timestamp_seconds End time of the last run.
# TYPE backup_last_run_timestamp_seconds gauge
backup_last_run_timestamp_seconds{$l} $end
# HELP backup_last_success_timestamp_seconds End time of the last successful run (0 = never).
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds{$l} $last_success
# HELP backup_last_duration_seconds Duration of the last run.
# TYPE backup_last_duration_seconds gauge
backup_last_duration_seconds{$l} $((end - start))
# HELP backup_last_added_bytes New (deduplicated) bytes added to the repository by the last run.
# TYPE backup_last_added_bytes gauge
backup_last_added_bytes{$l} $added
# HELP backup_max_age_seconds Allowed age of the last successful run before alerting.
# TYPE backup_max_age_seconds gauge
backup_max_age_seconds{$l} $max_age
EOF
}
