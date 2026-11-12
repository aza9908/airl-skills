# Каркас Dockerfile. Пишет /airl-devops, часть 0. Подставь стек проекта: ниже — Node.js;
# для Python замени этапы (python:3.12-slim, pip install -r requirements.txt).
# Правила: многоэтапная сборка; один контейнер отдаёт интерфейс, API и /healthz на одном
# порту; процесс не под root; версия приходит аргументом APP_VERSION (её отдаёт /healthz).
# Рядом — .dockerignore со строками: .env*, .git, node_modules, копии базы.
# За корпоративным прокси с подменой сертификатов — references/server-setup.md,
# «Сборка за корпоративным прокси»: сертификат передаётся секретом сборки (--secret id=ca).

# Этап 1. Зависимости и сборка
FROM node:22-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Этап 2. Только то, что нужно для работы
FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
COPY --from=build /app/package*.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
# [порт приложения: тот же, что APP_PORT в .env на сервере]
ENV PORT=3000
EXPOSE 3000
USER node
# [команда запуска сервера, который отдаёт dist, API и /healthz]
CMD ["node", "dist/server.js"]
