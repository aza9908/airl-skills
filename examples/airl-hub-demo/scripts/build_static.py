#!/usr/bin/env python3
"""Статическая демо-версия хаба для Netlify: экран руководителя и ВСЕ сервисы отделов на снимке данных.

Работает против запущенного стенда (bash scripts/dev_up.sh): входит как ceo (пароль — DEMO_PASSWORD из .env),
находит все GET-запросы к API, которые делают страницы (вызовы api('...') в services/*/public/*.js и ui.js),
раскрывает переменные части (период, показатель, id потока, клиента, сотрудника, кампании, месяц ОПиУ),
снимает ответы в data/*.json и собирает папку:

  dist-static/
    index.html, app.js, icons/ …        экран руководителя (services/hub/public без входа и service worker)
    assets/                              общие стили, скрипты, логотип (services/shared/static)
    <id>/index.html, <id>/app.js, <id>/assets/, <id>/icons/ …   сервис отдела по своему base_path
    data/*.json                          снимок API (имя — путь с запросом, не-латиница → «_»)
    static-mode.js, static-after.js, static.css, sw.js, _redirects, _headers, netlify.toml   из static-demo/

Только стандартная библиотека Python. Cookie входа помечена Secure, поэтому отправляется вручную заголовком Cookie.
Запуск:  python3 scripts/build_static.py [--url http://127.0.0.1:8080] [--out dist-static]
"""
import argparse
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = os.path.join(ROOT, "services")
GRAINS = ["day", "week", "month", "quarter"]

# Переменные части адресов, которые нельзя угадать из кода: откуда брать значения.
# Ключ — (база сервиса, выражение внутри ${…}); значение — (адрес-источник, поле списка, поле значения)
# или готовый список. Новое выражение без правила — ошибка сборки, а не молча пропущенная страница.
SOURCES = {
    ("/edu", "encodeURIComponent(code)"): ("/edu/api/overview", "cohorts", "cohort_code"),
    ("/finance", "encodeURIComponent(id)"): ("/finance/api/debtors", "rows", "client_id"),
    ("/finance", "encodeURIComponent(params.get('month') || '')"): ("/finance/api/pnl?month=&branch=all", "months", None, [""]),
    ("/finance", "encodeURIComponent(params.get('branch') || 'all')"): ["all", "airl", "airl_dev"],
    ("/hr", "encodeURIComponent(id)"): ("/hr/api/onboarding", "rows", "instance_id"),
    ("/marketing", "encodeURIComponent(b.dataset.id)"): ("/marketing/api/campaigns", "rows", "campaign_id"),
    ("", "grain"): GRAINS,
}


def fname(path):
    """Имя файла снимка — как в static-demo/static-mode.js."""
    return re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_") + ".json"


class Client:
    def __init__(self, base, password):
        self.base = base.rstrip("/")
        req = urllib.request.Request(self.base + "/auth/login", method="POST",
                                     data=json.dumps({"login": "ceo", "password": password}).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                cookies = r.headers.get_all("Set-Cookie") or []
        except urllib.error.HTTPError as e:
            sys.exit(f"Вход ceo не удался: HTTP {e.code} (429 — перезапустите стенд: dev_down.sh && dev_up.sh)")
        m = next((re.match(r"airl_session=([^;]+)", c) for c in cookies if c.startswith("airl_session=")), None)
        if not m:
            sys.exit("Вход ceo: нет cookie airl_session")
        self.cookie = f"airl_session={m.group(1)}"   # Secure-cookie по http не уйдёт сама — шлём заголовком
        self.cache = {}

    def get(self, path):
        if path in self.cache:
            return self.cache[path]
        req = urllib.request.Request(self.base + path, headers={"Cookie": self.cookie, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                body = json.loads(r.read())
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"GET {path} → HTTP {e.code}") from None
        self.cache[path] = body
        return body


def discover():
    """Шаблоны запросов из кода страниц: [(база сервиса, шаблон, файл)]. ${B} заменяется на base_path сервиса."""
    found = []
    files = [(f"/{d}" if d != "hub" else "", os.path.join(SERVICES, d, "public", f))
             for d in sorted(os.listdir(SERVICES)) if os.path.isdir(os.path.join(SERVICES, d, "public"))
             for f in os.listdir(os.path.join(SERVICES, d, "public")) if f.endswith(".js")]
    files.append(("", os.path.join(SERVICES, "shared", "static", "ui.js")))
    for base, f in files:
        src = open(f, encoding="utf-8").read()
        mb = re.search(r"const B = '([^']+)'", src)
        b = mb.group(1) if mb else base
        for m in re.finditer(r"\bapi\(\s*(`[^`]*`|'[^']*')", src):
            t = m.group(1)[1:-1].replace("${B}", b)
            found.append((b, t, os.path.relpath(f, ROOT)))
        # ряды графиков экрана руководителя: S('revenue') → /hub/api/series?metric=${m}&grain=${grain}
        if base == "" and "const S = (m)" in src:
            for m in sorted(set(re.findall(r"\bS\('([a-z_]+)'\)", src))):
                found.append(("", f"/hub/api/series?metric={m}&grain=${{grain}}", os.path.relpath(f, ROOT)))
    # шаблон series с ${m} заменён конкретными показателями выше
    return [x for x in found if "${m}" not in x[1]]


def values_for(cli, base, expr):
    rule = SOURCES.get((base, expr)) or SOURCES.get(("", expr))
    if rule is None:
        raise RuntimeError(f"нет правила для ${{{expr}}} в {base or '/'} — добавьте его в SOURCES")
    if isinstance(rule, list):
        return rule
    src, lst, field, *extra = rule
    data = cli.get(src)[lst]
    vals = [str(x if field is None else x[field]) for x in data]
    return (extra[0] if extra else []) + vals


def expand(cli, base, template):
    parts = re.split(r"\$\{([^}]*)\}", template)
    paths = [""]
    for i, p in enumerate(parts):
        if i % 2 == 0:
            paths = [x + p for x in paths]
        else:
            vals = values_for(cli, base, p)
            enc = "encodeURIComponent" in p
            paths = [x + (urllib.parse.quote(v, safe="") if enc else v) for x in paths for v in vals]
    return paths


def inject(html):
    """Подключить статический режим: до первого скрипта — данные из снимка, после последнего — отключение SW и выхода."""
    h = html.index("</head>")
    html = html[:h] + '  <link rel="stylesheet" href="/static.css">\n' + html[h:]
    i = html.index("<script")
    html = html[:i] + '<script src="/static-mode.js"></script>\n  ' + html[i:]
    j = html.rindex("</body>")
    return html[:j] + '  <script src="/static-after.js"></script>\n' + html[j:]


def copytree(src, dst, skip=()):
    for name in os.listdir(src):
        if name in skip:
            continue
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            os.makedirs(dst, exist_ok=True)
            shutil.copy2(s, d)


def read_env(name):
    if os.environ.get(name):
        return os.environ[name]
    with open(os.path.join(ROOT, ".env"), encoding="utf-8") as f:
        for line in f:
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip("'\"")
    sys.exit(f"Нет {name} в .env")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080")
    ap.add_argument("--out", default=os.path.join(ROOT, "dist-static"))
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    cli = Client(a.url, read_env("DEMO_PASSWORD"))
    registry = json.load(open(os.path.join(ROOT, "hub", "services.json"), encoding="utf-8"))["services"]
    live = [s for s in registry if s["status"] in ("connected", "degraded")]

    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(os.path.join(out, "data"))

    # 1. Снимок API
    me = cli.get("/auth/me")
    ids = {s["id"] for s in me["services"]}
    missing = [s["id"] for s in live if s["id"] not in ids]
    if missing:
        sys.exit(f"/auth/me под ceo не содержит сервисы {missing} — переключатель отделов будет неполным")
    paths = {"/auth/me"}
    for base, tpl, f in discover():
        try:
            paths.update(expand(cli, base, tpl))
        except (RuntimeError, KeyError) as e:
            sys.exit(f"{f}: {tpl}: {e}")
    errors = []
    for p in sorted(paths):
        try:
            body = cli.get(p)
        except RuntimeError as e:
            errors.append(str(e))
            continue
        with open(os.path.join(out, "data", fname(p)), "w", encoding="utf-8") as fh:
            json.dump(body, fh, ensure_ascii=False, separators=(",", ":"))
    if errors:
        sys.exit("Не удалось снять:\n  " + "\n  ".join(errors))

    # 2. Страницы: экран руководителя в корне, сервисы — по base_path
    shared = os.path.join(SERVICES, "shared", "static")
    copytree(os.path.join(SERVICES, "hub", "public"), out, skip={"login.html", "login.js", "login.css", "sw.js"})
    copytree(shared, os.path.join(out, "assets"))
    pages = ["/"]
    for s in live:
        d = os.path.join(out, s["base_path"].strip("/"))
        copytree(os.path.join(SERVICES, s["id"], "public"), d)
        copytree(shared, os.path.join(d, "assets"))
        shutil.copy2(os.path.join(ROOT, "static-demo", "sw.js"), os.path.join(d, "sw.js"))
        pages.append(s["base_path"] + "/")
    for p in pages:
        f = os.path.join(out, p.strip("/"), "index.html")
        with open(f, encoding="utf-8") as fh:
            html = fh.read()
        with open(f, "w", encoding="utf-8") as fh:
            fh.write(inject(html))

    # 3. Файлы статического режима и Netlify
    for name in ("static-mode.js", "static-after.js", "static.css", "sw.js", "_redirects", "_headers", "netlify.toml"):
        shutil.copy2(os.path.join(ROOT, "static-demo", name), os.path.join(out, name))

    n = len(os.listdir(os.path.join(out, "data")))
    size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(out) for f in fs)
    print(f"Статическая версия: {out}")
    print(f"  страницы: {', '.join(pages)}")
    print(f"  снимков API: {n} · размер: {size / 1e6:.1f} МБ · сервисов в переключателе: {len(me['services'])}")


if __name__ == "__main__":
    main()
