#!/usr/bin/env bash
# Автоматические проверки перед код-ревью (навык airl-code-review).
#
# Запуск из корня репозитория продукта:
#   bash scripts/review_checks.sh                    весь проект
#   bash scripts/review_checks.sh --since abc1234    только изменения с прошлого ревью
#   bash scripts/review_checks.sh --url https://staging.example.com   ещё и живой /healthz
#   bash scripts/review_checks.sh --no-tools         без линтера, тестов и аудита
#                                                    (в CI они идут отдельными шагами)
#   bash scripts/review_checks.sh --out review_checks.md   сохранить отчёт в файл
#   bash scripts/review_checks.sh backend            проверить только папку backend
#
# Код выхода: 0 — блокирующих находок нет; 1 — есть блокирующие; 2 — ошибка запуска.
# Ничего не устанавливает: нет инструмента — проверка помечается «пропущено».
# Значения найденных ключей не печатаются: только файл и номер строки.
# Работает в bash 3.2 (macOS) и новее, на Linux и в GitHub Actions.

set -uo pipefail

SINCE=""
URL=""
OUT=""
RUN_TOOLS=1
ROOT="."

need_value() {
  if [ "$2" -lt 2 ]; then
    echo "Параметру $1 нужно значение" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since) need_value "$1" $#; SINCE="$2"; shift 2 ;;
    --url) need_value "$1" $#; URL="${2%/}"; shift 2 ;;
    --out) need_value "$1" $#; OUT="$2"; shift 2 ;;
    --no-tools) RUN_TOOLS=0; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "Неизвестный параметр: $1 (см. --help)" >&2; exit 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done

if [ -n "$OUT" ] && [ "${OUT#/}" = "$OUT" ]; then
  OUT="$PWD/$OUT"
fi
cd "$ROOT" 2>/dev/null || { echo "Нет папки: $ROOT" >&2; exit 2; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t review_checks)
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/findings"
: > "$WORK/checks"
: > "$WORK/logs.md"

export CI=true NO_COLOR=1 FORCE_COLOR=0 NPM_CONFIG_UPDATE_NOTIFIER=false NPM_CONFIG_FUND=false
ESC=$(printf '\033')
TIMEOUT_SEC="${REVIEW_TIMEOUT:-900}"
SELF_NAME=$(basename "$0")

# ---------- служебные функции ----------

have() { command -v "$1" >/dev/null 2>&1; }

# finding <блокирует|важно|потом> <область> <текст>
finding() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WORK/findings"; }

# check <название> <ок|ошибка|замечания|пропущено> <подробности>
check() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WORK/checks"; }

# run <имя журнала> <команда...> — запуск с ограничением по времени, вывод в журнал
run() {
  local name="$1"
  shift
  if have timeout; then
    timeout "$TIMEOUT_SEC" "$@" > "$WORK/$name.log" 2>&1
  else
    "$@" > "$WORK/$name.log" 2>&1
  fi
}

# attach_log <имя журнала> <заголовок> — последние строки вывода в конец отчёта
attach_log() {
  {
    printf '\n### %s\n\n```text\n' "$2"
    sed "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$WORK/$1.log" | tail -n 25
    printf '```\n'
  } >> "$WORK/logs.md"
}

EXCL='(^|/)(node_modules|\.venv|venv|env|dist|build|out|\.next|\.nuxt|\.svelte-kit|coverage|htmlcov|__pycache__|\.git|vendor|\.mypy_cache|\.pytest_cache|\.ruff_cache|\.tox|\.terraform)(/|$)'

existing_only() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

IS_GIT=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then IS_GIT=1; fi

all_files() {
  if [ "$IS_GIT" = 1 ]; then
    git ls-files -co --exclude-standard
  else
    find . -type f | sed 's|^\./||'
  fi | grep -Ev "$EXCL" | existing_only
}

all_files | sort -u > "$WORK/all"

SCOPE_TEXT="весь проект"
if [ -n "$SINCE" ]; then
  if [ "$IS_GIT" != 1 ]; then
    echo "--since работает только в репозитории git" >&2
    exit 2
  fi
  if ! git rev-parse --verify --quiet "${SINCE}^{commit}" >/dev/null; then
    echo "Коммит не найден: $SINCE (сделайте git fetch или проверьте хеш в REVIEW.md)" >&2
    exit 2
  fi
  {
    git diff --relative --name-only --diff-filter=ACMR "$SINCE"
    git ls-files -o --exclude-standard
  } | grep -Ev "$EXCL" | existing_only | sort -u > "$WORK/scope"
  SCOPE_TEXT="изменения с $(git rev-parse --short "$SINCE"): файлов $(wc -l < "$WORK/scope" | tr -d ' ')"
else
  cp "$WORK/all" "$WORK/scope"
fi

COMMIT="нет git"
if [ "$IS_GIT" = 1 ]; then
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "нет коммитов")
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    COMMIT="$COMMIT + незакоммиченные правки"
  fi
fi

# grep_scope <файл со списком> <регулярка ERE> [доп. ключи grep] — вывод file:line:text
grep_list() {
  local list="$1" re="$2"
  shift 2
  [ -s "$list" ] || return 0
  tr '\n' '\0' < "$list" | xargs -0 grep -I -n -H -E "$@" -e "$re" /dev/null 2>/dev/null || true
}

# ---------- поиск проектов (корень и подпапки до двух уровней) ----------

find . -maxdepth 3 \( -name node_modules -o -name .venv -o -name venv -o -name .git -o -name dist -o -name build -o -name vendor \) -prune -o \
  \( -name package.json -o -name pyproject.toml -o -name requirements.txt -o -name setup.py -o -name Pipfile \) -type f -print 2>/dev/null \
  | sed 's|^\./||' > "$WORK/manifests"

NODE_DIRS=$(grep -E '(^|/)package\.json$' "$WORK/manifests" | sed -E 's|/?package\.json$||; s|^$|.|' | sort -u)
PY_DIRS=$(grep -E '(^|/)(pyproject\.toml|requirements\.txt|setup\.py|Pipfile)$' "$WORK/manifests" | sed -E 's|/?[^/]+$||; s|^$|.|' | sort -u)

STACK=""
[ -n "$NODE_DIRS" ] && STACK="Node.js"
grep -q '\.tsx\?$' "$WORK/all" && STACK="$STACK (TypeScript)"
[ -n "$PY_DIRS" ] && STACK="${STACK:+$STACK, }Python"
[ -n "$STACK" ] || STACK="не определён"

label() { if [ "$1" = "." ]; then printf '%s' "$2"; else printf '%s [%s]' "$2" "$1"; fi; }
logname() { printf '%s_%s' "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"; }

# ---------- Node.js / TypeScript ----------

node_checks() {
  local d="$1" s scripts deps prod_deps lock="" log cov
  cd "$d" || return
  if ! have node; then
    check "$(label "$d" "Node.js")" "пропущено" "node не установлен"
    finding "важно" "Проверки" "$(label "$d" "Node.js"): node не установлен, линтер и тесты не запускались"
    return
  fi
  pkg() { node -e "$1" 2>/dev/null; }
  scripts=$(pkg 'const s=(require("./package.json").scripts||{});for(const k of Object.keys(s)){if(!/no test specified/.test(s[k]))console.log(k)}')
  deps=$(pkg 'const p=require("./package.json");console.log(Object.keys(p.dependencies||{}).length+Object.keys(p.devDependencies||{}).length)')
  prod_deps=$(pkg 'const p=require("./package.json");console.log(Object.keys(p.dependencies||{}).length)')
  has_script() { printf '%s\n' "$scripts" | grep -qx "$1"; }
  script_text() { pkg "process.stdout.write((require('./package.json').scripts||{})['$1']||'')"; }
  bin() { [ -x "node_modules/.bin/$1" ] && printf '%s' "node_modules/.bin/$1"; }

  for f in package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb; do
    [ -f "$f" ] && { lock="$f"; break; }
  done
  if [ "${deps:-0}" -gt 0 ] && [ -z "$lock" ]; then
    finding "важно" "Сопровождение" "$(label "$d" "Node.js"): нет файла блокировки версий (package-lock.json): сборка на сервере может взять другие версии библиотек"
  fi

  # Аудит зависимостей — не требует node_modules
  if [ "$RUN_TOOLS" = 1 ]; then
    if [ "${prod_deps:-0}" = 0 ]; then
      check "$(label "$d" "Уязвимости зависимостей")" "ок" "рабочих зависимостей нет"
    elif [ "$lock" = "package-lock.json" ] || [ "$lock" = "npm-shrinkwrap.json" ]; then
      log=$(logname audit "$d")
      run "$log" npm audit --omit=dev --json
      local counts
      counts=$(node -e 'let j;try{j=JSON.parse(require("fs").readFileSync(0,"utf8"))}catch(e){process.exit(1)}if(j.error)process.exit(1);const v=(j.metadata||{}).vulnerabilities||{};console.log([v.critical||0,v.high||0,v.moderate||0,v.low||0].join(" "))' < "$WORK/$log.log" 2>/dev/null)
      if [ -z "$counts" ]; then
        check "$(label "$d" "Уязвимости зависимостей")" "пропущено" "npm audit не ответил (нет сети?)"
        finding "важно" "Безопасность" "$(label "$d" "Node.js"): npm audit не выполнился — проверьте уязвимости вручную: npm audit --omit=dev"
      else
        # shellcheck disable=SC2086 # четыре числа через пробел
        set -- $counts
        if [ "$1" -gt 0 ]; then
          check "$(label "$d" "Уязвимости зависимостей")" "ошибка" "критических $1, высоких $2, средних $3"
          finding "блокирует" "Безопасность" "$(label "$d" "Node.js"): критических уязвимостей в рабочих зависимостях — $1 (npm audit --omit=dev; чинить: npm audit fix или обновить пакет)"
        elif [ "$2" -gt 0 ]; then
          check "$(label "$d" "Уязвимости зависимостей")" "замечания" "высоких $2, средних $3"
          finding "важно" "Безопасность" "$(label "$d" "Node.js"): высоких уязвимостей в рабочих зависимостях — $2"
        else
          check "$(label "$d" "Уязвимости зависимостей")" "ок" "критических и высоких нет (средних $3, низких $4)"
          [ "$3" -gt 0 ] && finding "потом" "Безопасность" "$(label "$d" "Node.js"): средних уязвимостей — $3, обновить при плановом обновлении"
        fi
      fi
    else
      check "$(label "$d" "Уязвимости зависимостей")" "пропущено" "нет package-lock.json; для pnpm/yarn: pnpm audit --prod / yarn npm audit"
      finding "важно" "Безопасность" "$(label "$d" "Node.js"): уязвимости зависимостей не проверены автоматически"
    fi
  fi

  [ "$RUN_TOOLS" = 1 ] || return
  if [ "${deps:-0}" -gt 0 ] && [ ! -d node_modules ]; then
    check "$(label "$d" "Линтер, типы, тесты")" "пропущено" "зависимости не установлены: выполните npm ci"
    finding "важно" "Проверки" "$(label "$d" "Node.js"): зависимости не установлены (npm ci), линтер, проверка типов и тесты не запускались"
    return
  fi

  # Линтер
  log=$(logname lint "$d")
  if has_script lint; then
    if run "$log" npm run -s lint; then check "$(label "$d" "Линтер")" "ок" "npm run lint"
    else check "$(label "$d" "Линтер")" "замечания" "npm run lint"; attach_log "$log" "$(label "$d" "Линтер")"
      finding "важно" "Сопровождение" "$(label "$d" "Node.js"): линтер нашёл ошибки (npm run lint)"; fi
  elif bin eslint >/dev/null && ls eslint.config.* .eslintrc* >/dev/null 2>&1; then
    if run "$log" "$(bin eslint)" .; then check "$(label "$d" "Линтер")" "ок" "eslint"
    else check "$(label "$d" "Линтер")" "замечания" "eslint"; attach_log "$log" "$(label "$d" "Линтер")"
      finding "важно" "Сопровождение" "$(label "$d" "Node.js"): eslint нашёл ошибки"; fi
  else
    check "$(label "$d" "Линтер")" "пропущено" "не настроен (нет скрипта lint)"
    finding "потом" "Сопровождение" "$(label "$d" "Node.js"): линтер не настроен — добавить eslint и скрипт lint"
  fi

  # Форматирование
  log=$(logname fmt "$d")
  s=""
  for k in format:check fmt:check prettier:check; do has_script "$k" && { s="$k"; break; }; done
  if [ -n "$s" ]; then
    if run "$log" npm run -s "$s"; then check "$(label "$d" "Форматирование")" "ок" "npm run $s"
    else check "$(label "$d" "Форматирование")" "замечания" "npm run $s"
      finding "потом" "Сопровождение" "$(label "$d" "Node.js"): код не отформатирован ($s)"; fi
  elif bin prettier >/dev/null && { ls .prettierrc* prettier.config.* >/dev/null 2>&1 || grep -q '"prettier"' package.json; }; then
    if run "$log" "$(bin prettier)" --check .; then check "$(label "$d" "Форматирование")" "ок" "prettier --check"
    else check "$(label "$d" "Форматирование")" "замечания" "prettier --check"
      finding "потом" "Сопровождение" "$(label "$d" "Node.js"): код не отформатирован (prettier --write .)"; fi
  else
    check "$(label "$d" "Форматирование")" "пропущено" "не настроено"
  fi

  # Проверка типов
  log=$(logname types "$d")
  s=""
  for k in typecheck type-check check-types tsc; do has_script "$k" && { s="$k"; break; }; done
  if [ -n "$s" ]; then
    if run "$log" npm run -s "$s"; then check "$(label "$d" "Типы")" "ок" "npm run $s"
    else check "$(label "$d" "Типы")" "ошибка" "npm run $s"; attach_log "$log" "$(label "$d" "Типы")"
      finding "блокирует" "Корректность" "$(label "$d" "Node.js"): ошибки типов ($s) — код обращается к полям и функциям не так, как они объявлены"; fi
  elif [ -f tsconfig.json ] && bin tsc >/dev/null; then
    if run "$log" "$(bin tsc)" --noEmit -p tsconfig.json; then check "$(label "$d" "Типы")" "ок" "tsc --noEmit"
    else check "$(label "$d" "Типы")" "ошибка" "tsc --noEmit"; attach_log "$log" "$(label "$d" "Типы")"
      finding "блокирует" "Корректность" "$(label "$d" "Node.js"): ошибки типов (tsc --noEmit)"; fi
  elif [ -f tsconfig.json ]; then
    check "$(label "$d" "Типы")" "пропущено" "typescript не установлен в проекте"
    finding "важно" "Проверки" "$(label "$d" "Node.js"): проверка типов не запускалась (нет typescript в devDependencies)"
  else
    check "$(label "$d" "Типы")" "не требуется" "проект на JavaScript без TypeScript"
  fi

  # Тесты и покрытие
  log=$(logname tests "$d")
  if has_script test; then
    local t ok=1
    t=$(script_text test)
    case "$t" in
      *jest*) run "$log" npm test -- --coverage --coverageReporters=text-summary || ok=0 ;;
      *vitest*)
        if [ -d node_modules/@vitest/coverage-v8 ] || [ -d node_modules/@vitest/coverage-istanbul ]; then
          run "$log" npm test -- --run --coverage --coverage.reporter=text-summary || ok=0
        else
          run "$log" npm test -- --run || ok=0
        fi ;;
      "node --test"*) run "$log" sh -c "$(printf '%s' "$t" | sed 's/^node --test/node --test --experimental-test-coverage/')" || ok=0 ;;
      *) run "$log" npm test || ok=0 ;;
    esac
    # jest/vitest: «Lines : 85.7% ( 6/7 )»; node --test: «all files | 85.71 | ...»
    cov=$(sed "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$WORK/$log.log" | awk -F'|' '
      /^[[:space:]]*Lines[[:space:]]*:/ { sub(/^[[:space:]]*Lines[[:space:]]*:[[:space:]]*/, ""); split($0, x, " "); print "покрытие строк " x[1]; exit }
      /all files[[:space:]]*\|/ { v = $2; gsub(/[[:space:]]/, "", v); print "покрытие строк " v "%"; exit }')
    [ -n "$cov" ] || cov="покрытие не измерено"
    if [ "$ok" = 1 ]; then
      check "$(label "$d" "Тесты")" "ок" "$cov"
    else
      check "$(label "$d" "Тесты")" "ошибка" "$cov"; attach_log "$log" "$(label "$d" "Тесты")"
      finding "блокирует" "Тесты" "$(label "$d" "Node.js"): тесты падают (npm test)"
    fi
  else
    check "$(label "$d" "Тесты")" "пропущено" "нет скрипта test"
    finding "важно" "Тесты" "$(label "$d" "Node.js"): автотестов нет — минимум: главный путь пользователя (Playwright) и проверка ролей на сервере"
  fi
}

# ---------- Python ----------

pytool() {
  local d
  for d in .venv/bin venv/bin; do
    [ -x "$d/$1" ] && { printf '%s' "$d/$1"; return 0; }
  done
  command -v "$1" 2>/dev/null
}

python_checks() {
  local d="$1" t log cov rc
  cd "$d" || return

  # Аудит зависимостей
  if [ "$RUN_TOOLS" = 1 ]; then
    log=$(logname pipaudit "$d")
    if t=$(pytool pip-audit); then
      if [ -f requirements.txt ]; then run "$log" "$t" -r requirements.txt --progress-spinner off; rc=$?
      else run "$log" "$t" . --progress-spinner off; rc=$?; fi
      if [ "$rc" = 0 ]; then
        check "$(label "$d" "Уязвимости зависимостей")" "ок" "pip-audit"
      elif grep -qiE 'vulnerabilit(y|ies)|GHSA-|PYSEC-|CVE-' "$WORK/$log.log"; then
        check "$(label "$d" "Уязвимости зависимостей")" "замечания" "pip-audit нашёл уязвимости"; attach_log "$log" "$(label "$d" "pip-audit")"
        finding "важно" "Безопасность" "$(label "$d" "Python"): pip-audit нашёл уязвимые пакеты — проверьте по CVE, критические чинить до выкладки (тогда это «блокирует»)"
      else
        check "$(label "$d" "Уязвимости зависимостей")" "пропущено" "pip-audit не выполнился (нет сети?)"; attach_log "$log" "$(label "$d" "pip-audit")"
        finding "важно" "Безопасность" "$(label "$d" "Python"): уязвимости зависимостей не проверены"
      fi
    else
      check "$(label "$d" "Уязвимости зависимостей")" "пропущено" "pip-audit не установлен (pipx run pip-audit -r requirements.txt)"
      finding "важно" "Безопасность" "$(label "$d" "Python"): уязвимости зависимостей не проверены — нет pip-audit"
    fi
  fi

  [ "$RUN_TOOLS" = 1 ] || return

  # Линтер
  log=$(logname pylint "$d")
  if t=$(pytool ruff); then
    if run "$log" "$t" check .; then check "$(label "$d" "Линтер")" "ок" "ruff check"
    else check "$(label "$d" "Линтер")" "замечания" "ruff check"; attach_log "$log" "$(label "$d" "Линтер (ruff)")"
      finding "важно" "Сопровождение" "$(label "$d" "Python"): ruff нашёл ошибки (ruff check .)"; fi
  elif t=$(pytool flake8); then
    if run "$log" "$t" .; then check "$(label "$d" "Линтер")" "ок" "flake8"
    else check "$(label "$d" "Линтер")" "замечания" "flake8"; attach_log "$log" "$(label "$d" "Линтер (flake8)")"
      finding "важно" "Сопровождение" "$(label "$d" "Python"): flake8 нашёл ошибки"; fi
  else
    check "$(label "$d" "Линтер")" "пропущено" "нет ruff или flake8"
    finding "потом" "Сопровождение" "$(label "$d" "Python"): линтер не настроен — добавить ruff"
  fi

  # Форматирование
  log=$(logname pyfmt "$d")
  if t=$(pytool ruff); then
    if run "$log" "$t" format --check .; then check "$(label "$d" "Форматирование")" "ок" "ruff format --check"
    else check "$(label "$d" "Форматирование")" "замечания" "ruff format --check"
      finding "потом" "Сопровождение" "$(label "$d" "Python"): код не отформатирован (ruff format .)"; fi
  elif t=$(pytool black); then
    if run "$log" "$t" --check .; then check "$(label "$d" "Форматирование")" "ок" "black --check"
    else check "$(label "$d" "Форматирование")" "замечания" "black --check"
      finding "потом" "Сопровождение" "$(label "$d" "Python"): код не отформатирован (black .)"; fi
  else
    check "$(label "$d" "Форматирование")" "пропущено" "нет ruff или black"
  fi

  # Типы — только если проект их настроил, иначе шум
  log=$(logname pytypes "$d")
  if [ -f mypy.ini ] || grep -qs '^\[tool\.mypy\]' pyproject.toml || grep -qs '^\[mypy\]' setup.cfg; then
    if t=$(pytool mypy); then
      if run "$log" "$t" .; then check "$(label "$d" "Типы")" "ок" "mypy"
      else check "$(label "$d" "Типы")" "ошибка" "mypy"; attach_log "$log" "$(label "$d" "Типы (mypy)")"
        finding "блокирует" "Корректность" "$(label "$d" "Python"): ошибки типов (mypy)"; fi
    else
      check "$(label "$d" "Типы")" "пропущено" "mypy настроен, но не установлен"
      finding "важно" "Проверки" "$(label "$d" "Python"): проверка типов не запускалась"
    fi
  else
    check "$(label "$d" "Типы")" "пропущено" "mypy не настроен"
    finding "потом" "Сопровождение" "$(label "$d" "Python"): проверка типов не настроена (mypy в pyproject.toml)"
  fi

  # Тесты и покрытие
  log=$(logname pytests "$d")
  if find . -path ./node_modules -prune -o -path ./.venv -prune -o -path ./venv -prune -o \( -name 'test_*.py' -o -name '*_test.py' \) -type f -print 2>/dev/null | grep -q .; then
    if t=$(pytool pytest); then
      if "$t" --help 2>/dev/null | grep -q -- '--cov='; then
        run "$log" "$t" -q --cov=. --cov-report=term; rc=$?
      else
        run "$log" "$t" -q; rc=$?
      fi
      cov=$(grep -E '^TOTAL' "$WORK/$log.log" | awk '{print "покрытие строк " $NF}')
      [ -n "$cov" ] || cov="покрытие не измерено (нет pytest-cov)"
      if [ "$rc" = 0 ]; then
        check "$(label "$d" "Тесты")" "ок" "$(tail -n 1 "$WORK/$log.log" | sed 's/=//g; s/^ *//') · $cov"
      elif [ "$rc" = 5 ]; then
        check "$(label "$d" "Тесты")" "пропущено" "pytest не нашёл тестов"
        finding "важно" "Тесты" "$(label "$d" "Python"): файлы тестов есть, но pytest их не собрал"
      else
        check "$(label "$d" "Тесты")" "ошибка" "$cov"; attach_log "$log" "$(label "$d" "Тесты (pytest)")"
        finding "блокирует" "Тесты" "$(label "$d" "Python"): тесты падают (pytest)"
      fi
    else
      check "$(label "$d" "Тесты")" "пропущено" "pytest не установлен"
      finding "важно" "Тесты" "$(label "$d" "Python"): тесты есть, но не запускались — нет pytest"
    fi
  else
    check "$(label "$d" "Тесты")" "пропущено" "файлов test_*.py нет"
    finding "важно" "Тесты" "$(label "$d" "Python"): автотестов нет — минимум: главный путь пользователя и проверка ролей на сервере"
  fi
}

for d in $NODE_DIRS; do ( node_checks "$d" ); done
for d in $PY_DIRS; do ( python_checks "$d" ); done
if [ -z "$NODE_DIRS$PY_DIRS" ]; then
  check "Стек" "пропущено" "нет package.json, pyproject.toml или requirements.txt — линтер и тесты не запускались"
fi

# ---------- Секреты ----------

grep -v -E "(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Pipfile\.lock|uv\.lock)$|\.min\.js$|\.map$|(^|/)\.env\.(example|sample|template)$|(^|/)${SELF_NAME}$" "$WORK/scope" > "$WORK/scope_secrets" || true

STRICT='-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}|xox[baprs]-[A-Za-z0-9-]{10,}|(sk|rk)_live_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|sk-ant-[A-Za-z0-9_-]{20,}|sk-(proj-)?[A-Za-z0-9_-]{40,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{33}|glpat-[A-Za-z0-9_-]{20}'
GENERIC='(password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$<{[:space:]]{8,}["'"'"']'
DBURL='(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqp)://[^:/@[:space:]"'"'"']+:[^@/[:space:]"'"'"'$<{]{3,}@'
PLACEHOLDER='example|changeme|change_me|your[_-]|xxx|<[^>]+>|\$\{|dummy|placeholder|password@|pass@|secret@|test@|postgres:postgres@'

secret_hits() { # secret_hits <regex> <extra grep flags> — печатает только file:line
  grep_list "$WORK/scope_secrets" "$1" ${2:+"$2"} | grep -viE "$PLACEHOLDER" | cut -d: -f1,2
}

if have gitleaks; then
  if [ "$IS_GIT" = 1 ]; then
    run gitleaks gitleaks detect --source . --redact --no-banner --report-format json --report-path "$WORK/gitleaks.json" --exit-code 3
  else
    run gitleaks gitleaks detect --source . --no-git --redact --no-banner --report-format json --report-path "$WORK/gitleaks.json" --exit-code 3
  fi
  rc=$?
  if [ "$rc" = 0 ]; then
    check "Секреты (gitleaks, с историей git)" "ок" "утечек не найдено"
  elif [ "$rc" = 3 ]; then
    n=$(grep -o '"RuleID"' "$WORK/gitleaks.json" | wc -l | tr -d ' ')
    where=""
    if have python3; then
      where=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(", ".join(sorted({"%s:%s%s" % (x.get("File"), x.get("StartLine"), " (коммит %s)" % x["Commit"][:7] if x.get("Commit") else "") for x in d})[:10]))' "$WORK/gitleaks.json" 2>/dev/null)
    fi
    check "Секреты (gitleaks, с историей git)" "ошибка" "найдено: $n"
    finding "блокирует" "Безопасность" "gitleaks: похожих на ключи мест — $n${where:+: $where}. Ключ из истории git скомпрометирован: перевыпустить в кабинете сервиса, потом убрать из кода"
  else
    check "Секреты (gitleaks)" "пропущено" "gitleaks завершился с ошибкой $rc"; attach_log gitleaks "gitleaks"
  fi
else
  secret_hits "$STRICT" > "$WORK/strict_hits"
  secret_hits "$GENERIC" -i | grep -vxFf "$WORK/strict_hits" > "$WORK/generic_hits"
  secret_hits "$DBURL" > "$WORK/dburl_hits"
  ns=$(grep -c . "$WORK/strict_hits"); ng=$(grep -c . "$WORK/generic_hits"); nd=$(grep -c . "$WORK/dburl_hits")
  hist=0
  if [ "$IS_GIT" = 1 ]; then
    if [ -n "$SINCE" ]; then range="$SINCE..HEAD"; else range="--all"; fi
    hist=$(git log -p --no-color --no-ext-diff -n 500 "$range" -- . ':(exclude)*lock*' ":(exclude)*${SELF_NAME}" 2>/dev/null \
      | grep -E '^[+-]' | grep -E -e "$STRICT" | grep -cviE "$PLACEHOLDER")
  fi
  if [ "$ns" -gt 0 ]; then
    finding "блокирует" "Безопасность" "ключи или токены в файлах — $ns: $(head -n 10 "$WORK/strict_hits" | tr '\n' ' ')— перевыпустить ключ, перенести в .env на сервере"
  fi
  if [ "${hist:-0}" -gt 0 ]; then
    finding "блокирует" "Безопасность" "в истории git строк, похожих на ключи, — $hist (git log -p | поиск). Удаление строки не помогает: ключ перевыпустить"
  fi
  if [ "$nd" -gt 0 ]; then
    finding "важно" "Безопасность" "строка подключения к базе с паролем в коде — $nd: $(head -n 5 "$WORK/dburl_hits" | tr '\n' ' ')— перенести в переменную окружения"
  fi
  if [ "$ng" -gt 0 ]; then
    finding "важно" "Безопасность" "похоже на пароль или ключ в коде — $ng: $(head -n 10 "$WORK/generic_hits" | tr '\n' ' ')— проверить глазами (может быть ложное срабатывание)"
  fi
  if [ $((ns + ${hist:-0})) -gt 0 ]; then st="ошибка"; elif [ $((ng + nd)) -gt 0 ]; then st="замечания"; else st="ок"; fi
  check "Секреты (поиск по шаблонам; gitleaks не установлен)" "$st" "в файлах: точных $ns, похожих $((ng + nd)); в истории git: ${hist:-0}"
fi

# .env в git и .gitignore
if [ "$IS_GIT" = 1 ]; then
  tracked_env=$(git ls-files | grep -E '(^|/)\.env(\.[^/]*)?$' | grep -vE '\.(example|sample|template|dist)$' | tr '\n' ' ')
  if [ -n "$tracked_env" ]; then
    finding "блокирует" "Безопасность" "файлы окружения лежат в git: $tracked_env— убрать (git rm --cached), добавить в .gitignore, все ключи из них перевыпустить"
    check "Файлы .env вне git" "ошибка" "$tracked_env"
  else
    check "Файлы .env вне git" "ок" "в git нет .env"
  fi
fi
if ! grep -qsE '^/?\.env' .gitignore; then
  finding "важно" "Безопасность" ".env не записан в .gitignore — следующий коммит может унести ключи в репозиторий"
fi
grep -E '\.(js|mjs|cjs|ts|tsx|jsx|py)$' "$WORK/all" > "$WORK/envcode" || true
if [ ! -f .env.example ] && [ ! -f .env.sample ] && [ -n "$(grep_list "$WORK/envcode" 'process\.env|import\.meta\.env|os\.environ|os\.getenv' | head -n 1)" ]; then
  finding "потом" "Сопровождение" "нет .env.example: новому разработчику и серверу непонятно, какие переменные нужны"
fi

# ---------- Миграции базы ----------

grep -E '(^|/)(migrations?|migrate|alembic/versions|db/migrate|prisma/migrations|supabase/migrations|sql/migrations|flyway|liquibase)/.*\.(sql|py|ts|js)$|(^|/)[^/]*migration[^/]*\.sql$' "$WORK/scope" > "$WORK/migrations" || true
nm=$(grep -c . "$WORK/migrations")
if [ "$nm" = 0 ]; then
  check "Безопасность миграций" "не требуется" "файлов миграций в проверяемых файлах нет"
else
  : > "$WORK/mig_hits"
  while IFS= read -r f; do
    # Таблицы, созданные в этом же файле, — новые: к ним правила «большой таблицы» не относятся
    created=$(grep -ioE 'create table( if not exists)?[[:space:]]+[A-Za-z0-9_."]+|create_table\([[:space:]]*["'"'"'][A-Za-z0-9_]+' "$f" \
      | sed -E 's/.*[[:space:]("'"'"']//; s/"//g; s/.*\.//' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')
    awk -v file="$f" -v created=" $created " '
      function report(rule, text) { printf "%s:%d\t%s\t%s\n", file, NR, rule, text }
      function newtable(l,   m, t) {
        if (match(l, /(alter table|[ \t]on)( only)?( if exists)?[ \t]+[a-z0-9_."]+/)) {
          m = substr(l, RSTART, RLENGTH); sub(/.*[ \t]/, "", m); gsub(/"/, "", m); sub(/.*\./, "", m)
          return index(created, " " m " ") > 0
        }
        return 0
      }
      {
        l = tolower($0)
        sub(/--.*/, "", l)
        if (l ~ /^[ \t]*#/) next
        if (l ~ /drop[ \t]+table/ || l ~ /op\.drop_table/ || l ~ /migrations\.deletemodel/)
          report("DROP TABLE", "удаление таблицы — это шаг «contract»: только после релиза, в котором код уже не читает таблицу, и после свежей копии")
        if (l ~ /drop[ \t]+column/ || l ~ /op\.drop_column/ || l ~ /migrations\.removefield/)
          report("DROP COLUMN", "удаление колонки ломает работающую сейчас версию и откат кода: сначала релиз без использования колонки, удаление — следующим релизом (expand/contract)")
        if (l ~ /alter[ \t]+column.*[ \t]type[ \t]/ || l ~ /alter[ \t]+type/ || (l ~ /op\.alter_column/ && l ~ /type_/))
          report("ALTER TYPE", "смена типа переписывает таблицу под блокировкой и ломает старый код: новая колонка, двойная запись, перенос данных партиями, переключение, удаление старой")
        if (l ~ /rename[ \t]+column/ || l ~ /rename[ \t]+to/ || l ~ /migrations\.rename(field|model)/ || (l ~ /op\.alter_column/ && l ~ /new_column_name/))
          report("RENAME", "переименование ломает работающую версию кода и откат: добавить новое имя, писать в оба, переключить чтение, старое удалить потом")
        if ((l ~ /add[ \t]+column/ || l ~ /op\.add_column/) && (l ~ /not[ \t]+null/ || l ~ /nullable[ \t]*=[ \t]*false/) && l !~ /default/ && !newtable(l))
          report("NOT NULL без DEFAULT", "на таблице с данными упадёт или заблокирует запись: добавить колонку без NOT NULL, заполнить партиями, потом ограничение")
        if (l ~ /set[ \t]+not[ \t]+null/ && !newtable(l))
          report("SET NOT NULL", "проверка всей таблицы под блокировкой: сначала CHECK (col IS NOT NULL) NOT VALID, затем VALIDATE CONSTRAINT")
        if (((l ~ /create[ \t]+(unique[ \t]+)?index/ && l !~ /concurrently/) || (l ~ /op\.create_index/ && l !~ /postgresql_concurrently/)) && !newtable(l))
          report("INDEX без CONCURRENTLY", "на большой таблице блокирует запись на время построения: CREATE INDEX CONCURRENTLY вне транзакции миграции")
        if (l ~ /add[ \t]+constraint/ && (l ~ /foreign[ \t]+key/ || l ~ /check[ \t]*\(/) && l !~ /not[ \t]+valid/ && !newtable(l))
          report("CONSTRAINT без NOT VALID", "проверка всех строк под блокировкой: добавить NOT VALID, потом VALIDATE CONSTRAINT отдельным шагом")
        if (l ~ /^[ \t]*truncate/ || (l ~ /^[ \t]*delete[ \t]+from/ && l !~ /where/))
          report("Удаление данных", "TRUNCATE или DELETE без WHERE в миграции: данные не вернутся без копии")
        if (l ~ /^[ \t]*update[ \t]/ && l !~ /where/)
          report("UPDATE всей таблицы", "одним запросом блокирует таблицу: переносить данные партиями отдельной задачей (backfill)")
      }' "$f" >> "$WORK/mig_hits"
  done < "$WORK/migrations"
  nh=$(grep -c . "$WORK/mig_hits")
  if [ "$nh" = 0 ]; then
    check "Безопасность миграций" "ок" "файлов миграций: $nm, опасных операций не найдено"
  else
    check "Безопасность миграций" "замечания" "файлов миграций: $nm, предупреждений: $nh"
    while IFS="$(printf '\t')" read -r where rule text; do
      finding "важно" "Данные и миграции" "$where — $rule: $text"
    done < "$WORK/mig_hits"
  fi
fi

# ---------- Dockerfile и compose ----------

grep -E '(^|/)(Dockerfile[^/]*|[^/]+\.Dockerfile|Containerfile)$' "$WORK/scope" > "$WORK/dockerfiles" || true
ndf=$(grep -c . "$WORK/dockerfiles")
if [ "$ndf" = 0 ]; then
  if grep -qE '(^|/)Dockerfile' "$WORK/all"; then
    check "Dockerfile" "не требуется" "Dockerfile с прошлого ревью не менялся"
  else
    check "Dockerfile" "не требуется" "Dockerfile нет"
    finding "потом" "Выкладка" "нет Dockerfile — для выкладки на свой сервер он понадобится (/airl-devops, часть 0)"
  fi
else
  before=$(grep -c . "$WORK/findings")
  while IFS= read -r f; do
    awk -v file="$f" '
      BEGIN { secret = "(password|passwd|secret|token|api_?key|access_?key|private_?key|client_?secret|dsn|database_url)" }
      {
        line = $0; l = tolower($0)
        if (l ~ /^[ \t]*from[ \t]/) {
          n = split(line, a, /[ \t]+/); img = ""
          for (i = 2; i <= n; i++) { if (a[i] ~ /^--/) continue; img = a[i]; break }
          if (tolower(a[n-1]) == "as") stages[tolower(a[n])] = 1
          lastuser = ""; final_from = NR
          li = tolower(img)
          if (li == "scratch" || (li in stages) || img ~ /^\$/) next
          if (img ~ /@sha256:/) next
          base = img; sub(/.*\//, "", base)
          if (base !~ /:/ || base ~ /:latest$/)
            printf "важно\t%s:%d\tбазовый образ %s без версии: сборка завтра может дать другой результат — указать версию (node:22-slim) или хеш @sha256\n", file, NR, img
        }
        if (l ~ /^[ \t]*user[ \t]/) { u = l; sub(/^[ \t]*user[ \t]+/, "", u); sub(/[ \t].*/, "", u); lastuser = u }
        if (l ~ /^[ \t]*env[ \t]/ && l ~ secret) {
          rest = l; sub(/^[ \t]*env[ \t]+/, "", rest)
          if (rest ~ secret "[ \t]*[= ][ \t]*[^ \t$]")
            printf "блокирует\t%s:%d\tсекрет зашит в образ через ENV: его видит любой, у кого есть образ (docker history). Передавать через env_file на сервере\n", file, NR
        }
        if (l ~ /^[ \t]*arg[ \t]/ && l ~ secret)
          printf "важно\t%s:%d\tсекрет через ARG остаётся в истории образа — использовать RUN --mount=type=secret\n", file, NR
        if (l ~ /^[ \t]*(copy|add)[ \t]/ && l ~ /(^|[ \t\/])\.env([ \t]|$)/)
          printf "блокирует\t%s:%d\tфайл .env копируется в образ — ключи уедут в реестр\n", file, NR
      }
      END {
        if (lastuser == "" || lastuser == "root" || lastuser == "0" || lastuser ~ /^0:/)
          printf "важно\t%s:%d\tпроцесс в контейнере работает от root: добавить USER (например, USER node или свой пользователь) в последнем этапе\n", file, final_from
      }' "$f" | while IFS="$(printf '\t')" read -r sev where text; do
        finding "$sev" "Выкладка" "$where — $text"
      done
    dir=$(dirname "$f")
    if [ ! -f "$dir/.dockerignore" ]; then
      finding "важно" "Выкладка" "$dir: нет .dockerignore — в образ попадут .env, .git и node_modules"
    elif ! grep -qE '^\*?\*?/?\.env' "$dir/.dockerignore"; then
      finding "важно" "Выкладка" "$dir/.dockerignore не исключает .env"
    fi
  done < "$WORK/dockerfiles"
  after=$(grep -c . "$WORK/findings")
  if [ "$after" -gt "$before" ]; then
    check "Dockerfile" "замечания" "файлов: $ndf, замечаний: $((after - before))"
  else
    check "Dockerfile" "ок" "файлов: $ndf: не root, версии образов указаны, секретов нет"
  fi
fi

grep -E '(^|/)(docker-)?compose[^/]*\.ya?ml$' "$WORK/scope" > "$WORK/compose" || true
if [ -s "$WORK/compose" ]; then
  grep_list "$WORK/compose" '^[[:space:]]*-[[:space:]]*"?([0-9.]+:)?[0-9]+:(5432|3306|6379|27017|9092|9200|8123|5672|15672|9000|9090|3100)"?[[:space:]]*$' \
    | grep -v '127\.0\.0\.1:' | cut -d: -f1,2 > "$WORK/compose_ports"
  if [ -s "$WORK/compose_ports" ]; then
    finding "блокирует" "Безопасность" "порт базы или служебной системы открыт наружу в compose: $(tr '\n' ' ' < "$WORK/compose_ports")— Docker публикует порты в обход межсетевого экрана; убрать ports или привязать к 127.0.0.1"
    check "Порты в docker compose" "ошибка" "наружу открыты служебные порты"
  else
    check "Порты в docker compose" "ок" "базы и служебные системы наружу не открыты"
  fi
  # образ без метки (после последней «/» нет «:») или с меткой latest
  grep_list "$WORK/compose" '^[[:space:]]*image:[[:space:]]*["'"'"']?([^[:space:]"'"'"'#]*/)?[^/:[:space:]"'"'"'#@]+["'"'"']?[[:space:]]*(#.*)?$' | cut -d: -f1,2 > "$WORK/compose_latest"
  grep_list "$WORK/compose" 'image:[[:space:]]*[^[:space:]]+:latest' | cut -d: -f1,2 >> "$WORK/compose_latest"
  if [ -s "$WORK/compose_latest" ]; then
    finding "важно" "Выкладка" "образ без версии или latest в compose: $(sort -u "$WORK/compose_latest" | tr '\n' ' ')— откат на предыдущую версию невозможен"
  fi
fi

# ---------- /healthz ----------

grep -E '\.(js|mjs|cjs|ts|tsx|jsx|py|go|rb|php|java|kt|cs|rs)$' "$WORK/all" | grep -vE '(^|/)(tests?|__tests__|e2e|spec)/|\.(test|spec)\.' > "$WORK/code"
hz=$(grep_list "$WORK/code" 'healthz' | cut -d: -f1,2 | head -n 3 | tr '\n' ' ')
if [ -n "$hz" ]; then
  check "Адрес /healthz в коде" "ок" "$hz"
elif [ -s "$WORK/code" ]; then
  check "Адрес /healthz в коде" "ошибка" "не найден"
  finding "блокирует" "Надёжность" "нет адреса /healthz: выкладка не сможет проверить новую версию и откатиться, мониторинг не узнает о падении (/airl-pwa, часть 5)"
else
  check "Адрес /healthz в коде" "пропущено" "файлов кода не найдено"
fi

if [ -n "$URL" ]; then
  if have curl; then
    code=$(curl -sS -o "$WORK/healthz_body" -w '%{http_code}' -m 10 "$URL/healthz" 2>"$WORK/healthz_err")
    if [ "$code" = 200 ] && grep -q '"status"' "$WORK/healthz_body"; then
      check "Живой $URL/healthz" "ок" "200: $(head -c 200 "$WORK/healthz_body" | tr '\n' ' ')"
    else
      check "Живой $URL/healthz" "ошибка" "ответ ${code:-нет}"
      finding "блокирует" "Надёжность" "$URL/healthz отвечает ${code:-нет ответа} вместо 200 с полем status"
    fi
  else
    check "Живой $URL/healthz" "пропущено" "нет curl"
  fi
fi

# ---------- Отчёт ----------

nb=$(grep -c '^блокирует' "$WORK/findings")
ni=$(grep -c '^важно' "$WORK/findings")
nl=$(grep -c '^потом' "$WORK/findings")
nsk=$(grep -c "$(printf '\t')пропущено$(printf '\t')" "$WORK/checks")

{
  echo "# Автоматические проверки перед ревью"
  echo
  echo "**Дата**: $(date +%F) · **Коммит**: $COMMIT · **Стек**: $STACK · **Объём**: $SCOPE_TEXT"
  echo
  echo "**Итог**: блокирующих — $nb · важных — $ni · на потом — $nl · проверок пропущено — $nsk"
  if [ "$nb" -gt 0 ]; then
    echo
    echo "Есть блокирующие находки: выкладывать и подключать к хабу нельзя, пока они не исправлены."
  fi
  if [ "$nsk" -gt 0 ]; then
    echo
    echo "Пропущенная проверка — не зелёный результат, а дыра: её закрывает ручное ревью или установка инструмента."
  fi
  echo
  echo "## Проверки"
  echo
  echo "| Проверка | Итог | Подробности |"
  echo "|---|---|---|"
  while IFS="$(printf '\t')" read -r name st detail; do
    printf '| %s | %s | %s |\n' "$name" "$st" "$(printf '%s' "$detail" | sed 's/|/\\|/g')"
  done < "$WORK/checks"
  for sev in блокирует важно потом; do
    if grep -q "^$sev" "$WORK/findings"; then
      echo
      case "$sev" in
        блокирует) echo "## Блокирует" ;;
        важно) echo "## Важно" ;;
        потом) echo "## Потом" ;;
      esac
      echo
      grep "^$sev" "$WORK/findings" | while IFS="$(printf '\t')" read -r _ area text; do
        printf -- '- **%s**: %s\n' "$area" "$text"
      done
    fi
  done
  if [ -s "$WORK/logs.md" ]; then
    echo
    echo "## Вывод инструментов (последние строки)"
    cat "$WORK/logs.md"
  fi
} > "$WORK/report.md"

cat "$WORK/report.md"
if [ -n "$OUT" ]; then
  cp "$WORK/report.md" "$OUT" && echo && echo "Отчёт сохранён: $OUT" >&2
fi

[ "$nb" -gt 0 ] && exit 1
exit 0
