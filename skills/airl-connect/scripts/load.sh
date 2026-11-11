#!/bin/bash
# Загрузка выгрузки extract.py в хранилище без дублей.
#
#   DATABASE_URL=... bash load.sh <system> <папка выгрузки>
#
# Кладёт записи в raw_<system>.records (ключ: сущность + ID записи). Изменённые —
# обновляет, неизменённые — не трогает. Если рядом лежит <entity>.ids (запуск
# extract.py --full), помечает пропавшие записи is_deleted = true. Защита:
# если в .ids меньше половины уже загруженных живых записей — пометку не делает
# (сломанная выгрузка не «удалит» половину CRM).
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"

SYSTEM="${1:?Укажите систему: bitrix24 или amocrm}"
DIR="${2:?Укажите папку выгрузки}"
: "${DATABASE_URL:?Задайте DATABASE_URL}"
case "$SYSTEM" in bitrix24|amocrm) ;; *) echo "Система: bitrix24 или amocrm" >&2; exit 2 ;; esac
SCHEMA="raw_$SYSTEM"

psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 <<SQL
CREATE SCHEMA IF NOT EXISTS $SCHEMA;
CREATE TABLE IF NOT EXISTS $SCHEMA.records (
    entity       text        NOT NULL,
    source_id    text        NOT NULL,
    modified_at  timestamptz,
    payload      jsonb       NOT NULL,
    is_deleted   boolean     NOT NULL DEFAULT false,
    loaded_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (entity, source_id)
);
CREATE INDEX IF NOT EXISTS records_modified_idx ON $SCHEMA.records (entity, modified_at);
SQL

shopt -s nullglob
for file in "$DIR"/*.ndjson; do
  entity="$(basename "$file" .ndjson)"
  [[ "$entity" =~ ^[a-z_]+$ ]] || { echo "✖ пропускаю $file: странное имя" >&2; continue; }
  result=$(psql "$DATABASE_URL" -X -q -At -v ON_ERROR_STOP=1 \
    -c "CREATE TEMP TABLE stage (line text)" \
    -c "\\copy stage (line) FROM STDIN WITH (FORMAT csv, QUOTE E'\\x01', DELIMITER E'\\x02')" \
    -c "WITH s AS (SELECT line::jsonb AS j FROM stage WHERE line <> ''),
             up AS (
               INSERT INTO $SCHEMA.records AS r (entity, source_id, modified_at, payload, is_deleted, loaded_at)
               SELECT '$entity', j->>'source_id', (j->>'modified_at')::timestamptz, j->'payload', false, now()
               FROM s
               ON CONFLICT (entity, source_id) DO UPDATE
                 SET payload = EXCLUDED.payload, modified_at = EXCLUDED.modified_at,
                     is_deleted = false, loaded_at = now()
                 WHERE r.payload IS DISTINCT FROM EXCLUDED.payload OR r.is_deleted
               RETURNING 1)
        SELECT (SELECT count(*) FROM s) || ' прочитано, ' || (SELECT count(*) FROM up) || ' новых или изменённых'" \
    < "$file")
  echo "✔ $entity: $result"

  ids="$DIR/$entity.ids"
  if [ -f "$ids" ]; then
    marked=$(psql "$DATABASE_URL" -X -q -At -v ON_ERROR_STOP=1 \
      -c "CREATE TEMP TABLE stage_ids (source_id text PRIMARY KEY)" \
      -c "\\copy stage_ids (source_id) FROM STDIN" \
      -c "WITH live AS (SELECT count(*) AS n FROM $SCHEMA.records WHERE entity = '$entity' AND NOT is_deleted),
               got  AS (SELECT count(*) AS n FROM stage_ids),
               del AS (
                 UPDATE $SCHEMA.records r SET is_deleted = true, loaded_at = now()
                 WHERE r.entity = '$entity' AND NOT r.is_deleted
                   AND NOT EXISTS (SELECT 1 FROM stage_ids s WHERE s.source_id = r.source_id)
                   AND (SELECT n FROM got) * 2 >= (SELECT n FROM live)
                 RETURNING 1)
          SELECT CASE WHEN (SELECT n FROM got) * 2 < (SELECT n FROM live)
                      THEN 'пропущено: в списке ID меньше половины записей — проверьте выгрузку'
                      ELSE (SELECT count(*) FROM del) || ' помечено удалёнными' END" \
      < "$ids")
    echo "  $entity: $marked"
  fi
done
