# Backup runner: restic + docker cli + minio client + supercronic.
# Used on vm1/vm2 (backup jobs) and on vm3 (prune / check / restore-test).
ARG RESTIC_VERSION=0.17.3
FROM restic/restic:${RESTIC_VERSION}

ARG SUPERCRONIC_VERSION=v0.2.33
ARG TARGETARCH=amd64

RUN apk add --no-cache bash coreutils curl docker-cli flock jq tzdata \
 && curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
 && curl -fsSL -o /usr/local/bin/mc \
      "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc" \
 && chmod +x /usr/local/bin/supercronic /usr/local/bin/mc

COPY lib/ /usr/local/lib/backup/
COPY bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/* /usr/local/lib/backup/jobs/*

ENV RESTIC_CACHE_DIR=/cache \
    METRICS_DIR=/textfile

ENTRYPOINT []
CMD ["supercronic", "-passthrough-logs", "/etc/backup/crontab"]
