#!/usr/bin/env python3
"""Выгрузка данных из Bitrix24 и amoCRM для хранилища AIRL.

Только стандартная библиотека Python 3.9+. Только чтение.

  BITRIX24_WEBHOOK_URL=https://<портал>/rest/<id>/<код>/ \\
    python3 extract.py --system bitrix24 --entities deals,companies,tasks --out /srv/hub/raw/bitrix24

  AMOCRM_BASE_URL=https://<поддомен>.amocrm.ru AMOCRM_TOKEN=... \\
    python3 extract.py --system amocrm --entities leads,contacts --out /srv/hub/raw/amocrm

Для каждой сущности пишет <out>/<entity>.ndjson: по строке на запись
{"system", "entity", "source_id", "modified_at", "payload"}. При повторном запуске
берёт только изменённое после прошлого раза (с запасом 10 минут) — состояние
в <out>/state.json. С --full пишет ещё <entity>.ids — полный список ID для пометки
удалённых (load.sh). Адрес вебхука и токен не печатаются.

Код выхода: 0 — всё выгружено, 1 — ошибка по одной из сущностей, 2 — ошибка запуска.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

OVERLAP = timedelta(minutes=10)

BITRIX = {
    "deals":       {"method": "crm.deal.list",     "key": "ID", "modified": "DATE_MODIFY", "select": ["*", "UF_*"]},
    "leads":       {"method": "crm.lead.list",     "key": "ID", "modified": "DATE_MODIFY", "select": ["*", "UF_*"]},
    "companies":   {"method": "crm.company.list",  "key": "ID", "modified": "DATE_MODIFY", "select": ["*", "UF_*"]},
    "contacts":    {"method": "crm.contact.list",  "key": "ID", "modified": "DATE_MODIFY", "select": ["*", "UF_*"]},
    "activities":  {"method": "crm.activity.list", "key": "ID", "modified": "LAST_UPDATED", "select": ["*"]},
    "tasks":       {"method": "tasks.task.list",   "key": "id", "modified": "CHANGED_DATE", "record_modified": "changedDate",
                    "select": ["*"], "result_key": "tasks"},
    "users":       {"method": "user.get",          "key": "ID"},
    "departments": {"method": "department.get",    "key": "ID"},
    "deal_stages": {"method": "crm.status.list",   "key": "ID", "filter": {"ENTITY_ID": "DEAL_STAGE"}},
}

AMO = {
    "leads":     {"path": "/api/v4/leads",           "embedded": "leads",     "modified": "updated_at"},
    "contacts":  {"path": "/api/v4/contacts",        "embedded": "contacts",  "modified": "updated_at"},
    "companies": {"path": "/api/v4/companies",       "embedded": "companies", "modified": "updated_at"},
    "tasks":     {"path": "/api/v4/tasks",           "embedded": "tasks",     "modified": "updated_at"},
    "events":    {"path": "/api/v4/events",          "embedded": "events",    "modified": "created_at", "filter_field": "created_at"},
    "pipelines": {"path": "/api/v4/leads/pipelines", "embedded": "pipelines"},
    "users":     {"path": "/api/v4/users",           "embedded": "users"},
}


class Client:
    """HTTP с паузой между запросами и повтором при перегрузке."""

    def __init__(self, min_interval, headers=None, max_retries=6):
        self.min_interval = min_interval
        self.headers = headers or {}
        self.max_retries = max_retries
        self._last = 0.0
        self.requests = 0

    def call(self, url, label, body=None):
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(self.max_retries + 1):
            wait = self.min_interval - (time.monotonic() - self._last)
            if wait > 0:
                time.sleep(wait)
            self._last = time.monotonic()
            self.requests += 1
            req = urllib.request.Request(url, data=data, method="POST" if data else "GET",
                                         headers={"Accept": "application/json", **self.headers,
                                                  **({"Content-Type": "application/json"} if data else {})})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    raw = r.read()
                    return r.status, (json.loads(raw) if raw else None)
            except urllib.error.HTTPError as e:
                raw = e.read()
                try:
                    payload = json.loads(raw) if raw else {}
                except ValueError:
                    payload = {}
                overloaded = e.code in (429, 503) or (isinstance(payload, dict) and payload.get("error") == "QUERY_LIMIT_EXCEEDED")
                if overloaded and attempt < self.max_retries:
                    retry_after = e.headers.get("Retry-After")
                    delay = float(retry_after) if retry_after and retry_after.isdigit() else min(60, 2 ** attempt)
                    print(f"  {label}: перегрузка ({e.code}), пауза {delay:.0f} с", file=sys.stderr)
                    time.sleep(delay)
                    continue
                if e.code >= 500 and attempt < self.max_retries:
                    time.sleep(min(60, 2 ** attempt))
                    continue
                detail = payload.get("error_description") or payload.get("error") or payload.get("title") or ""
                raise RuntimeError(f"{label}: HTTP {e.code} {detail}".strip()) from None
            except urllib.error.URLError as e:
                if attempt < self.max_retries:
                    time.sleep(min(60, 2 ** attempt))
                    continue
                raise RuntimeError(f"{label}: нет соединения ({e.reason})") from None
        raise RuntimeError(f"{label}: не удалось после {self.max_retries} повторов")


def parse_time(value):
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=timezone.utc)
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def bitrix_pages(client, base, spec, since):
    start = 0
    while True:
        body = {"start": start}
        if "select" in spec:
            body["select"] = spec["select"]
            body["order"] = {spec["key"].upper(): "ASC"}
        flt = dict(spec.get("filter", {}))
        if since is not None and "modified" in spec:
            flt[">=" + spec["modified"]] = since.isoformat()
        if flt:
            body["filter"] = flt
        status, data = client.call(base + spec["method"] + ".json", spec["method"], body)
        if not isinstance(data, dict):
            raise RuntimeError(f"{spec['method']}: неожиданный ответ")
        if "error" in data:
            raise RuntimeError(f"{spec['method']}: {data.get('error_description') or data['error']}")
        result = data.get("result", [])
        if isinstance(result, dict):
            result = result.get(spec.get("result_key", "items"), [])
        for rec in result:
            yield rec
        nxt = data.get("next")
        if nxt is None or not result:
            return
        start = nxt


def amo_pages(client, base, spec, since):
    page = 1
    while True:
        params = {"limit": 250, "page": page}
        if since is not None and "modified" in spec:
            params[f"filter[{spec.get('filter_field', spec['modified'])}][from]"] = int(since.timestamp())
        url = base.rstrip("/") + spec["path"] + "?" + urllib.parse.urlencode(params)
        status, data = client.call(url, spec["path"])
        if status == 204 or not data:
            return
        items = (data.get("_embedded") or {}).get(spec["embedded"], [])
        for rec in items:
            yield rec
        if not items or "next" not in (data.get("_links") or {}):
            return
        page += 1


def main():
    p = argparse.ArgumentParser(description="Выгрузка из Bitrix24 и amoCRM")
    p.add_argument("--system", required=True, choices=["bitrix24", "amocrm"])
    p.add_argument("--entities", required=True, help="через запятую, например deals,companies,tasks")
    p.add_argument("--out", required=True)
    p.add_argument("--since", help="ISO-дата: выгрузить изменённое после неё (иначе — из state.json или всё)")
    p.add_argument("--full", action="store_true", help="выгрузить всё и записать полный список ID для пометки удалённых")
    p.add_argument("--min-interval", type=float, help="пауза между запросами, с (по умолчанию 0.55 для Bitrix24, 0.15 для amoCRM)")
    a = p.parse_args()

    catalog = BITRIX if a.system == "bitrix24" else AMO
    entities = [e.strip() for e in a.entities.split(",") if e.strip()]
    unknown = [e for e in entities if e not in catalog]
    if unknown:
        print(f"Неизвестные сущности для {a.system}: {', '.join(unknown)}. Есть: {', '.join(catalog)}", file=sys.stderr)
        return 2

    if a.system == "bitrix24":
        base = os.environ.get("BITRIX24_WEBHOOK_URL", "")
        if not base.startswith("http"):
            print("Задайте BITRIX24_WEBHOOK_URL (адрес входящего вебхука)", file=sys.stderr)
            return 2
        base = base.rstrip("/") + "/"
        client = Client(a.min_interval if a.min_interval is not None else 0.55)
    else:
        base = os.environ.get("AMOCRM_BASE_URL", "")
        token = os.environ.get("AMOCRM_TOKEN", "")
        if not base.startswith("http") or not token:
            print("Задайте AMOCRM_BASE_URL и AMOCRM_TOKEN", file=sys.stderr)
            return 2
        client = Client(a.min_interval if a.min_interval is not None else 0.15,
                        headers={"Authorization": f"Bearer {token}"})

    os.makedirs(a.out, exist_ok=True)
    state_path = os.path.join(a.out, "state.json")
    try:
        with open(state_path, encoding="utf-8") as f:
            state = json.load(f)
    except (FileNotFoundError, ValueError):
        state = {}

    failed = 0
    for entity in entities:
        spec = catalog[entity]
        since = None
        if not a.full and "modified" in spec:
            since = parse_time(a.since) if a.since else parse_time(state.get(entity))
            if since is not None:
                since -= OVERLAP
        key = spec.get("key", "id")
        rec_mod = spec.get("record_modified", spec.get("modified"))
        out_path = os.path.join(a.out, f"{entity}.ndjson")
        tmp_path = out_path + ".tmp"
        count, newest = 0, parse_time(state.get(entity))
        extracted_at = datetime.now(timezone.utc).isoformat()
        try:
            pages = (bitrix_pages(client, base, spec, since) if a.system == "bitrix24"
                     else amo_pages(client, base, spec, since))
            with open(tmp_path, "w", encoding="utf-8") as f:
                for rec in pages:
                    sid = rec.get(key) if key in rec else rec.get(key.lower(), rec.get(key.upper()))
                    if sid is None:
                        continue
                    mod = parse_time(rec.get(rec_mod)) if rec_mod else None
                    if mod and (newest is None or mod > newest):
                        newest = mod
                    f.write(json.dumps({"system": a.system, "entity": entity, "source_id": str(sid),
                                        "modified_at": mod.isoformat() if mod else None,
                                        "extracted_at": extracted_at, "payload": rec},
                                       ensure_ascii=False) + "\n")
                    count += 1
            os.replace(tmp_path, out_path)
            if a.full:
                ids_path = os.path.join(a.out, f"{entity}.ids")
                with open(out_path, encoding="utf-8") as src, open(ids_path, "w", encoding="utf-8") as dst:
                    for line in src:
                        dst.write(json.loads(line)["source_id"] + "\n")
            if newest:
                state[entity] = newest.isoformat()
            mode = "полностью" if a.full or since is None else f"с {since.isoformat()}"
            print(f"✔ {entity}: {count} записей ({mode})")
        except RuntimeError as e:
            failed += 1
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
            print(f"✖ {entity}: {e}", file=sys.stderr)

    with open(state_path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    os.replace(state_path + ".tmp", state_path)
    print(f"Запросов: {client.requests}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
