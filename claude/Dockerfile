FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less openssh-client passwd procps util-linux \
      python3 python3-venv ripgrep fd-find tree unzip vim-tiny \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

# A placeholder uid. The entrypoint moves the user to whatever .env says at
# startup, so this number never leaves the image and never needs a rebuild.
RUN groupadd -g 1000 claude \
 && useradd -m -u 1000 -g 1000 -s /bin/bash claude

USER claude
ENV HOME=/home/claude
ENV PATH=/home/claude/.local/bin:$PATH

# Plugin fetches go over https, so no key material is needed.
RUN git config --global url."https://github.com/".insteadOf git@github.com:

# Both installers below are fetched unpinned, on purpose. `make rebuild` is
# the documented way to move versions forward, and pinning would mean editing
# this file to get a security fix.
#
# uv: the ai-workspace plugin's MCP server runs `uv run --script`.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# The native installer, not npm. npm -g needs a root-owned prefix, which
# breaks background auto-update for a non-root user.
RUN curl -fsSL https://claude.ai/install.sh | bash -s stable

# Back to root so the entrypoint can align the uid before dropping to claude.
USER root
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude", "remote-control", "--permission-mode", "auto"]
