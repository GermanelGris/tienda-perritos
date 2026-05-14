# ============================================================
# STAGE 1: Dependencias
# ============================================================
FROM node:18-alpine AS deps

WORKDIR /app

COPY package*.json ./

RUN npm install --only=production && npm cache clean --force
# ============================================================
# STAGE 2: Runtime
# ============================================================
FROM node:18-alpine AS runtime

WORKDIR /app

# Usuario no-root (mínimo privilegio)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=deps /app/node_modules ./node_modules
COPY server.js ./
COPY package.json ./

RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 3001

CMD ["node", "server.js"]
