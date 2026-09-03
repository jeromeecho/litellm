# syntax=docker/dockerfile:1.7

# Base image for building
ARG LITELLM_BUILD_IMAGE=cgr.dev/chainguard/wolfi-base@sha256:a31344ab2cb8618db84f535eec56f76f6178b142cb92cb2e48676cc2dcebea72

# Runtime image
ARG LITELLM_RUNTIME_IMAGE=cgr.dev/chainguard/wolfi-base@sha256:a31344ab2cb8618db84f535eec56f76f6178b142cb92cb2e48676cc2dcebea72
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.7@sha256:240fb85ab0f263ef12f492d8476aa3a2e4e1e333f7d67fbdd923d00a506a516a
ARG RUST_IMAGE=rust:1.94.1-slim-bookworm@sha256:cf9dd0ec73e75f827fe59123fff9dc65af1a1c8363c3c31ee8d7f8ad0b6a5fb2
# Pinned by digest like the other base images; bump explicitly on Node upgrades.
ARG UI_BUILD_IMAGE=node:24.19-alpine3.24@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43

FROM $UV_IMAGE AS uvbin
FROM $RUST_IMAGE AS rustbin

# Admin UI builder. Pinned to the build platform so the architecture-independent
# Next.js static export compiles once natively even in a multi-arch build,
# instead of once per target arch under QEMU.
FROM --platform=$BUILDPLATFORM $UI_BUILD_IMAGE AS ui-builder

ARG NPM_CONFIG_REGISTRY=https://registry.npmjs.org/

ENV NEXT_TELEMETRY_DISABLED=1 \
    npm_config_fund=false \
    npm_config_audit=false

WORKDIR /ui

COPY ui/litellm-dashboard/package.json ui/litellm-dashboard/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --prefer-offline

COPY ui/litellm-dashboard/ ./
RUN npm run build

# Builder stage
FROM $LITELLM_BUILD_IMAGE AS builder

ARG NPM_CONFIG_REGISTRY=https://registry.npmjs.org/
ARG UV_DEFAULT_INDEX=https://pypi.org/simple

WORKDIR /app
USER root

COPY --from=uvbin /uv /usr/local/bin/uv
COPY --from=uvbin /uvx /usr/local/bin/uvx
COPY --from=rustbin /usr/local/cargo /usr/local/cargo
COPY --from=rustbin /usr/local/rustup /usr/local/rustup

RUN apk add --no-cache \
    bash \
    gcc \
    openssl \
    openssl-dev \
    libsndfile

ENV UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_PYTHON=3.13.13 \
    UV_LINK_MODE=copy \
    UV_HTTP_CONNECT_TIMEOUT=60 \
    UV_HTTP_TIMEOUT=120 \
    UV_HTTP_RETRIES=5 \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH="/usr/local/cargo/bin:/app/.venv/bin:${PATH}"

# Copy dependency metadata first for layer caching
COPY pyproject.toml uv.lock ./
COPY enterprise/pyproject.toml enterprise/
COPY litellm-proxy-extras/pyproject.toml litellm-proxy-extras/

# Install third-party dependencies (cached unless pyproject.toml/uv.lock change)
RUN --mount=type=cache,target=/root/.cache/uv \
    sed -i \
    -e '/^exclude-newer = /d' \
    -e '/^exclude-newer-span = /d' \
    pyproject.toml uv.lock && \
    uv lock --default-index "$UV_DEFAULT_INDEX" && \
    uv sync --default-index "$UV_DEFAULT_INDEX" \
    --frozen --no-install-project --no-install-workspace --no-default-groups --no-editable \
    --extra proxy \
    --extra proxy-runtime \
    --extra extra_proxy \
    --extra semantic-router \
    --extra saml \
    --python 3.13.13

# Copy full source tree
COPY . .

# Replace the committed UI bundle with the one built from this exact source.
# Clearing first drops the committed bundle's content-hashed chunks that COPY
# would otherwise leave behind alongside the fresh ones.
RUN rm -rf litellm/proxy/_experimental/out
COPY --from=ui-builder /ui/out/. litellm/proxy/_experimental/out/

# Build Admin UI before final sync (applies the enterprise color override when present)
RUN sed -i 's/\r$//' docker/build_admin_ui.sh && chmod +x docker/build_admin_ui.sh && ./docker/build_admin_ui.sh

# Install project and workspace packages (fast - deps already cached)
RUN --mount=type=cache,target=/root/.cache/uv \
    sed -i \
    -e '/^exclude-newer = /d' \
    -e '/^exclude-newer-span = /d' \
    pyproject.toml uv.lock && \
    uv lock --default-index "$UV_DEFAULT_INDEX" && \
    uv sync --default-index "$UV_DEFAULT_INDEX" \
    --frozen --no-default-groups --no-editable \
    --extra proxy \
    --extra proxy-runtime \
    --extra extra_proxy \
    --extra semantic-router \
    --extra saml \
    --python 3.13.13

RUN printf '\n[tool.prisma]\nnodeenv_extra_args = ["--node=20.20.2"]\n' >> pyproject.toml && \
    HOME=/opt/prisma XDG_CACHE_HOME=/opt/prisma/.cache PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries \
    NPM_CONFIG_REGISTRY="$NPM_CONFIG_REGISTRY" \
    npm_config_cache=/root/.npm \
    prisma generate --schema=./schema.prisma

RUN sed -i 's/\r$//' docker/entrypoint.sh && chmod +x docker/entrypoint.sh && \
    sed -i 's/\r$//' docker/prod_entrypoint.sh && chmod +x docker/prod_entrypoint.sh

# Runtime stage
FROM $LITELLM_RUNTIME_IMAGE AS runtime

USER root

RUN apk add --no-cache bash openssl tzdata libatomic libgcc libstdc++ libsndfile

WORKDIR /app
ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/prisma/.cache/prisma-python/nodeenv/bin:/app/.venv/bin:${PATH}" \
    PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries \
    PRISMA_CLI_PATH=/opt/prisma/binaries/node_modules/.bin/prisma \
    PRISMA_CLI_QUERY_ENGINE_TYPE=binary \
    PRISMA_OFFLINE_MODE=true

# Copy only what runtime needs. The application is installed inside the venv;
# the rest of the builder's /app is source and build metadata that must not
# ship (manifest-scanning tools attribute everything in it to this image).
# entrypoint.sh invokes litellm/proxy/prisma_migration.py by source path.
COPY --from=builder /opt/python /opt/python
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/docker /app/docker
COPY --from=builder /app/schema.prisma /app/schema.prisma
COPY --from=builder /app/litellm/proxy/prisma_migration.py /app/litellm/proxy/prisma_migration.py
# enterprise/ is imported by source path at runtime (proxy_cli puts the
# working directory on sys.path; litellm/proxy/hooks resolves
# enterprise.enterprise_hooks from it)
COPY --from=builder /app/enterprise /app/enterprise
COPY --from=builder /app/litellm-proxy-extras /app/litellm-proxy-extras
# Prisma CLI + engines are baked under /opt/prisma, a fixed path every
# runtime uid can read and that no cache volume mount shadows. The paths are
# pinned via PRISMA_BINARY_CACHE_DIR / PRISMA_CLI_PATH and recorded into the
# generated client at build time, so `prisma migrate deploy` on a fresh
# database needs no npm and no network access (#33650, #24554).
COPY --from=builder /opt/prisma /opt/prisma

RUN find /app/.venv -type f -path "*/tornado/test/*" -delete && \
    find /app/.venv -type d -path "*/tornado/test" -delete && \
    chmod -R a+rX /opt/prisma && \
    test -x /opt/prisma/binaries/node_modules/.bin/prisma && \
    test -f /opt/prisma/binaries/node_modules/prisma/build/index.js && \
    /opt/prisma/.cache/prisma-python/nodeenv/bin/node --version && \
    /app/.venv/bin/python -c "from prisma.client import BINARY_PATHS; paths = list(BINARY_PATHS.query_engine.values()); assert paths and all(p.startswith('/opt/prisma/') for p in paths), paths"

EXPOSE 4000/tcp

ENTRYPOINT ["docker/prod_entrypoint.sh"]
CMD ["--port", "4000"]
