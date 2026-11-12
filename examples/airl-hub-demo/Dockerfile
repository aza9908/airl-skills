# syntax=docker/dockerfile:1
# Один образ на сервис хаба: SERVICE = hub | finance | sales | edu.
#   docker build --build-arg SERVICE=finance --build-arg APP_VERSION=1.0.0 -t airl-hub-demo-finance:1.0.0 .
FROM node:22-alpine
ARG SERVICE
ARG APP_VERSION=dev
ENV NODE_ENV=production APP_VERSION=${APP_VERSION} SERVICE=${SERVICE}
WORKDIR /app
COPY services/package.json services/package-lock.json services/
# Корпоративный прокси с своим сертификатом (необязательно): --secret id=ca,src=<файл CA>
RUN --mount=type=secret,id=ca,required=false \
    if [ -f /run/secrets/ca ]; then export NPM_CONFIG_CAFILE=/run/secrets/ca; fi; \
    cd services && npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY services/shared services/shared
# Оболочке хаба нужны контракты всех сервисов (кому виден сервис) и реестр.
COPY services/finance/airl.service.json services/finance/airl.service.json
COPY services/sales/airl.service.json services/sales/airl.service.json
COPY services/edu/airl.service.json services/edu/airl.service.json
COPY hub/services.json hub/services.json
COPY services/${SERVICE} services/${SERVICE}
RUN mkdir -p /app/.secrets /app/ai/out && chown -R node:node /app/.secrets /app/ai
USER node
HEALTHCHECK --interval=15s --timeout=3s --retries=5 CMD node -e "const p={hub:'/healthz'}[process.env.SERVICE]||'/'+process.env.SERVICE+'/healthz';fetch('http://127.0.0.1:'+(process.env.PORT||3000)+p).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["sh", "-c", "exec node services/${SERVICE}/server.js"]
