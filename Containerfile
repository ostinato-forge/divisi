# divisi agent-context image: one base for every isolated context.
# Build args let it match the host user so bind-mounted homes keep your uid.
ARG BASE=registry.fedoraproject.org/fedora:43
FROM ${BASE}

ARG UID=1000
ARG GID=1000
ARG USERNAME=dev

RUN dnf -y install \
        git git-lfs nodejs npm python3 python3-pip \
        make gcc gcc-c++ ripgrep fd-find jq tmux nano vim-enhanced \
        openssh-clients procps-ng iputils tar unzip which hostname \
        findutils diffutils gitleaks curl shadow-utils \
    && dnf clean all

# GitHub CLI: in Fedora repos, with upstream repo as fallback.
RUN dnf -y install gh \
    || ( curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo \
            -o /etc/yum.repos.d/gh-cli.repo \
         && dnf -y install gh && dnf clean all )

# Terminal coding agents. Update by rebuilding the image (autoupdaters off).
# Add or remove CLIs here to taste; keep DIVISI_GUARD_TOOLS in sync.
RUN npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex \
        @google/gemini-cli

RUN getent group ${GID} >/dev/null || groupadd -g ${GID} ${USERNAME}
RUN useradd -u ${UID} -g ${GID} -m ${USERNAME}
