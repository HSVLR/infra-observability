# Backup runner: restic + docker cli + rclone + supercronic.
# Used on vm1/vm2 (backup jobs) and on vm3 (prune / check / restore-test).
ARG RESTIC_VERSION=0.17.3
ARG RCLONE_VERSION=1.75.1

# rclone reads MinIO buckets over the S3 API (static binary).
FROM rclone/rclone:${RCLONE_VERSION} AS rclone

FROM restic/restic:${RESTIC_VERSION}

ARG SUPERCRONIC_VERSION=v0.2.33

# The architecture is taken from the image itself (x86_64 or aarch64), so the
# build works on both amd64 and ARM VMs.
RUN apk add --no-cache bash coreutils curl docker-cli flock jq tzdata \
 && case "$(apk --print-arch)" in \
      x86_64)  arch=amd64 ;; \
      aarch64) arch=arm64 ;; \
      *) echo "unsupported architecture $(apk --print-arch)" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${arch}" \
 && chmod +x /usr/local/bin/supercronic \
 && /usr/local/bin/supercronic -test /dev/null

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY lib/ /usr/local/lib/backup/
COPY bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/* /usr/local/lib/backup/jobs/*

ENV RESTIC_CACHE_DIR=/cache \
    METRICS_DIR=/textfile

ENTRYPOINT []
# Absolute path: as PID 1 supercronic re-executes itself (zombie reaping)
# via argv[0], which fails for a bare name.
CMD ["/usr/local/bin/supercronic", "-passthrough-logs", "/etc/backup/crontab"]
