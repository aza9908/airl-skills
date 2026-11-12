'use strict';
// Генерирует proxy/Caddyfile из реестра hub/services.json (/airl-hub, часть 5): один блок на сервис,
// префикс пути не срезается; всё остальное — оболочка хаба. Сервис со статусом disabled не публикуется.
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const reg = JSON.parse(fs.readFileSync(path.join(ROOT, 'hub', 'services.json'), 'utf8')).services;
const blocks = reg.filter((s) => s.status !== 'disabled').map((s) => `    redir ${s.base_path} ${s.base_path}/ 308
    handle ${s.base_path}/* {
        reverse_proxy ${s.upstream}
    }`).join('\n\n');

const out = `# Сгенерировано scripts/gen_caddy.js из hub/services.json — руками не править.
# HUB_SITE: ":80" локально (docker compose) или "hub.<домен>" на сервере (сертификат выпустит Caddy).
{$HUB_SITE::80} {
    encode gzip
    header -Server

${blocks}

    handle {
        reverse_proxy hub:3000
    }
}
`;
fs.mkdirSync(path.join(ROOT, 'proxy'), { recursive: true });
fs.writeFileSync(path.join(ROOT, 'proxy', 'Caddyfile'), out);
console.log(`proxy/Caddyfile: ${reg.length} сервисов`);
