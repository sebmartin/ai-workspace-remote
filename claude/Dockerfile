FROM debian:trixie-slim

ARG WORKSPACE_UID=1000
ARG WORKSPACE_GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less openssh-client procps \
      python3 python3-venv ripgrep fd-find tree unzip vim-tiny \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

RUN groupadd -g "${WORKSPACE_GID}" claude \
 && useradd -m -u "${WORKSPACE_UID}" -g "${WORKSPACE_GID}" -s /bin/bash claude

USER claude
ENV PATH=/home/claude/.local/bin:$PATH

# Plugin fetches go over https, so no key material is needed.
RUN git config --global url."https://github.com/".insteadOf git@github.com:

# uv: the ai-workspace plugin's MCP server runs `uv run --script`.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# The native installer, not npm. npm -g needs a root-owned prefix, which
# breaks background auto-update for a non-root user.
RUN curl -fsSL https://claude.ai/install.sh | bash -s stable

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude", "remote-control", "--permission-mode", "auto"]
