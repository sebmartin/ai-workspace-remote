# Commits the workspace, mirrors the bare repo and the session transcripts to
# the NAS over SSH, and keeps the local repo healthy.
#
# The NAS only ever receives files. It never runs git, so git never has to be
# installed there and git's ref locking never touches a network filesystem.

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
      openssh-client \
      rsync \
      tzdata \
      flock

RUN curl -fsSLO "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${SUPERCRONIC_ARCH}" \
 && echo "${SUPERCRONIC_SHA256}  supercronic-linux-${SUPERCRONIC_ARCH}" | sha256sum -c - \
 && chmod +x "supercronic-linux-${SUPERCRONIC_ARCH}" \
 && mv "supercronic-linux-${SUPERCRONIC_ARCH}" /usr/local/bin/supercronic

COPY --chmod=755 entrypoint.sh /opt/aiwr/entrypoint.sh
COPY --chmod=755 scripts/ /opt/aiwr/

ENTRYPOINT ["/opt/aiwr/entrypoint.sh"]
