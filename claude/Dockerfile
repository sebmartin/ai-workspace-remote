FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less openssh-client passwd procps util-linux \
      python3 python3-venv ripgrep fd-find tree unzip vim-tiny chromium \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

# gh from GitHub's own apt repo, not Debian's. Trixie ships 2.46 from early
# 2024, which predates the stacked-PR support this repo's workflow wants.
# Unpinned for the same reason as the installers below, and the architecture
# is read from dpkg so this builds on arm64 and amd64 alike.
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# A placeholder uid. The entrypoint moves the user to whatever .env says at
# startup, so this number never leaves the image and never needs a rebuild.
RUN groupadd -g 1000 claude \
 && useradd -m -u 1000 -g 1000 -s /bin/bash claude

USER claude
ENV HOME=/home/claude
ENV PATH=/home/claude/.local/bin:$PATH

# Plugin fetches go over https, so no key material is needed.
RUN git config --global url."https://github.com/".insteadOf git@github.com:

# Lets git push and clone use whatever token gh has, which is GH_TOKEN from
# the mounted secret. Configured here rather than at startup because it is a
# property of the image. With no token present the helper supplies nothing and
# public clones still work, so this is harmless when GitHub is not configured.
#
# --force because there is no token at build time and gh otherwise refuses to
# write the helper for a host it is not logged into. The hostname is explicit
# for the same reason: without one it looks for a logged-in host and finds none.
RUN gh auth setup-git --hostname github.com --force

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
CMD ["claude", "remote-control", "--spawn=same-dir", "--permission-mode", "auto"]
