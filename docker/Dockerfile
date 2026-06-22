# Build stage for pi-coding-agent
FROM node:24-bookworm AS agent-builder
ARG NPM_LOGLEVEL=error

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pi-mono
RUN git clone --quiet --depth 1 https://github.com/badlogic/pi-mono.git .

# Remove unused packages to reduce dependencies
RUN rm -rf packages/web-ui packages/mom packages/pods packages/web-ui/example

# Clean up package.json workspaces cleanly using node
RUN node -e 'const fs = require("fs"); const p = JSON.parse(fs.readFileSync("package.json")); \
    p.workspaces = ["packages/*"]; \
    p.scripts.build = "cd packages/tui && npm run build && cd ../ai && npm run build && cd ../agent && npm run build && cd ../coding-agent && npm run build"; \
    fs.writeFileSync("package.json", JSON.stringify(p, null, 2))'

# canvas is a test-only devDep in packages/ai; strip it to avoid native build deps
RUN node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync("packages/ai/package.json")); delete p.devDependencies.canvas; fs.writeFileSync("packages/ai/package.json", JSON.stringify(p,null,2))'

RUN npm install --loglevel=${NPM_LOGLEVEL}
RUN npm run build --loglevel=${NPM_LOGLEVEL}
RUN npm prune --omit=dev --loglevel=${NPM_LOGLEVEL}

# Manually remove known large dev folders just in case they survived prune
RUN rm -rf node_modules/@biomejs \
    node_modules/typescript \
    node_modules/@typescript \
    node_modules/@types \
    node_modules/.cache

# Final stage
FROM node:24-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies and strip npm/npx/corepack (not needed at runtime)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    fd-find \
    ripgrep \
    poppler-utils \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
    && rm -rf /var/lib/apt/lists/*

# Copy built pi-coding-agent (only necessary files)
WORKDIR /opt/pi-mono
COPY --from=agent-builder /opt/pi-mono/package.json ./
COPY --from=agent-builder /opt/pi-mono/node_modules ./node_modules
COPY --from=agent-builder /opt/pi-mono/packages/coding-agent/package.json ./packages/coding-agent/
COPY --from=agent-builder /opt/pi-mono/packages/coding-agent/dist ./packages/coding-agent/dist
COPY --from=agent-builder /opt/pi-mono/packages/agent ./packages/agent
COPY --from=agent-builder /opt/pi-mono/packages/ai ./packages/ai
COPY --from=agent-builder /opt/pi-mono/packages/tui ./packages/tui

# Create a symlink for pi
RUN echo '#!/bin/bash\nnode /opt/pi-mono/packages/coding-agent/dist/cli.js "$@"' > /usr/local/bin/pi && \
    chmod +x /usr/local/bin/pi

# Setup default configuration for pi under the non-root node user's home
RUN mkdir -p /home/node/.pi/agent && chown -R node:node /home/node/.pi
COPY --chown=node:node docker/agent/ /home/node/.pi/agent/
RUN chmod -R a+rwX /home/node/.pi

# Entrypoint script
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

USER node

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "bash" ]
