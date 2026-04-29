FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
  bat \
  bash \
  build-essential \
  ca-certificates \
  curl \
  docker-compose \
  docker.io \
  fd-find \
  git \
  gh \
  gosu \
  jq \
  make \
  openssh-client \
  passwd \
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
  yamllint \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/lib/docker/cli-plugins \
  && ln -sf /usr/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

RUN corepack enable && corepack prepare pnpm@latest --activate
RUN npm install -g \
  @biomejs/biome \
  eslint \
  jest \
  nodemon \
  npm-check-updates \
  nx \
  prettier \
  prisma \
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
RUN su agent -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
RUN su agent -c 'curl -fsSL https://bun.sh/install | bash'

RUN su agent -c 'curl -fsSL https://opencode.ai/install | bash'
RUN ln -sf /home/agent/.opencode/bin/opencode /usr/local/bin/opencode
RUN ln -sf /home/agent/.local/bin/uv /usr/local/bin/uv || true
RUN ln -sf /home/agent/.local/bin/serena /usr/local/bin/serena || true

COPY bin/ /opt/opencode/bin/
COPY templates/ /opt/opencode/templates/

RUN chmod +x /opt/opencode/bin/*.sh

ENV PATH="/home/agent/.opencode/bin:/home/agent/.local/bin:/home/agent/.bun/bin:/usr/local/bin:/usr/bin:/bin"

WORKDIR /workspace

EXPOSE 4096

ENTRYPOINT ["/opt/opencode/bin/entrypoint.sh"]
