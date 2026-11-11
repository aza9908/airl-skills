#!/usr/bin/env python3
"""Проверка сервиса отдела перед подключением к хабу AIRL.

Только стандартная библиотека Python 3.8+.

Самопроверка в репозитории сервиса (только файлы):
  python3 check_service.py --service airl.service.json --map airl/COMPANY_MAP.md --files-only

Приёмка командой AIRL (файлы и живые адреса):
  python3 check_service.py --service airl.service.json --map COMPANY_MAP.md \
      --registry hub/services.json --url https://hub.company.kz

Токен тестового пользователя ceo для /api/hub/summary берётся из переменной
окружения AIRL_HUB_TOKEN и никогда не печатается. Он отправляется и заголовком
Authorization: Bearer, и cookie (имя cookie — параметр --cookie).

Код выхода:
  0 — все проверенные ворота зелёные (с --files-only: только файловые);
  1 — есть красные ворота;
  2 — ошибка запуска;
  3 — красных нет, но живые ворота 5, 8, 9 не проверены: подключать нельзя.
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


def section(text, number):
    """Текст раздела карты «## N. ...» до следующего заголовка второго уровня."""
    m = re.search(rf"^##\s*{number}\..*?(?=^##\s|\Z)", text, re.S | re.M)
    return m.group(0) if m else ""


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
    metrics = set(re.findall(r"^#{3,4}\s+`?([a-z][a-z0-9_]*)`?\s+[—–-]", section(text, 4), re.M))
    # Раздел 6: строки таблицы, первая ячейка — `id`
    departments = set(re.findall(r"^\|\s*`([a-z][a-z0-9_]*)`\s*\|", section(text, 6), re.M))
    return version, metrics, departments


def version_tuple(v):
    parts = re.findall(r"\d+", str(v))
    return (int(parts[0]), int(parts[1]) if len(parts) > 1 else 0) if parts else None


def check_files(svc, map_version, map_metrics, departments):
    required = ["id", "title", "department", "map_version", "version", "base_path",
                "roles", "data", "hub"]
    missing = [k for k in required if k not in svc]
    report("1 Контракт", FAIL if missing else OK,
           f"нет полей: {', '.join(missing)}" if missing else "все обязательные поля на месте")
    sid = str(svc.get("id", ""))

    if departments:
        report("1 Контракт", OK if sid in departments else FAIL,
               f"id '{sid}' " + ("есть" if sid in departments else "НЕТ") + " в разделе 6 карты")
    else:
        report("1 Контракт", FAIL, "в разделе 6 карты нет таблицы отделов с id в `кавычках`")

    bp = svc.get("base_path", "")
    report("1 Контракт", OK if bp == f"/{sid}" else FAIL,
           f"base_path = '{bp}', ожидается '/{sid}'")

    hub = svc.get("hub") if isinstance(svc.get("hub"), dict) else {}
    for key in ("health", "summary"):
        path = str(hub.get(key, ""))
        if not path.startswith(f"/{sid}/"):
            report("1 Контракт", FAIL, f"hub.{key} = '{path}', должен начинаться с '/{sid}/'")

    sv, mv = version_tuple(svc.get("map_version", "")), version_tuple(map_version)
    if mv is None:
        report("2 Та же карта", FAIL, "в карте нет map_version в шапке")
    elif sv is None:
        report("2 Та же карта", FAIL, "в airl.service.json нет map_version")
    elif sv[0] != mv[0]:
        report("2 Та же карта", FAIL,
               f"сервис {svc.get('map_version')} · карта {map_version}: изменились определения → /airl-spec апгрейд")
    elif sv != mv:
        report("2 Та же карта", WARN,
               f"сервис {svc.get('map_version')} · карта {map_version}: в карте есть дополнения → /airl-spec апгрейд")
    else:
        report("2 Та же карта", OK, f"сервис и карта на версии {map_version}")

    hub_metrics = hub.get("metrics", [])
    if not isinstance(hub_metrics, list):
        hub_metrics = []
    unknown = [m for m in hub_metrics if m not in map_metrics]
    if not hub_metrics:
        report("3 Одни цифры", FAIL, "hub.metrics пуст — нечего показать руководителю")
    elif not map_metrics:
        report("3 Одни цифры", FAIL,
               "в разделе 4 карты нет показателей вида «### id — Название»: проверить нечем")
    else:
        report("3 Одни цифры", FAIL if unknown else OK,
               f"нет в карте: {', '.join(unknown)}" if unknown
               else f"показателей из карты: {len(hub_metrics)}")

    data = svc.get("data") if isinstance(svc.get("data"), dict) else {}
    writes = data.get("writes", []) or []
    allowed = f"mart_{svc.get('department', sid)}"
    bad = [w for w in writes if str(w).split(".")[0] != allowed]
    report("4 Свой участок", FAIL if bad else OK,
           f"пишет вне {allowed}: {', '.join(map(str, bad))}" if bad else f"пишет только в {allowed}")
    reads = data.get("reads", []) or []
    bad_reads = [r for r in reads if str(r).split(".")[0] not in ("core", "metrics", allowed)]
    report("4 Свой участок", FAIL if bad_reads else OK,
           f"читает мимо core/metrics/{allowed}: {', '.join(map(str, bad_reads))}" if bad_reads
           else "читает только core, metrics и свою витрину")

    roles = svc.get("roles") if isinstance(svc.get("roles"), dict) else {}
    view = roles.get("view", []) or []
    if "ceo" not in view:
        report("10 Роли", WARN, "роль ceo не видит сервис — руководитель не увидит его в хабе")
    foreign = [r for r in view if re.match(r"^(head|staff)_", r) and not r.endswith(f"_{sid}")]
    if foreign:
        report("10 Роли", WARN, f"доступ ролям других отделов: {', '.join(foreign)} — это есть в SPEC?")


def fetch(url, token=None, cookie=None, timeout=5):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
        if cookie:
            req.add_header("Cookie", f"{cookie}={token}")
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(), time.monotonic() - start
    except urllib.error.HTTPError as e:
        return e.code, e.read(), time.monotonic() - start


def check_live(svc, base_url, map_metrics, cookie):
    hub = svc.get("hub") if isinstance(svc.get("hub"), dict) else {}
    base = base_url.rstrip("/")

    try:
        code, body, _ = fetch(base + str(hub.get("health", "")))
        data = json.loads(body or b"{}")
        if not isinstance(data, dict):
            data = {}
        good = code == 200 and data.get("status") == "ok"
        report("8 Живой", OK if good else FAIL, f"/healthz → {code}, status={data.get('status')}")
        if good:
            same = data.get("version") == svc.get("version")
            report("8 Живой", OK if same else FAIL,
                   f"выложена версия {data.get('version')}, в airl.service.json {svc.get('version')}")
    except Exception as e:  # noqa: BLE001
        report("8 Живой", FAIL, f"/healthz недоступен: {type(e).__name__}")

    summary_url = base + str(hub.get("summary", ""))
    try:
        code, _, _ = fetch(summary_url)
        report("5 Один вход", OK if code in (401, 403) else FAIL,
               f"summary без токена → {code} (ожидается 401 или 403)")
    except Exception as e:  # noqa: BLE001
        report("5 Один вход", FAIL, f"summary недоступен: {type(e).__name__}")
        return

    token = os.environ.get("AIRL_HUB_TOKEN")
    if not token:
        report("9 Отдаёт в хаб", SKIP, "нет AIRL_HUB_TOKEN — summary с токеном не проверен")
        return
    try:
        code, body, elapsed = fetch(summary_url, token, cookie)
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
    if not isinstance(data, dict):
        report("9 Отдаёт в хаб", FAIL, "summary должен быть объектом JSON")
        return

    problems = []
    if data.get("service") != svc.get("id"):
        problems.append(f"service='{data.get('service')}'")
    ts = data.get("generated_at")
    try:
        dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        if dt.tzinfo is None:
            problems.append("generated_at без часового пояса")
    except ValueError:
        problems.append("generated_at не в формате ISO 8601")
    declared = [m for m in hub.get("metrics", []) if isinstance(m, str)]
    items = data.get("metrics")
    if not isinstance(items, list) or not items:
        problems.append("metrics пуст или не список")
        items = []
    seen = set()
    for m in items:
        if not isinstance(m, dict):
            problems.append("элемент metrics не объект")
            continue
        mid = m.get("id")
        seen.add(mid)
        if mid not in declared or (map_metrics and mid not in map_metrics):
            problems.append(f"показатель '{mid}' не объявлен в hub.metrics или его нет в карте")
        value = m.get("value")
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            problems.append(f"'{mid}'.value не число")
        if m.get("status") not in ("ok", "warning", "danger"):
            problems.append(f"'{mid}'.status не ok|warning|danger")
    absent = [m for m in declared if m not in seen]
    if items and absent:
        problems.append(f"объявлены, но не пришли: {', '.join(absent)}")
    report("9 Отдаёт в хаб", FAIL if problems else OK,
           "; ".join(problems) if problems else f"форма верна, показателей: {len(items)}")
    report("9 Отдаёт в хаб", OK if elapsed < 1 else WARN, f"ответ за {elapsed:.2f} с (цель — до 1 с)")


def check_registry(svc, path):
    try:
        with open(path, encoding="utf-8") as f:
            reg = json.load(f)
    except FileNotFoundError:
        report("Реестр", WARN, f"нет {path} — хаб ещё не создан? (/airl-hub, режим A)")
        return
    except ValueError:
        report("Реестр", FAIL, f"{path} — не JSON")
        return
    services = reg.get("services", []) if isinstance(reg, dict) else reg
    if not isinstance(services, list):
        report("Реестр", FAIL, "реестр должен быть списком сервисов или объектом с ключом services")
        return
    paths = {s.get("base_path"): s.get("id") for s in services
             if isinstance(s, dict) and s.get("id") != svc.get("id")}
    clash = paths.get(svc.get("base_path"))
    report("Реестр", FAIL if clash else OK,
           f"base_path занят сервисом '{clash}'" if clash else "конфликтов путей нет")


def main():
    p = argparse.ArgumentParser(description="Ворота в хаб AIRL")
    p.add_argument("--service", default="airl.service.json")
    p.add_argument("--map", required=True)
    p.add_argument("--registry")
    p.add_argument("--url", help="адрес хаба, например https://hub.company.kz")
    p.add_argument("--cookie", default="airl_session", help="имя cookie входа из карты")
    p.add_argument("--files-only", action="store_true", help="самопроверка без живых адресов")
    a = p.parse_args()

    try:
        with open(a.service, encoding="utf-8") as f:
            svc = json.load(f)
        if not isinstance(svc, dict):
            raise ValueError("airl.service.json должен быть объектом")
        map_version, map_metrics, departments = read_map(a.map)
    except (OSError, ValueError) as e:
        print(f"Не удалось прочитать файлы: {e}", file=sys.stderr)
        return 2

    check_files(svc, map_version, map_metrics, departments)
    if a.registry:
        check_registry(svc, a.registry)
    if a.url and not a.files_only:
        check_live(svc, a.url, map_metrics, a.cookie)
    elif not a.files_only:
        report("5, 8, 9 Живые", SKIP, "не передан --url")

    icon = {OK: "✔", FAIL: "✖", WARN: "!", SKIP: "–"}
    print(f"\nСервис: {svc.get('id')} v{svc.get('version')} · карта {map_version}\n")
    for gate, status, text in results:
        print(f"  {icon[status]} {gate:<16} {text}")
    fails = sum(1 for _, s, _ in results if s == FAIL)
    skips = sum(1 for _, s, _ in results if s == SKIP)
    if fails:
        print(f"\nИтог: красных: {fails} — в хаб не подключаем")
        return 1
    if a.files_only:
        print("\nИтог: файловые ворота 1–4 зелёные. Живые ворота 5, 8, 9 проверяет команда AIRL при приёмке")
        return 0
    if skips:
        print("\nИтог: красных нет, но живые ворота 5, 8, 9 проверены не полностью — подключать нельзя")
        return 3
    print("\nИтог: красных ворот нет")
    return 0


if __name__ == "__main__":
    sys.exit(main())
