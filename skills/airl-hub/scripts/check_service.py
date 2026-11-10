#!/usr/bin/env python3
"""Проверка сервиса отдела перед подключением к хабу AIRL.

Только стандартная библиотека Python 3.8+.

  python3 check_service.py --service airl.service.json --map COMPANY_MAP.md \
      [--registry hub/services.json] [--url https://hub.company.kz]

Токен тестового пользователя для /api/hub/summary берётся из AIRL_HUB_TOKEN
и никогда не печатается. Код выхода: 0 — все ворота зелёные, 1 — есть красные,
2 — ошибка запуска.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

OK, FAIL, WARN, SKIP = "ok", "FAIL", "warn", "skip"
results = []


def report(gate, status, text):
    results.append((gate, status, text))


def read_map(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    version = None
    fm = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
    if fm:
        m = re.search(r"^map_version:\s*['\"]?([\w.]+)", fm.group(1), re.M)
        if m:
            version = m.group(1)
    # Раздел 4: заголовки вида "### revenue — Выручка"
    metrics = set(re.findall(r"^###\s+`?([a-z][a-z0-9_]*)`?\s+[—-]", text, re.M))
    # Раздел 6: строки таблицы, первая ячейка — `id`
    departments = set()
    sec6 = re.search(r"^##\s*6\..*?(?=^##\s)", text, re.S | re.M)
    if sec6:
        departments = set(re.findall(r"^\|\s*`([a-z][a-z0-9_]*)`\s*\|", sec6.group(0), re.M))
    return version, metrics, departments


def check_files(svc, map_version, map_metrics, departments):
    required = ["id", "title", "department", "map_version", "version", "base_path",
                "roles", "data", "hub"]
    missing = [k for k in required if k not in svc]
    report("1 Контракт", FAIL if missing else OK,
           f"нет полей: {', '.join(missing)}" if missing else "все обязательные поля на месте")
    sid = svc.get("id", "")

    if departments:
        report("1 Контракт", OK if sid in departments else FAIL,
               f"id '{sid}' " + ("есть" if sid in departments else "НЕТ") + " в разделе 6 карты")
    else:
        report("1 Контракт", WARN, "не нашёл таблицу отделов в разделе 6 карты — проверьте вручную")

    bp = svc.get("base_path", "")
    report("1 Контракт", OK if bp == f"/{sid}" else FAIL,
           f"base_path = '{bp}', ожидается '/{sid}'")

    sv = str(svc.get("map_version", ""))
    if map_version is None:
        report("2 Та же карта", WARN, "в карте нет map_version в шапке")
    else:
        report("2 Та же карта", OK if sv == map_version else FAIL,
               f"сервис {sv} · карта {map_version}" + ("" if sv == map_version else " → /airl-spec апгрейд"))

    hub_metrics = svc.get("hub", {}).get("metrics", [])
    unknown = [m for m in hub_metrics if m not in map_metrics]
    if not hub_metrics:
        report("3 Одни цифры", FAIL, "hub.metrics пуст — нечего показать руководителю")
    elif not map_metrics:
        report("3 Одни цифры", WARN, "не нашёл показатели в разделе 4 карты (### id — Название)")
    else:
        report("3 Одни цифры", FAIL if unknown else OK,
               f"нет в карте: {', '.join(unknown)}" if unknown else f"{len(hub_metrics)} показателя из карты")

    writes = svc.get("data", {}).get("writes", [])
    allowed = f"mart_{svc.get('department', sid)}"
    bad = [w for w in writes if w.split(".")[0] != allowed]
    report("4 Свой участок", FAIL if bad else OK,
           f"пишет вне {allowed}: {', '.join(bad)}" if bad else f"пишет только в {allowed}")

    view = svc.get("roles", {}).get("view", [])
    if "ceo" not in view:
        report("10 Роли", WARN, "роль ceo не видит сервис — руководитель не увидит его в хабе")
    foreign = [r for r in view if re.match(r"^(head|staff)_", r) and not r.endswith(f"_{sid}")]
    if foreign:
        report("10 Роли", WARN, f"доступ ролям других отделов: {', '.join(foreign)} — это задумано в SPEC?")


def fetch(url, token=None, timeout=5):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            return r.status, body, time.monotonic() - start
    except urllib.error.HTTPError as e:
        return e.code, e.read(), time.monotonic() - start


def check_live(svc, base_url, map_metrics):
    hub = svc.get("hub", {})
    base = base_url.rstrip("/")

    try:
        code, body, _ = fetch(base + hub.get("health", ""))
        data = json.loads(body or b"{}")
        good = code == 200 and data.get("status") == "ok"
        report("8 Живой", OK if good else FAIL, f"/healthz → {code}, status={data.get('status')}")
        if good and data.get("version") != svc.get("version"):
            report("8 Живой", WARN, f"выложена {data.get('version')}, в манифесте {svc.get('version')}")
    except Exception as e:  # noqa: BLE001
        report("8 Живой", FAIL, f"/healthz недоступен: {type(e).__name__}")

    summary_url = base + hub.get("summary", "")
    try:
        code, _, _ = fetch(summary_url)
        report("5 Один вход", OK if code in (401, 403) else FAIL,
               f"summary без токена → {code} (ожидается 401/403)")
    except Exception as e:  # noqa: BLE001
        report("5 Один вход", FAIL, f"summary недоступен: {type(e).__name__}")
        return

    token = os.environ.get("AIRL_HUB_TOKEN")
    if not token:
        report("9 Отдаёт в хаб", SKIP, "нет AIRL_HUB_TOKEN — форму summary не проверил")
        return
    try:
        code, body, elapsed = fetch(summary_url, token)
    except Exception as e:  # noqa: BLE001
        report("9 Отдаёт в хаб", FAIL, f"summary с токеном недоступен: {type(e).__name__}")
        return
    if code != 200:
        report("9 Отдаёт в хаб", FAIL, f"summary с токеном ceo → {code}")
        return
    try:
        data = json.loads(body)
    except ValueError:
        report("9 Отдаёт в хаб", FAIL, "summary вернул не JSON")
        return

    problems = []
    if data.get("service") != svc.get("id"):
        problems.append(f"service='{data.get('service')}'")
    ts = data.get("generated_at", "")
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            problems.append("generated_at без часового пояса")
    except ValueError:
        problems.append("generated_at не ISO 8601")
    declared = set(hub.get("metrics", []))
    for m in data.get("metrics", []):
        mid = m.get("id")
        if mid not in declared or (map_metrics and mid not in map_metrics):
            problems.append(f"метрика '{mid}' не объявлена или нет в карте")
        if not isinstance(m.get("value"), (int, float)) or isinstance(m.get("value"), bool):
            problems.append(f"'{mid}'.value не число")
        if m.get("status") not in ("ok", "warning", "danger"):
            problems.append(f"'{mid}'.status не ok|warning|danger")
    if not data.get("metrics"):
        problems.append("metrics пуст")
    report("9 Отдаёт в хаб", FAIL if problems else OK,
           "; ".join(problems) if problems else f"форма верна, {len(data['metrics'])} показателя")
    report("9 Отдаёт в хаб", OK if elapsed < 1 else WARN, f"ответ за {elapsed:.2f} с (цель < 1 с)")


def check_registry(svc, path):
    try:
        with open(path, encoding="utf-8") as f:
            reg = json.load(f)
    except FileNotFoundError:
        report("Реестр", WARN, f"нет {path} — хаб ещё не создан? (/airl-hub режим A)")
        return
    services = reg.get("services", reg) if isinstance(reg, dict) else reg
    paths = {s.get("base_path"): s.get("id") for s in services if s.get("id") != svc.get("id")}
    clash = paths.get(svc.get("base_path"))
    report("Реестр", FAIL if clash else OK,
           f"base_path занят сервисом '{clash}'" if clash else "конфликтов путей нет")


def main():
    p = argparse.ArgumentParser(description="Ворота в хаб AIRL")
    p.add_argument("--service", default="airl.service.json")
    p.add_argument("--map", required=True)
    p.add_argument("--registry")
    p.add_argument("--url", help="адрес хаба, например https://hub.company.kz")
    a = p.parse_args()

    try:
        with open(a.service, encoding="utf-8") as f:
            svc = json.load(f)
        map_version, map_metrics, departments = read_map(a.map)
    except (OSError, ValueError) as e:
        print(f"Не удалось прочитать файлы: {e}", file=sys.stderr)
        return 2

    check_files(svc, map_version, map_metrics, departments)
    if a.registry:
        check_registry(svc, a.registry)
    if a.url:
        check_live(svc, a.url, map_metrics)
    else:
        report("8–9 Живые проверки", SKIP, "не передан --url")

    icon = {OK: "✔", FAIL: "✖", WARN: "!", SKIP: "–"}
    print(f"\nСервис: {svc.get('id')} v{svc.get('version')} · карта {map_version}\n")
    for gate, status, text in results:
        print(f"  {icon[status]} {gate:<20} {text}")
    fails = sum(1 for _, s, _ in results if s == FAIL)
    print("\nИтог: " + ("красных ворот нет" if not fails else f"красных: {fails} — в хаб не подключаем"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
