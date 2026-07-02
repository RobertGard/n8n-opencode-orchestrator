FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
  bat \
  bash \
  bc \
  build-essential \
  ca-certificates \
  curl \
  docker-compose \
  docker.io \
  fd-find \
  fzf \
  git \
  gh \
  gnupg \
  gosu \
  hyperfine \
  jq \
  make \
  mariadb-client \
  openssh-client \
  passwd \
  postgresql-client \
  procps \
  python3 \
  python3-pip \
  python3-venv \
  ripgrep \
  rsync \
  shellcheck \
  sqlite3 \
  tree \
  unzip \
  vim-tiny \
  wget \
  yamllint \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/lib/docker/cli-plugins \
  && ln -sf /usr/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

COPY bin/install-github-tool.sh /opt/opencode/bin/
RUN bash /opt/opencode/bin/install-github-tool.sh \
    'hadolint/hadolint|hadolint|hadolint-Linux-x86_64' \
    'dandavison/delta|delta|git-delta_.*_amd64\.deb' \
    'xo/usql|usql|usql.*linux.*amd64' \
    'rhysd/actionlint|actionlint|actionlint_.*_linux_amd64\.tar\.gz' \
    'gitleaks/gitleaks|gitleaks|gitleaks_.*_linux_amd64\.tar\.gz'

RUN corepack enable && corepack prepare pnpm@latest --activate
RUN npm install -g \
  @ast-grep/cli \
  @biomejs/biome \
  eslint \
  jest \
  nodemon \
  npm-check-updates \
  nx \
  prettier \
  prisma \
  playwright \
  ts-jest \
  ts-node \
  tsx \
  turbo \
  typescript \
  typescript-language-server \
  vite \
  vitest \
  vscode-langservers-extracted \
  zx

RUN useradd -m -s /bin/bash agent
RUN su agent -c 'mkdir -p /home/agent/.npm-global && npm config set prefix /home/agent/.npm-global'
RUN su agent -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
RUN su agent -c 'curl -fsSL https://bun.sh/install | bash'

RUN su agent -c 'curl -fsSL https://opencode.ai/install | bash'
RUN ln -sf /home/agent/.opencode/bin/opencode /usr/local/bin/opencode
RUN ln -sf /home/agent/.local/bin/uv /usr/local/bin/uv || true
RUN ln -sf /home/agent/.local/bin/serena /usr/local/bin/serena || true

COPY bin/ /opt/opencode/bin/
COPY templates/ /opt/opencode/templates/

RUN chmod +x /opt/opencode/bin/*.sh

ENV PATH="/home/agent/.npm-global/bin:/home/agent/.opencode/bin:/home/agent/.local/bin:/home/agent/.bun/bin:/usr/local/bin:/usr/bin:/bin"

WORKDIR /workspace

EXPOSE 4096

ENTRYPOINT ["/opt/opencode/bin/entrypoint.sh"]
