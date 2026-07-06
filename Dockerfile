# =====================================================================
# MailForge — Production Dockerfile for DigitalOcean Ubuntu Droplet
# Multi-stage build: produces a small runtime image with standalone Next.js
# =====================================================================

# ---- Builder ----
FROM node:20-bookworm-slim AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Install bun (used for install + build scripts)
RUN npm install -g bun

WORKDIR /app

# Install deps first (better layer caching)
COPY package.json bun.lock* ./
COPY prisma ./prisma
RUN bun install --frozen-lockfile

# Copy source and build
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
# Throwaway DB URL just so prisma generate / next build can read schema.prisma
ENV DATABASE_URL=file:/tmp/build.db

RUN bunx prisma generate
# `bun run build` runs `next build` then copies static + public into standalone/
RUN bun run build

# ---- Runner ----
FROM node:20-bookworm-slim AS runner
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
ENV DATA_DIR=/app/data
# Default DB location — overridable via docker-compose / -e
ENV DATABASE_URL=file:/app/data/custom.db

# Standalone Next.js server (includes bundled node_modules: @prisma/client + generated client)
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

# Prisma CLI + schema for runtime `db push` (idempotent schema apply on first boot)
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/node_modules/prisma ./node_modules/prisma
COPY --from=builder /app/package.json ./package.json

# Entrypoint: apply schema, then start server
COPY deploy/entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

# Persistent data (SQLite DB) + scratch dirs
RUN mkdir -p /app/data /app/upload /app/download

EXPOSE 3000
VOLUME ["/app/data"]

CMD ["./entrypoint.sh"]
