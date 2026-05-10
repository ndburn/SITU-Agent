# Build stage for pi-coding-agent
FROM node:22-bullseye AS agent-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pi-mono
RUN git clone --depth 1 https://github.com/badlogic/pi-mono.git .

# Remove unused packages to reduce dependencies
RUN rm -rf packages/web-ui packages/mom packages/pods packages/web-ui/example

# Clean up package.json workspaces cleanly using node
RUN node -e 'const fs = require("fs"); const p = JSON.parse(fs.readFileSync("package.json")); \
    p.workspaces = ["packages/*"]; \
    p.scripts.build = "cd packages/tui && npm run build && cd ../ai && npm run build && cd ../agent && npm run build && cd ../coding-agent && npm run build"; \
    fs.writeFileSync("package.json", JSON.stringify(p, null, 2))'

RUN npm install
RUN npm run build
RUN npm prune --omit=dev

# Manually remove known large dev folders just in case they survived prune
RUN rm -rf node_modules/@biomejs \
    node_modules/typescript \
    node_modules/@typescript \
    node_modules/@types \
    node_modules/.cache

# Final stage
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    xz-utils \
    fd-find \
    ripgrep \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js in the final image and strip headers/npm
RUN set -e; \
    arch=$(dpkg --print-architecture); \
    case "$arch" in \
        amd64) node_arch="x64" ;; \
        arm64) node_arch="arm64" ;; \
        *) echo "Unsupported architecture: $arch"; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-${node_arch}.tar.xz" | tar -xJ -C /usr/local --strip-components=1 && \
    rm -rf /usr/local/include /usr/local/share/doc /usr/local/share/man /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack && \
    rm -rf /var/lib/apt/lists/*

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

# Non-root user for the agent. UID 1000 is mapped from the host user
# at runtime via `podman run --userns=keep-id:uid=1000,gid=1000`.
RUN useradd -m -u 1000 -s /bin/bash situ

# Setup default configuration for pi
RUN mkdir -p /home/situ/.pi/agent && chown -R situ:situ /home/situ/.pi
COPY --chown=situ:situ docker/agent/ /home/situ/.pi/agent/
RUN chmod -R u+rwX,go+rX /home/situ/.pi

# Entrypoint script (root-owned, executable, readable by all).
# Force 0755 — `chmod +x` would preserve restrictive host perms (e.g. 0700
# on iCloud Drive), making the script unreadable to the non-root `situ` user.
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER situ
WORKDIR /workspace

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "bash" ]
