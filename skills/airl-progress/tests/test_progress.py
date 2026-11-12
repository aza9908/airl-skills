#!/usr/bin/env python3
"""Проверка scripts/progress.py без сети.

  python3 skills/airl-progress/tests/test_progress.py
  python3 skills/airl-progress/tests/test_progress.py -v

Что проверяется:
  1. пять поддельных репозиториев участников (git init, разные этапы и даты
     коммитов) — локальный режим --local: этапы, проценты, флаги, подсказки;
  2. три снимка подряд: история растёт, процент «среднего» участника растёт,
     «застрял» считается и по дням без роста процента;
  3. путь через GitHub API — против локального поддельного сервера: те же итоги,
     что и в локальном режиме; ETag на дереве (второй запуск получает 304),
     файлы не скачиваются повторно (итоги по SHA); токен нигде не сохраняется;
     содержимое файлов участников не попадает в снимок и кеш;
  4. живая проверка /healthz по адресу из списка (локальный HTTP-сервер);
  5. мини-парсер YAML даёт то же, что PyYAML, на шаблонах навыка;
  6. отчёт: index.html открывается в Playwright без ошибок в консоли, графики
     на месте, на ширине телефона нет горизонтальной прокрутки; скриншоты
     светлой и тёмной темы — в папку из PROGRESS_SCREENSHOTS или во временную;
  7. несколько потоков в одном списке: свои даты старта, средние по потокам,
     блок «Сравнение потоков», фильтр «Поток» в браузере;
  8. имя репозитория без владельца в режиме --local;
  9. монорепозиторий: сервисы в подпапках (колонка path) — отдельные проценты
     и активность по подпапке, локально и через GitHub API; папка внутри git;
 10. старая история (один поток на снимок) по-прежнему рисуется.

Нужно: Python 3.9+, git. Для пункта 6 — пакет playwright и Chromium
(или Chrome: путь в PLAYWRIGHT_CHROME); без них пункт 6 пропускается.
Код выхода: 0 — всё прошло, 1 — есть провалы.
"""
from __future__ import annotations

import base64
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
sys.path.insert(0, str(SKILL / "scripts"))
import progress  # noqa: E402

NOW = ["2026-11-18T09:00:00Z", "2026-11-19T09:00:00Z", "2026-11-23T09:00:00Z"]
FAKE_TOKEN = "ghp_FAKE_TOKEN_must_not_leak_123456"
SECRET_LINE = "СЕКРЕТНОЕ_СОДЕРЖИМОЕ_ТЗ_42"

SPEC_FULL = f"""---
service_id: calls
---
# PRD продукта «Учёт звонков»

## 1. Боль и результат
**Сейчас**: менеджеры записывают звонки в тетрадь, отчёт собирается руками.
**Цена боли**: 6 часов в неделю у руководителя — как замерили: хронометраж 2 недели
**После запуска**: отчёт собирается сам
**Метрика успеха для Demo Day**: было 6 часов → стало 0 часов в неделю

## 2. Пользователи и роли
{SECRET_LINE}

## 10. Критерии готовности
- [ ] Менеджер создаёт звонок с телефона за три касания
- [ ] Чужой звонок нельзя открыть, подставив его номер в адрес
- [ ] Отчёт за неделю открывается за 2 секунды

## 12. План спринтов
- [x] Неделя 1 · План
- [x] Demo Day: было → стало
"""

SPEC_TEMPLATE = """# PRD продукта «[Название]»

## 1. Боль и результат
**Сейчас**: [что происходит, одной-двумя фразами]
**Цена боли**: [часов в неделю / денег / заявок / ошибок] — как замерили: [...]
**Метрика успеха для Demo Day**: [было X → стало Y]

## 10. Критерии готовности
- [ ] ...
"""

ARCH = """# Архитектура

## Контекст для следующих шагов
```yaml
# airl-context
mode: solo
country: KZ
```
"""

LONG = "Описание. " * 40

SECURITY_OK = """# Безопасность сервиса «Учёт звонков»

**Дата**: 2026-11-15 · **Коммит**: abc1234 · **Проверял**: airl-cybersecurity
**Можно открывать людям** (в хабе: подключать к хабу): да, потому что срочных находок нет
"""
SECURITY_NO = SECURITY_OK.replace(": да, потому что срочных находок нет", ": нет, потому что ключ в репозитории")
REVIEW_OK = "# Код-ревью\n\n## Ревью 2026-11-17\n\n**Блокирующих замечаний**: 0\n**Вердикт**: можно выкладывать\n"
HUB_CHECK = "# Приёмка в хаб\n\n**Дата**: 2026-11-17 · **map_version**: 1.0\n**Решение**: готов к приёмке\n"
SERVICE_JSON = json.dumps({"id": "sales", "hub": {"health": "/sales/healthz", "summary": "/sales/api/hub/summary"},
                           "data": {"writes": ["mart_sales"]}})
SERVER_JS = "app.get('/healthz', (q, r) => r.json({ok: true}));\n"
HUB_SERVER_JS = SERVER_JS + "app.get('/sales/api/hub/summary', auth, summary);\n"


def git(repo: Path, *args, date: str | None = None):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
    if date:
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = date
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError(r.stderr)
    return r.stdout


def commit(repo: Path, files: dict[str, str], date: str, msg: str = "work"):
    for path, content in files.items():
        p = repo / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", msg, date=date)


def make_repos(base: Path) -> None:
    def init(name):
        r = base / f"cohort__{name}"
        r.mkdir(parents=True)
        git(r, "init", "-q", "-b", "main")
        return r

    # 1. Впереди: всё до Demo Day, свежие коммиты
    r = init("ahead")
    commit(r, {"CLAUDE.md": LONG, "README.md": "x"}, "2026-11-02T10:00:00Z")
    commit(r, {"SPEC.md": SPEC_FULL, "ARCHITECTURE.md": ARCH}, "2026-11-04T10:00:00Z")
    commit(r, {"DWH.md": LONG, "migrations/001_init.sql": "create table calls(id int);",
               "migrations/002_kit.sql": "create table airl_settings(x int);",
               "public/manifest.webmanifest": "{}", "public/sw.js": "//",
               "server/index.js": SERVER_JS}, "2026-11-10T10:00:00Z")
    commit(r, {"SECURITY.md": SECURITY_OK}, "2026-11-14T10:00:00Z")
    commit(r, {"Dockerfile": "FROM node:22", ".github/workflows/ci.yml": "name: ci",
               "DEVOPS.md": LONG, "REVIEW.md": REVIEW_OK}, "2026-11-17T10:00:00Z")
    git(r, "branch", "feature-x")

    # 2. Середина: план готов, данные начаты; в следующих снимках догоняет
    r = init("mid")
    commit(r, {"CLAUDE.md": LONG}, "2026-11-03T10:00:00Z")
    commit(r, {"SPEC.md": SPEC_FULL.replace("- [x] Demo Day", "- [ ] Demo Day"),
               "ARCHITECTURE.md": ARCH}, "2026-11-06T10:00:00Z")
    commit(r, {"DWH.md": LONG}, "2026-11-16T10:00:00Z")

    # 3. Застрял: шаблон ТЗ без цифр, последний коммит 10+ дней назад
    r = init("stalled")
    commit(r, {"CLAUDE.md": "коротко", "SPEC.md": SPEC_TEMPLATE}, "2026-11-05T10:00:00Z")

    # 4. Хаб: сервис отдела, защита пройдена, ждёт приёмки
    r = init("hub")
    commit(r, {"CLAUDE.md": LONG, "airl/COMPANY_MAP.md": "# Карта", "airl.service.json": SERVICE_JSON,
               "SPEC.md": SPEC_FULL, "ARCHITECTURE.md": ARCH.replace("solo", "hub")}, "2026-11-04T10:00:00Z")
    commit(r, {"DWH.md": LONG, "migrations/001.sql": "create schema mart_sales;",
               "migrations/002_receivables.sql": "--", "src/server.js": HUB_SERVER_JS,
               "package.json": '{"devDependencies": {"vite-plugin-pwa": "1.0.0"}}'}, "2026-11-11T10:00:00Z")
    commit(r, {"SECURITY.md": SECURITY_OK, "HUB_CHECK.md": HUB_CHECK}, "2026-11-17T12:00:00Z")

    # 5. Пусто: только README, но коммиты свежие
    r = init("empty")
    commit(r, {"README.md": "hello"}, "2026-11-17T10:00:00Z")


ROSTER = """name,company,department,mode,repo,branch,live_url,cohort
Анна Впереди,Арома,продажи,solo,cohort/ahead,main,{live},Тест-когорта
Борис Середина,Арома,склад,solo,https://github.com/cohort/mid,,,Тест-когорта
Вера Застряла,Дару,регистратура,solo,cohort/stalled,main,,Тест-когорта
Гульнара Хаб,Север,продажи,hub,cohort/hub,main,,Тест-когорта
Данияр Пусто,Север,склад,solo,cohort/empty,main,,Тест-когорта
Ерлан Нет доступа,Север,финансы,solo,cohort/missing,main,,Тест-когорта
"""


# ---------------------------------------------------------------------------
# Поддельный GitHub API поверх локальных git-репозиториев
# ---------------------------------------------------------------------------

class FakeGitHub:
    def __init__(self, base: Path):
        self.base = base
        self.log: list[str] = []
        self.auth: set[str] = set()
        srv = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                srv.log.append(self.path)
                srv.auth.add(self.headers.get("Authorization", ""))
                try:
                    code, body, hdrs = srv.route(self.path, self.headers)
                except Exception as e:  # noqa: BLE001
                    code, body, hdrs = 500, str(e).encode(), {}
                self.send_response(code)
                for k, v in hdrs.items():
                    self.send_header(k, v)
                self.send_header("X-RateLimit-Remaining", "4999")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()

    def g(self, repo, *args):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True).stdout

    def route(self, path, headers):
        from urllib.parse import urlparse, parse_qs, unquote
        u = urlparse(path)
        parts = [unquote(p) for p in u.path.strip("/").split("/")]
        q = parse_qs(u.query)
        if len(parts) < 3 or parts[0] != "repos":
            return 404, b"{}", {}
        repo = self.base / f"{parts[1]}__{parts[2]}"
        if not repo.is_dir():
            return 404, b'{"message":"Not Found"}', {}
        rest = parts[3:]
        js = {"Content-Type": "application/json"}
        if not rest:
            return 200, json.dumps({"default_branch": "main"}).encode(), js
        if rest[0] == "branches" and len(rest) == 2:
            sha = self.g(repo, "rev-parse", rest[1]).decode().strip()
            date = self.g(repo, "log", "-1", "--format=%cI", rest[1]).decode().strip()
            return 200, json.dumps({"name": rest[1], "commit": {"sha": sha, "commit": {
                "committer": {"date": date}}}}).encode(), js
        if rest[0] == "branches":
            names = self.g(repo, "branch", "--format=%(refname:short)").decode().split()
            return 200, json.dumps([{"name": n} for n in names]).encode(), js
        if rest[:2] == ["git", "trees"]:
            sha = rest[2]
            etag = '"' + sha + '"'
            if headers.get("If-None-Match") == etag:
                return 304, b"", {"ETag": etag}
            out = self.g(repo, "ls-tree", "-r", "-l", sha).decode()
            tree = []
            for ln in out.splitlines():
                meta, name = ln.split("\t", 1)
                _mode, typ, bsha, size = meta.split()
                tree.append({"path": name, "type": typ, "sha": bsha, "size": int(size)})
            return 200, json.dumps({"sha": sha, "tree": tree}).encode(), dict(js, ETag=etag)
        if rest[:2] == ["git", "blobs"]:
            return 200, self.g(repo, "cat-file", "-p", rest[2]), {"Content-Type": "application/octet-stream"}
        if rest[0] == "commits":
            args = ["log", "--format=%H %cI"]
            if q.get("since"):
                args.append(f"--since={q['since'][0]}")
            if q.get("per_page", ["100"])[0] == "1":
                args.append("-1")
            args.append(q.get("sha", ["main"])[0])
            if q.get("path"):
                args += ["--", q["path"][0]]
            out = [ln.split() for ln in self.g(repo, *args).decode().splitlines() if ln.strip()]
            return 200, json.dumps([{"sha": h, "commit": {"committer": {"date": d}}} for h, d in out]).encode(), js
        if rest[0] == "pulls":
            n = 1 if parts[2] == "ahead" else 0
            return 200, json.dumps([{"number": i} for i in range(n)]).encode(), js
        return 404, b"{}", {}


class Health:
    def __init__(self):
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                self.send_response(200 if self.path == "/healthz" else 404)
                self.end_headers()
                self.wfile.write(b"ok")

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()


def run(*args) -> str:
    buf_out, buf_err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
        code = progress.main(list(args))
    if code != 0:
        raise AssertionError(f"progress.py {' '.join(args)} → {code}\n{buf_err.getvalue()}")
    return buf_out.getvalue()


def by_id(snap):
    return {p["id"]: p for p in snap["participants"]}


class ProgressTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="airl_progress_"))
        cls.repos = cls.tmp / "repos"
        make_repos(cls.repos)
        cls.health = Health()
        cls.roster = cls.tmp / "roster.csv"
        cls.roster.write_text(ROSTER.format(live=cls.health.url), encoding="utf-8")
        cls.weights = SKILL / "templates" / "weights.yml"
        # три снимка в локальном режиме; между ними «середина» догоняет
        cls.data = cls.tmp / "local" / "progress.jsonl"
        cls.out = cls.tmp / "local" / "report"
        common = ["--roster", str(cls.roster), "--weights", str(cls.weights), "--local", str(cls.repos),
                  "--data", str(cls.data), "--out", str(cls.out)]
        run("check", *common, "--now", NOW[0])
        mid = cls.repos / "cohort__mid"
        commit(mid, {"migrations/001.sql": "create table t(x int);", "migrations/002_approvals.sql": "--",
                     "public/manifest.webmanifest": "{}", "public/sw.js": "//",
                     "api/health.py": "@app.get('/healthz')\ndef h(): return 'ok'\n"}, "2026-11-18T20:00:00Z")
        run("check", *common, "--now", NOW[1])
        cls.tg = run("check", *common, "--now", NOW[2], "--telegram-text")
        cls.hist = progress.load_history(cls.data)

    @classmethod
    def tearDownClass(cls):
        cls.health.close()
        if not os.environ.get("KEEP_TMP"):
            shutil.rmtree(cls.tmp, ignore_errors=True)

    # 1. Этапы, проценты, флаги -------------------------------------------
    def test_stages_and_percent(self):
        s = by_id(self.hist[0])
        a = s["cohort/ahead"]
        self.assertEqual(a["stage"], "finished")
        self.assertEqual(a["stage_done"], "demo")
        self.assertEqual(a["percent"], 100.0)
        self.assertEqual(a["items"]["live"], 1.0)
        self.assertIsNone(a["items"]["service_json"])          # только для хаба

        m = s["cohort/mid"]
        self.assertEqual(m["stage_done"], "plan")
        self.assertEqual(m["stage"], "data")
        self.assertIsNone(m["items"]["live"])                   # адреса нет — пункт не считается
        self.assertTrue(20 < m["percent"] < 40, m["percent"])

        st = s["cohort/stalled"]
        self.assertEqual(st["items"]["spec"], 1.0)
        self.assertEqual(st["items"]["spec_pain"], 0.0)         # шаблон с [...] — не заполнено
        self.assertEqual(st["items"]["spec_metric"], 0.0)
        self.assertEqual(st["items"]["spec_criteria"], 0.0)
        self.assertEqual(st["items"]["claude_md"], 0.5)         # слишком короткий
        self.assertEqual(st["stage"], "plan")

        h = s["cohort/hub"]
        self.assertEqual(h["mode"], "hub")
        for k in ("service_json", "company_map", "hub_summary", "healthz", "pwa_manifest", "pwa_sw", "module"):
            self.assertEqual(h["items"][k], 1.0, k)
        self.assertEqual(h["items"]["security_ok"], 1.0)
        self.assertEqual(h["items"]["demo"], 0.5)               # «готов к приёмке», ещё не подключён
        self.assertEqual(h["stage_done"], "security")
        self.assertEqual(h["stage"], "launch")

        e = s["cohort/empty"]
        self.assertEqual(e["stage"], "start")
        self.assertIsNone(e["stage_done"])                      # нет CLAUDE.md — старт не пройден

        x = s["cohort/missing"]
        self.assertIn("error", x)
        self.assertEqual(x["flags"][0]["kind"], "error")

    def test_flags_and_advice(self):
        s = by_id(self.hist[0])
        kinds = {pid: {f["kind"] for f in p["flags"]} for pid, p in s.items()}
        self.assertIn("ahead", kinds["cohort/ahead"])
        self.assertIn("stalled", kinds["cohort/stalled"])
        stalled = next(f for f in s["cohort/stalled"]["flags"] if f["kind"] == "stalled")
        self.assertEqual(stalled["days"], 12)                   # 5 → 17 ноября
        self.assertIn("behind", kinds["cohort/stalled"])
        self.assertIn("behind", kinds["cohort/empty"])
        self.assertNotIn("stalled", kinds["cohort/empty"])      # коммит вчера
        self.assertNotIn("stalled", kinds["cohort/ahead"])
        nxt = s["cohort/stalled"]["next"]
        self.assertEqual(nxt[0]["skill"], "/airl-context")      # CLAUDE.md неполный
        self.assertEqual(nxt[1]["skill"], "/airl-spec")
        self.assertEqual(s["cohort/hub"]["next"][0]["skill"], "/airl-devops")
        self.assertEqual(s["cohort/ahead"]["activity"]["branches"], 2)
        self.assertEqual(s["cohort/ahead"]["activity"]["commits_7d"], 2)
        out = run("laggards", "--data", str(self.data))
        self.assertIn("Вера Застряла", out)
        self.assertIn("/airl-spec", out)
        self.assertNotIn("Анна Впереди", out)

    def test_schedule_expected(self):
        cfg = progress.load_config(str(self.weights))
        cfg["schedule"]["start_date"] = "2026-11-02"
        t = progress.parse_ts("2026-11-16T00:00:00Z")      # конец недели 2
        self.assertAlmostEqual(progress.expected_percent(cfg, t), 50.0)
        t = progress.parse_ts("2026-11-12T12:00:00Z")      # середина недели 2
        self.assertTrue(25 < progress.expected_percent(cfg, t) < 50)

    # 2. История --------------------------------------------------------------
    def test_history(self):
        self.assertEqual(len(self.hist), 3)
        p = [by_id(s)["cohort/mid"]["percent"] for s in self.hist]
        self.assertLess(p[0], p[1])
        self.assertEqual(p[1], p[2])
        # третий снимок: процент не рос 4 дня, коммит 4+ дня назад — «застрял»
        last = by_id(self.hist[2])["cohort/mid"]
        self.assertEqual(last["days_flat"], 4)
        self.assertIn("stalled", {f["kind"] for f in last["flags"]})
        self.assertEqual(by_id(self.hist[2])["cohort/mid"]["stage_done"], "data")
        self.assertIn("Тест-когорта", self.tg)
        self.assertIn("Нужна помощь", self.tg)
        md = (self.out / "summary.md").read_text(encoding="utf-8")
        self.assertIn("| 1 | Анна Впереди |", md)
        self.assertIn("## Кому помочь", md)
        self.assertIn("## Воронка этапов", md)

    def test_no_contents_stored(self):
        raw = self.data.read_text(encoding="utf-8")
        self.assertNotIn(SECRET_LINE, raw)
        self.assertNotIn("Цена боли", raw)
        html = (self.out / "index.html").read_text(encoding="utf-8")
        self.assertNotIn(SECRET_LINE, html)

    # 3. GitHub API -------------------------------------------------------------
    def test_github_api_path(self):
        fake = FakeGitHub(self.repos)
        old = {k: os.environ.get(k) for k in ("GITHUB_API_URL", "GITHUB_TOKEN", "GH_TOKEN")}
        os.environ["GITHUB_API_URL"] = fake.url
        os.environ["GITHUB_TOKEN"] = FAKE_TOKEN
        os.environ.pop("GH_TOKEN", None)
        try:
            d = self.tmp / "gh"
            args = ["check", "--roster", str(self.roster), "--weights", str(self.weights),
                    "--data", str(d / "progress.jsonl"), "--out", str(d / "report"), "--now", NOW[2]]
            run(*args)
            first_blobs = sum(1 for x in fake.log if "/git/blobs/" in x)
            fake.log.clear()
            run(*args)
            second_blobs = sum(1 for x in fake.log if "/git/blobs/" in x)
            trees = [x for x in fake.log if "/git/trees/" in x]
        finally:
            fake.close()
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.assertIn("Bearer " + FAKE_TOKEN, fake.auth)
        self.assertGreater(first_blobs, 0)
        self.assertEqual(second_blobs, 0, "файлы без изменений не должны скачиваться снова")
        self.assertEqual(len(trees), 5)
        gh_hist = progress.load_history(d / "progress.jsonl")
        loc = by_id(self.hist[2])
        for pid, p in by_id(gh_hist[-1]).items():
            if pid == "cohort/missing":
                self.assertIn("error", p)
                continue
            self.assertEqual(p["items"], loc[pid]["items"], pid)
            self.assertEqual(p["percent"], loc[pid]["percent"], pid)
        self.assertEqual(by_id(gh_hist[-1])["cohort/ahead"]["activity"]["open_prs"], 1)
        for f in [d / "progress.jsonl", d / ".cache" / "github.json", d / "report" / "index.html", d / "report" / "summary.md"]:
            t = f.read_text(encoding="utf-8")
            self.assertNotIn(FAKE_TOKEN, t, f)
            self.assertNotIn(SECRET_LINE, t, f)
            self.assertNotIn(base64.b64encode(SECRET_LINE.encode()).decode()[:20], t, f)

    # 4. Живой адрес ------------------------------------------------------------
    def test_live_check(self):
        self.assertTrue(progress.http_ok(self.health.url))
        self.assertFalse(progress.http_ok("http://127.0.0.1:9/nothing", timeout=2))

    # 5. YAML -------------------------------------------------------------------
    def test_mini_yaml(self):
        text = (SKILL / "templates" / "weights.yml").read_text(encoding="utf-8")
        mine = progress.mini_yaml(text)
        self.assertEqual(mine["stages"]["security"], 15)
        self.assertEqual(sum(mine["stages"].values()), 100)
        self.assertEqual(mine["schedule"]["expected_end_of_week"], [5, 25, 50, 65, 90, 100])
        self.assertEqual(mine["schedule"]["start_date"], "")
        roster = progress.mini_yaml("participants:\n  - name: Анна\n    repo: a/b  # коммент\n    mode: hub\n  - name: Б\n    repo: c/d\n")
        self.assertEqual(roster["participants"][0], {"name": "Анна", "repo": "a/b", "mode": "hub"})
        try:
            import yaml  # type: ignore
        except ImportError:
            return
        self.assertEqual(mine, yaml.safe_load(text))

    def test_parse_repo(self):
        self.assertEqual(progress.parse_repo("https://github.com/a/b.git"), ("a", "b"))
        self.assertEqual(progress.parse_repo("git@github.com:a/b.git"), ("a", "b"))
        self.assertEqual(progress.parse_repo("a/b"), ("a", "b"))
        with self.assertRaises(ValueError):
            progress.parse_repo("just-name")

    def test_verdict_parsers(self):
        self.assertEqual(progress.check_security_verdict(SECURITY_OK), 1.0)
        self.assertEqual(progress.check_security_verdict(SECURITY_NO), 0.0)
        tpl = "**Можно открывать людям** (в хабе: подключать к хабу): да / нет, потому что [одна фраза]"
        self.assertEqual(progress.check_security_verdict(tpl), 0.0)
        self.assertEqual(progress.check_review(REVIEW_OK), 1.0)
        self.assertEqual(progress.check_review("**Блокирующих замечаний**: 2"), 0.3)
        self.assertEqual(progress.check_hub_decision("**Решение**: подключён"), 1.0)
        self.assertEqual(progress.check_hub_decision("**Решение**: не подключён"), 0.25)

    # 6. Отчёт в браузере ----------------------------------------------------
    def test_report_renders(self):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            self.skipTest("нет пакета playwright")
        shots = Path(os.environ.get("PROGRESS_SCREENSHOTS") or (self.tmp / "shots"))
        shots.mkdir(parents=True, exist_ok=True)
        url = (self.out / "index.html").resolve().as_uri()
        with sync_playwright() as p:
            browser = None
            for opts in ({}, {"executable_path": os.environ.get("PLAYWRIGHT_CHROME") or "/usr/bin/google-chrome"}):
                try:
                    browser = p.chromium.launch(**opts)
                    break
                except Exception:  # noqa: BLE001
                    continue
            if browser is None:
                self.skipTest("нет Chromium для Playwright")
            for scheme, w, h, name in (("light", 1280, 900, "desktop-light"), ("dark", 1280, 900, "desktop-dark"),
                                       ("light", 390, 844, "phone-light")):
                ctx = browser.new_context(viewport={"width": w, "height": h}, color_scheme=scheme)
                page = ctx.new_page()
                errors = []
                page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.goto(url)
                page.wait_for_selector("#line svg")
                self.assertEqual(errors, [], name)
                self.assertEqual(page.locator("#lb .lb-row").count(), 6)
                self.assertGreater(page.locator("#line svg path").count(), 3)
                self.assertGreater(page.locator("#funnel svg rect").count(), 6)
                self.assertGreater(page.locator("#company svg rect").count(), 2)
                self.assertGreater(page.locator("#heat td.c").count(), 50)
                self.assertGreater(page.locator("#help li").count(), 1)
                overflow = page.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
                self.assertLessEqual(overflow, 0, f"горизонтальная прокрутка на {name}")
                if name == "desktop-light":
                    page.locator("#lb .lb-row").nth(1).click()
                    self.assertEqual(page.locator("#line-legend span").count(), 3)
                    page.select_option("#f-company", "Север")
                    self.assertEqual(page.locator("#lb .lb-row").count(), 3)
                    page.select_option("#f-company", "")
                page.screenshot(path=str(shots / f"{name}.png"), full_page=True)
                ctx.close()
            browser.close()
        print(f"\nСкриншоты отчёта: {shots}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Несколько потоков, репозиторий без владельца, монорепозиторий, старая история
# ---------------------------------------------------------------------------

MULTI_ROSTER = """name,company,department,mode,repo,branch,live_url,cohort,path
Алия Осень-1,Арома,продажи,solo,mc/a1,main,,Осень,
Арман Осень-2,Север,склад,solo,mc/a2,main,,Осень,
Белла Зима-1,Арома,финансы,solo,mc/b1,main,,Зима,
Бахыт Зима-2,Север,продажи,solo,b2,main,,Зима,
"""
MULTI_WEIGHTS = """stages: {start: 5, plan: 20, data: 25, security: 15, launch: 25, demo: 10}
thresholds:
  stall_days: 30
schedule:
  start_date: ""
  expected_end_of_week: [5, 25, 50, 65, 90, 100]
  cohorts:
    Осень:
      start_date: "2026-11-02"
    Зима:
      start_date: "2026-11-16"
"""

MONO_ROSTER = """name,company,department,mode,repo,branch,live_url,cohort,path
Фарида Финансы,Дару,финансы,hub,{repo},main,,Монорепо,services/finance
Серик Склад,Дару,склад,hub,{repo},main,,Монорепо,services/stock
"""


def launch_browser(p):
    for opts in ({}, {"executable_path": os.environ.get("PLAYWRIGHT_CHROME") or "/usr/bin/google-chrome"}):
        try:
            return p.chromium.launch(**opts)
        except Exception:  # noqa: BLE001
            continue
    return None


class MultiCohortTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="airl_progress_mc_"))
        base = cls.tmp / "repos"

        def init(d):
            d.mkdir(parents=True)
            git(d, "init", "-q", "-b", "main")
            return d
        a1 = init(base / "mc__a1")
        commit(a1, {"CLAUDE.md": LONG, "SPEC.md": SPEC_FULL, "ARCHITECTURE.md": ARCH}, "2026-11-10T10:00:00Z")
        a2 = init(base / "mc__a2")
        commit(a2, {"CLAUDE.md": LONG}, "2026-11-10T10:00:00Z")
        b1 = init(base / "mc__b1")
        commit(b1, {"README.md": "x"}, "2026-11-17T10:00:00Z")
        b2 = init(base / "b2")                       # без владельца: папка просто «b2»
        commit(b2, {"CLAUDE.md": LONG, "SPEC.md": SPEC_TEMPLATE}, "2026-11-17T10:00:00Z")
        cls.roster = cls.tmp / "roster.csv"
        cls.roster.write_text(MULTI_ROSTER, encoding="utf-8")
        cls.weights = cls.tmp / "weights.yml"
        cls.weights.write_text(MULTI_WEIGHTS, encoding="utf-8")
        cls.data = cls.tmp / "progress.jsonl"
        cls.out = cls.tmp / "report"
        common = ["--roster", str(cls.roster), "--weights", str(cls.weights), "--local", str(base),
                  "--data", str(cls.data), "--out", str(cls.out), "--no-live"]
        run("check", *common, "--now", NOW[0])
        commit(a2, {"SPEC.md": SPEC_FULL, "ARCHITECTURE.md": ARCH}, "2026-11-18T12:00:00Z")
        commit(b1, {"CLAUDE.md": LONG}, "2026-11-18T12:00:00Z")
        run("check", *common, "--now", NOW[1])
        commit(a2, {"DWH.md": LONG, "migrations/001.sql": "--"}, "2026-11-20T12:00:00Z")
        cls.tg = run("check", *common, "--now", NOW[2], "--telegram-text")
        cls.hist = progress.load_history(cls.data)

    @classmethod
    def tearDownClass(cls):
        if not os.environ.get("KEEP_TMP"):
            shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_cohorts_stats(self):
        self.assertEqual(len(self.hist), 3)
        for snap in self.hist:
            self.assertEqual(set(snap["cohorts"]), {"Осень", "Зима"})
            self.assertEqual(snap["cohort"], "Все потоки")
            for c in ("Осень", "Зима"):
                pc = [r["percent"] for r in snap["participants"] if r["cohort"] == c]
                self.assertEqual(len(pc), 2)
                st = next(x for x in progress.cohort_stats(snap) if x["cohort"] == c)
                self.assertAlmostEqual(st["avg"], sum(pc) / 2)
                self.assertAlmostEqual(st["median"], sum(pc) / 2)
                self.assertAlmostEqual(sum(st["stages"].values()), 1.0)
            # у каждого потока свой план по своей дате старта
            t = progress.parse_ts(snap["ts"])
            cfg = progress.load_config(str(self.weights))
            self.assertEqual(snap["cohorts"]["Осень"]["start_date"], "2026-11-02")
            self.assertAlmostEqual(snap["cohorts"]["Осень"]["expected"],
                                   round(progress.expected_percent(cfg, t, "Осень"), 1))
            self.assertLess(snap["cohorts"]["Зима"]["expected"], snap["cohorts"]["Осень"]["expected"])
            self.assertIsNone(snap["expected"])                      # планы разные
            for r in snap["participants"]:
                self.assertEqual(r["expected"], snap["cohorts"][r["cohort"]]["expected"])
        # «Осень» растёт по снимкам (a2 догоняет)
        av = [next(x for x in progress.cohort_stats(s) if x["cohort"] == "Осень")["avg"] for s in self.hist]
        self.assertLess(av[0], av[1])
        self.assertLess(av[1], av[2])
        # отстаёт относительно плана своего потока
        last = by_id(self.hist[-1])
        self.assertIn("behind", {f["kind"] for f in last["mc/a2"]["flags"]} | {f["kind"] for f in last["mc/a1"]["flags"]})
        md = (self.out / "summary.md").read_text(encoding="utf-8")
        self.assertIn("## Сравнение потоков", md)
        self.assertIn("потоков: 2", md)
        st = {x["cohort"]: x for x in progress.cohort_stats(self.hist[-1])}
        self.assertIn(f"| Осень | 2 | {st['Осень']['avg']:.0f} |", md)
        self.assertIn("Участников: 4, потоков: 2", self.tg)
        self.assertIn("• Осень — 2 уч., средний", self.tg)
        self.assertIn("• Зима — 2 уч., средний", self.tg)
        html = (self.out / "index.html").read_text(encoding="utf-8")
        self.assertIn("Сравнение потоков", html)
        self.assertIn('id="f-cohort"', html)
        self.assertIn('"cohort": "Зима"', html)

    def test_repo_without_owner_local(self):
        r = by_id(self.hist[-1])["b2"]
        self.assertNotIn("error", r)
        self.assertEqual(r["items"]["claude_md"], 1.0)
        self.assertEqual(r["activity"]["commits_7d"], 1)
        self.assertEqual(progress.load_roster(str(self.roster))[3]["owner"], "")
        # нет папки — понятная ошибка с путями, где искали
        bad = self.tmp / "bad.csv"
        bad.write_text("name,repo\nНикто,nothing-here\n", encoding="utf-8")
        run("check", "--roster", str(bad), "--local", str(self.tmp / "repos"), "--data",
            str(self.tmp / "bad" / "p.jsonl"), "--out", str(self.tmp / "bad" / "r"), "--no-live")
        err = progress.load_history(self.tmp / "bad" / "p.jsonl")[-1]["participants"][0]["error"]
        self.assertIn("нет локальной папки", err)
        self.assertIn("nothing-here", err)
        # для GitHub имя без владельца — ошибка строки, а не падение
        with self.assertRaises(ValueError):
            progress.parse_repo("b2")

    def test_old_single_cohort_history(self):
        old = json.loads(json.dumps(self.hist[0]))
        old.pop("cohorts")
        old["cohort"] = "Старая-когорта"
        old["participants"] = [r for r in old["participants"] if r["cohort"] == "Осень"]
        for r in old["participants"]:
            r.pop("cohort")
            r.pop("path", None)
        d = self.tmp / "old"
        d.mkdir()
        (d / "p.jsonl").write_text(json.dumps(old, ensure_ascii=False) + "\n", encoding="utf-8")
        tg = run("report", "--data", str(d / "p.jsonl"), "--out", str(d / "r"), "--telegram-text")
        self.assertIn("Старая-когорта", tg)
        self.assertNotIn("потоков", tg)
        md = (d / "r" / "summary.md").read_text(encoding="utf-8")
        self.assertIn("# Прогресс когорты «Старая-когорта»", md)
        self.assertNotIn("Сравнение потоков", md)
        html = (d / "r" / "index.html").read_text(encoding="utf-8")
        self.assertIn("Алия Осень-1", html)
        self.__class__.old_html = d / "r" / "index.html"

    def test_report_browser(self):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            self.skipTest("нет пакета playwright")
        if not hasattr(self.__class__, "old_html"):
            self.test_old_single_cohort_history()
        shots = Path(os.environ.get("PROGRESS_SCREENSHOTS") or (self.tmp / "shots"))
        shots.mkdir(parents=True, exist_ok=True)
        url = (self.out / "index.html").resolve().as_uri()
        with sync_playwright() as p:
            browser = launch_browser(p)
            if browser is None:
                self.skipTest("нет Chromium для Playwright")
            for scheme, w, h, name in (("light", 1280, 900, "desktop-light"), ("dark", 1280, 900, "desktop-dark"),
                                       ("light", 390, 844, "phone-light")):
                ctx = browser.new_context(viewport={"width": w, "height": h}, color_scheme=scheme, device_scale_factor=2)
                page = ctx.new_page()
                errors = []
                page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.goto(url)
                page.wait_for_selector("#cmp-line svg")
                self.assertTrue(page.locator("#sec-cohorts").is_visible())
                self.assertEqual(page.locator("#cmp-table tbody tr").count(), 2)
                self.assertEqual(page.locator("#cmp-line svg path[data-cohort]").count(), 2)
                self.assertIn("дни от старта", page.locator("#cmp-axis").inner_text())
                self.assertEqual(page.locator("#lb .lb-row").count(), 4)
                self.assertIn("4", page.locator("#tiles").inner_text())
                page.select_option("#f-cohort", "Зима")
                self.assertEqual(page.locator("#lb .lb-row").count(), 2)
                self.assertIn("Зима", page.locator("#title").inner_text())
                self.assertEqual(page.locator("#cmp-table tbody tr.on").count(), 1)
                page.select_option("#f-company", "Арома")
                self.assertEqual(page.locator("#lb .lb-row").count(), 1)
                self.assertEqual(page.locator("#heat tbody tr").count(), 1)
                self.assertEqual(page.locator("#cmp-table tbody tr").count(), 2)
                page.select_option("#f-company", "")
                if name != "phone-light":
                    page.select_option("#f-cohort", "")
                overflow = page.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
                self.assertLessEqual(overflow, 0, f"горизонтальная прокрутка на {name}")
                self.assertEqual(errors, [], name)
                page.screenshot(path=str(shots / f"progress-multicohort-{name}.png"), full_page=True)
                ctx.close()
            # старая история: блок сравнения скрыт, ошибок нет
            ctx = browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2)
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            page.goto(self.old_html.resolve().as_uri())
            page.wait_for_selector("#line svg")
            self.assertFalse(page.locator("#sec-cohorts").is_visible())
            self.assertEqual(page.locator("#lb .lb-row").count(), 2)
            self.assertEqual(errors, [])
            page.screenshot(path=str(shots / "progress-multicohort-old-history.png"), full_page=True)
            ctx.close()
            browser.close()
        print(f"\nСкриншоты (несколько потоков): {shots}", file=sys.stderr)


class MonorepoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="airl_progress_mono_"))
        cls.base = cls.tmp / "repos"
        m = cls.base / "org__mono"
        m.mkdir(parents=True)
        git(m, "init", "-q", "-b", "main")
        commit(m, {"README.md": "монорепозиторий", ".github/workflows/ci.yml": "name: ci",
                   "services/stock/CLAUDE.md": LONG}, "2026-11-13T08:00:00Z")
        commit(m, {"services/finance/CLAUDE.md": LONG, "services/finance/SPEC.md": SPEC_FULL,
                   "services/finance/ARCHITECTURE.md": ARCH.replace("solo", "hub"),
                   "services/finance/DWH.md": LONG}, "2026-11-20T10:00:00Z")
        commit(m, {"services/finance/migrations/001.sql": "--"}, "2026-11-22T10:00:00Z")

    @classmethod
    def tearDownClass(cls):
        if not os.environ.get("KEEP_TMP"):
            shutil.rmtree(cls.tmp, ignore_errors=True)

    def _check(self, tag, repo, local, extra=()):
        roster = self.tmp / f"{tag}.csv"
        roster.write_text(MONO_ROSTER.format(repo=repo), encoding="utf-8")
        d = self.tmp / tag
        args = ["check", "--roster", str(roster), "--data", str(d / "p.jsonl"), "--out", str(d / "r"),
                "--now", NOW[2], "--no-live", *extra]
        if local:
            args += ["--local", str(local)]
        run(*args)
        return progress.load_history(d / "p.jsonl")[-1]

    def _assert_mono(self, snap, fin_id, st_id):
        s = by_id(snap)
        fin, st = s[fin_id], s[st_id]
        self.assertNotIn("error", fin)
        self.assertNotIn("error", st)
        self.assertEqual(fin["items"]["spec_pain"], 1.0)
        self.assertEqual(fin["items"]["migrations"], 1.0)
        self.assertEqual(st["items"]["spec"], 0.0)
        self.assertEqual(st["items"]["migrations"], 0.0)          # миграции соседа не засчитываются
        self.assertEqual(fin["items"]["ci"], 1.0)                  # CI в корне монорепозитория
        self.assertEqual(st["items"]["ci"], 1.0)
        self.assertGreater(fin["percent"], st["percent"] + 10)
        self.assertEqual(fin["activity"]["commits_7d"], 2)
        self.assertEqual(st["activity"]["commits_7d"], 0)
        self.assertEqual(st["activity"]["days_since_commit"], 10)
        stalled = [f for f in st["flags"] if f["kind"] == "stalled"]
        self.assertEqual(stalled and stalled[0]["label"], "застрял 10 дн.")
        self.assertNotIn("stalled", {f["kind"] for f in fin["flags"]})
        return fin, st

    def test_monorepo_local(self):
        snap = self._check("local", "org/mono", self.base)
        fin, _ = self._assert_mono(snap, "org/mono:services/finance", "org/mono:services/stock")
        self.assertEqual(fin["path"], "services/finance")

    def test_monorepo_local_without_owner(self):
        snap = self._check("noowner", "org__mono", self.base)
        self._assert_mono(snap, "org__mono:services/finance", "org__mono:services/stock")

    def test_folder_inside_git_repo(self):
        # список указывает на «services», а папка лежит внутри git-репозитория
        roster = self.tmp / "inside.csv"
        roster.write_text("name,repo,cohort\nФин,finance,X\nСклад,stock,X\n", encoding="utf-8")
        d = self.tmp / "inside"
        run("check", "--roster", str(roster), "--local", str(self.base / "org__mono" / "services"),
            "--data", str(d / "p.jsonl"), "--out", str(d / "r"), "--now", NOW[2], "--no-live")
        s = by_id(progress.load_history(d / "p.jsonl")[-1])
        self.assertEqual(s["finance"]["activity"]["commits_7d"], 2)
        self.assertEqual(s["stock"]["activity"]["days_since_commit"], 10)
        self.assertEqual(s["finance"]["items"]["ci"], 1.0)

    def test_monorepo_github_api(self):
        fake = FakeGitHub(self.base)
        old = {k: os.environ.get(k) for k in ("GITHUB_API_URL", "GITHUB_TOKEN", "GH_TOKEN")}
        os.environ["GITHUB_API_URL"] = fake.url
        os.environ["GITHUB_TOKEN"] = FAKE_TOKEN
        os.environ.pop("GH_TOKEN", None)
        try:
            snap = self._check("gh", "org/mono", None)
        finally:
            fake.close()
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self._assert_mono(snap, "org/mono:services/finance", "org/mono:services/stock")
        self.assertTrue(any("path=services/stock" in x for x in fake.log))
        loc = by_id(self._check("local2", "org/mono", self.base))
        for pid, p in by_id(snap).items():
            self.assertEqual(p["items"], loc[pid]["items"], pid)


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1)
