#!/bin/sh
# Export docker container state (running / healthcheck) as Prometheus metrics
# through node-exporter's textfile collector. cAdvisor does not expose the
# docker health status and drops stopped containers, so we collect it here.
#
#   docker_container_running{name,critical}    1 running, 0 otherwise
#   docker_container_unhealthy{name,critical}  1 healthcheck reports unhealthy
#   docker_container_health_info{name,status}  healthy|unhealthy|starting|none
#
# Containers listed in CRITICAL_CONTAINERS but missing entirely are reported
# as running=0 so that "docker compose down" also raises an alert.
set -eu

OUT_DIR=/textfile
OUT=$OUT_DIR/container_health.prom
INTERVAL=${INTERVAL:-30}
CRITICAL=" $(echo "${CRITICAL_CONTAINERS:-}" | tr ',' ' ') "

is_critical() {
  case "$CRITICAL" in *" $1 "*) echo true ;; *) echo false ;; esac
}

collect() {
  work=$(mktemp -d)
  # errexit is off inside "collect || ...", so check explicitly.
  if ! docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' > "$work/ps"; then
    rm -rf "$work"
    return 1
  fi

  seen=" "
  while IFS='|' read -r name state status; do
    [ -n "$name" ] || continue
    seen="$seen$name "
    crit=$(is_critical "$name")
    running=0; [ "$state" = running ] && running=1
    case "$status" in
      *"(healthy)"*) health=healthy ;;
      *"(unhealthy)"*) health=unhealthy ;;
      *"(health: starting)"*) health=starting ;;
      *) health=none ;;
    esac
    unhealthy=0; [ "$health" = unhealthy ] && unhealthy=1
    echo "docker_container_running{name=\"$name\",critical=\"$crit\"} $running" >> "$work/running"
    echo "docker_container_unhealthy{name=\"$name\",critical=\"$crit\"} $unhealthy" >> "$work/unhealthy"
    echo "docker_container_health_info{name=\"$name\",status=\"$health\"} 1" >> "$work/info"
  done < "$work/ps"

  for name in $CRITICAL; do
    case "$seen" in *" $name "*) ;; *)
      echo "docker_container_running{name=\"$name\",critical=\"true\"} 0" >> "$work/running" ;;
    esac
  done

  {
    echo "# HELP docker_container_running 1 if the container is running."
    echo "# TYPE docker_container_running gauge"
    cat "$work/running" 2>/dev/null || true
    echo "# HELP docker_container_unhealthy 1 if the container healthcheck reports unhealthy."
    echo "# TYPE docker_container_unhealthy gauge"
    cat "$work/unhealthy" 2>/dev/null || true
    echo "# HELP docker_container_health_info Docker health status of the container."
    echo "# TYPE docker_container_health_info gauge"
    cat "$work/info" 2>/dev/null || true
    echo "# HELP docker_container_collector_last_run_timestamp_seconds Last successful collection."
    echo "# TYPE docker_container_collector_last_run_timestamp_seconds gauge"
    echo "docker_container_collector_last_run_timestamp_seconds $(date +%s)"
  } > "$work/out"

  chmod 0644 "$work/out"
  mv -f "$work/out" "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
  rm -rf "$work"
}

while true; do
  collect || echo "$(date -Iseconds) container-health: collection failed" >&2
  sleep "$INTERVAL"
done
