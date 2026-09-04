# Commits the workspace to a git repo on the mounted backup storage, copies
# the session transcripts alongside it, and keeps both repos healthy.
#
# The storage is whatever the OS mounted. Docker bind-mounts it at /backup and
# this container writes to it as an ordinary directory.

FROM alpine:3.21

# supercronic rather than busybox crond: it logs each job's output to its own
# stdout with the job name and exit code, inherits the container environment,
# and runs as a non-root uid without needing a passwd entry.
#
# The checksum is for linux-amd64. Building on arm64 needs both args changed.
ARG SUPERCRONIC_VERSION=v0.2.49
ARG SUPERCRONIC_ARCH=amd64
ARG SUPERCRONIC_SHA256=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1

RUN apk add --no-cache \
      bash \
      coreutils \
      curl \
      git \
      rsync \
      tzdata

RUN curl -fsSLO "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${SUPERCRONIC_ARCH}" \
 && echo "${SUPERCRONIC_SHA256}  supercronic-linux-${SUPERCRONIC_ARCH}" | sha256sum -c - \
 && chmod +x "supercronic-linux-${SUPERCRONIC_ARCH}" \
 && mv "supercronic-linux-${SUPERCRONIC_ARCH}" /usr/local/bin/supercronic

# Set here, not in the entrypoint: `docker compose exec` inherits the image
# environment, not PID 1's, so a manually invoked job would otherwise have no
# git identity and no writable HOME.
ENV HOME=/tmp \
    GIT_CONFIG_GLOBAL=/tmp/gitconfig

COPY --chmod=755 entrypoint.sh /opt/aiwr/entrypoint.sh
COPY --chmod=755 scripts/ /opt/aiwr/

ENTRYPOINT ["/opt/aiwr/entrypoint.sh"]
