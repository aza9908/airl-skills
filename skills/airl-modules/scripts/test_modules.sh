#!/bin/bash
# Проверка модулей AIRL на чистой базе PostgreSQL.
#
#   DATABASE_URL=postgres://user@host/db bash test_modules.sh [модуль ...]
#
# Для каждого модуля: новая схема, kit.sql → schema.sql → demo_src.sql → seed.sql,
# затем повторный запуск всех файлов (проверка, что установка повторяема),
# затем каждое представление v_* и m_* должно выполниться, m_* — вернуть строки
# с колонками metric_id, period, value, unit, status. Схемы удаляются в конце.
# Не запускать на боевой базе: создаёт и удаляет схемы test_airl_*.
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"

: "${DATABASE_URL:?Задайте DATABASE_URL тестовой базы}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
  for d in "$ROOT"/modules/*/; do MODULES+=("$(basename "$d")"); done
fi

fail=0
for m in "${MODULES[@]}"; do
  dir="$ROOT/modules/$m"
  schema="test_airl_$(echo "$m" | tr '-' '_')"
  for f in schema.sql demo_src.sql seed.sql MODULE.md; do
    [ -f "$dir/$f" ] || { echo "✖ $m: нет файла $f"; fail=1; continue 2; }
  done

  run() {
    psql "$DATABASE_URL" -q -X -v ON_ERROR_STOP=1 <<SQL
SET client_min_messages TO warning;
SET search_path TO $schema;
\i $ROOT/kit/kit.sql
\i $dir/demo_src.sql
\i $dir/schema.sql
\i $dir/seed.sql
SQL
  }

  psql "$DATABASE_URL" -q -X -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS $schema CASCADE; CREATE SCHEMA $schema;" >/dev/null
  out=""; out2=""
  if ! out=$(run 2>&1) || ! out2=$(run 2>&1); then
    echo "✖ $m: установка не прошла"; echo "$out$out2" | tail -5; fail=1; continue
  fi

  views=$(psql "$DATABASE_URL" -X -At -c \
    "SELECT table_name FROM information_schema.views WHERE table_schema = '$schema' AND (table_name LIKE 'v\_%' OR table_name LIKE 'm\_%') ORDER BY 1")
  bad=0; summary=""
  for v in $views; do
    if ! n=$(psql "$DATABASE_URL" -X -At -v ON_ERROR_STOP=1 -c "SET search_path TO $schema; SELECT count(*) FROM $v" 2>&1 | tail -1); then
      echo "✖ $m: $v — ошибка: $n"; bad=1; continue
    fi
    if [[ "$v" == m_* ]]; then
      cols=$(psql "$DATABASE_URL" -X -At -c \
        "SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema = '$schema' AND table_name = '$v'")
      if [ "$cols" != "metric_id,period,value,unit,status" ]; then
        echo "✖ $m: $v — колонки «$cols», нужны metric_id,period,value,unit,status"; bad=1
      fi
      if [ "$n" = "0" ]; then echo "✖ $m: $v — пусто на демо-данных"; bad=1; fi
      st=$(psql "$DATABASE_URL" -X -At -c "SET search_path TO $schema; SELECT count(*) FROM $v WHERE status NOT IN ('ok','warning','danger') OR status IS NULL" | tail -1)
      if [ "$st" != "0" ]; then echo "✖ $m: $v — status вне ok|warning|danger"; bad=1; fi
    fi
    summary+="$v=$n "
  done
  if [ $bad -eq 0 ]; then echo "✔ $m: $summary"; else fail=1; fi
  psql "$DATABASE_URL" -q -X -c "DROP SCHEMA IF EXISTS $schema CASCADE;" >/dev/null
done

# Все модули вместе в одной схеме (как у отдела с несколькими модулями), дважды,
# и чтение показателей из другой схемы — как их читают хаб и ИИ-слой.
if [ ${#MODULES[@]} -gt 1 ]; then
  schema="test_airl_together"
  psql "$DATABASE_URL" -q -X -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS $schema CASCADE; CREATE SCHEMA $schema;" >/dev/null
  script="SET search_path TO $schema;"$'\n'"\\i $ROOT/kit/kit.sql"$'\n'
  for m in "${MODULES[@]}"; do script+="\\i $ROOT/modules/$m/demo_src.sql"$'\n'; done
  for m in "${MODULES[@]}"; do script+="\\i $ROOT/modules/$m/schema.sql"$'\n'; done
  for m in "${MODULES[@]}"; do script+="\\i $ROOT/modules/$m/seed.sql"$'\n'; done
  if ! out=$(printf '%s' "$script" | psql "$DATABASE_URL" -q -X -v ON_ERROR_STOP=1 2>&1) || \
     ! out2=$(printf '%s' "$script" | psql "$DATABASE_URL" -q -X -v ON_ERROR_STOP=1 2>&1); then
    echo "✖ все вместе: установка не прошла"; echo "$out$out2" | tail -5; fail=1
  else
    bad=0; n=0
    for v in $(psql "$DATABASE_URL" -X -At -c "SELECT table_name FROM information_schema.views WHERE table_schema = '$schema' AND table_name LIKE 'm\_%' ORDER BY 1"); do
      n=$((n+1))
      if ! psql "$DATABASE_URL" -X -At -v ON_ERROR_STOP=1 -c "SET search_path TO public; SELECT count(*) FROM $schema.$v" >/dev/null 2>&1; then
        echo "✖ все вместе: $schema.$v не читается из другой схемы"; bad=1
      fi
    done
    [ $bad -eq 0 ] && echo "✔ все вместе: ${#MODULES[@]} модулей в одной схеме, $n показателей читаются из другой схемы" || fail=1
  fi
  psql "$DATABASE_URL" -q -X -c "DROP SCHEMA IF EXISTS $schema CASCADE;" >/dev/null
fi
exit $fail
