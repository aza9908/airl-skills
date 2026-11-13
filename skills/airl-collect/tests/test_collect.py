#!/usr/bin/env python3
"""Проверка scripts/collect.py без сети.

  python3 skills/airl-collect/tests/test_collect.py
  python3 skills/airl-collect/tests/test_collect.py -v

Что проверяется:
  1. четыре поддельных репозитория участников (git init): заполненное ТЗ с ключом,
     телефоном, ИИН и почтой; монорепозиторий с сервисом в подпапке (колонка path);
     репозиторий без SPEC.md; ТЗ — нетронутый шаблон /airl-spec;
  2. раскладка <поток>/<компания>/<участник>/, meta.json, готовность ТЗ по разделам,
     маскирование (в копиях нет ключа, телефона, ИИН и почты, счётчики в meta.json);
  3. оглавление: таблица в README.md, PAINS.md находит одну боль у двух компаний
     («кандидат в модуль»), METRICS.md считает показатели;
  4. второй запуск с изменённым SPEC.md дописывает CHANGELOG.md; запуск без изменений
     не меняет ни одного файла (иначе GitHub Actions коммитил бы каждый день);
  5. путь через GitHub API (поддельный сервер): те же копии, скачиваются только
     документы, повторно — ничего; токен не попадает ни в файлы, ни в вывод;
  6. отказ писать в публичный репозиторий коллекции; --allow-public; закрытый — ок;
  7. --on-secret skip, команды index и changes.

Нужно: Python 3.9+, git. Код выхода: 0 — всё прошло, 1 — есть провалы.
"""
from __future__ import annotations

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
ROOT = SKILL.parent.parent
sys.path.insert(0, str(SKILL / "scripts"))
import collect  # noqa: E402

FAKE_TOKEN = "ghp_FAKE_TOKEN_must_not_leak_123456"
SECRET_IN_SPEC = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
PHONE = "+7 701 123 45 67"
EMAIL = "aigerim.s@client-company.kz"
NOW = ["2026-11-16T03:00:00Z", "2026-11-18T03:00:00Z", "2026-11-19T03:00:00Z"]


def valid_iin() -> str:
    for base in ("90051530012", "88020340056", "75111250031"):
        for d in range(10):
            if collect._iin_ok(base + str(d)):
                return base + str(d)
    raise RuntimeError("не нашёл ИИН для теста")


IIN = valid_iin()


def spec(title, dept, now_line, price, metric, extra=""):
    return f"""---
service_id: test
spec_version: 1.0
status: утверждено
owner: тест
---
<!-- подсказка шаблона: не считается -->

# PRD продукта «{title}»

Автор: тест, руководитель, {dept}

## 1. Боль и результат
**Сейчас**: {now_line}
**Цена боли**: {price} — как замерили: журнал за неделю
**После запуска**: всё в одном месте
**Метрика успеха для Demo Day**: {metric}

## 2. Пользователи и роли
| Роль | Кто это | Как часто | Что видит | Что может менять |
|---|---|---|---|---|
| `manager` | менеджер | каждый день | свои заявки | статус |

## 3. Главное действие
Принять заявку — доступно с первого экрана за 2 касания.

## 4. Экраны
### 4.1 Список
Зачем: видеть заявки · главная кнопка: «Принять»

## 5. Данные
| Сущность | Главные поля | Связи | Персональные данные |
|---|---|---|---|
| Заявка | клиент, статус | клиент | телефон клиента |

## 6. Показатели продукта
| Показатель | Формула | Откуда данные | Где показываем |
|---|---|---|---|
| `lost_requests` | потерянные / все | заявки | главный |
| `response_time_min` | среднее время ответа | заявки | главный |

## 7. Внешние сервисы и API
| Сервис | Что берём | Что отдаём | Как часто | Доступ к API есть? |
|---|---|---|---|---|
| WhatsApp | сообщения | ничего | 15 мин | да |

## 8. Условия работы
Устройства: телефон · пользователей: 12

## 9. Доступы и персональные данные
Страна данных: KZ · персональные данные: телефон клиента · маска: телефон

## 10. Критерии готовности
- [ ] менеджер принимает заявку с телефона за 2 касания
- [ ] чужую заявку нельзя открыть подменой номера в адресе
- [ ] доля потерянных заявок ниже 2% за неделю пилота

## 11. Не делаем сейчас
- оплату онлайн — позже

## 12. План спринтов
- [x] Неделя 0 · Замер «было»: менеджер замеряет с 2026-11-02
- [ ] Неделя 1 · План

{extra}
"""


SPEC_ACME = spec("Заявки без потерь", "продажи",
                 "Заявки клиентов теряются в чатах WhatsApp, менеджеры отвечают с опозданием.",
                 "12 потерянных заявок в неделю, около 900 000 тенге",
                 "было 12 потерянных заявок в неделю → стало не больше 2",
                 extra=f"## 13. Решено по умолчанию\n- контакт клиента: {PHONE}, {EMAIL}, ИИН {IIN}\n"
                       f"- ключ бота для теста: token = {SECRET_IN_SPEC}\n")
SPEC_BETA = spec("Обращения в одном окне", "сервис",
                 "Заявки от клиентов теряются между чатами и звонками, ответ занимает день.",
                 "20 потерянных заявок в месяц",
                 "было 20 потерянных заявок в месяц → стало 0")
SPEC_ROOT_MONO = "# Корневой SPEC монорепозитория — его брать НЕЛЬЗЯ\n"


def git(repo: Path, *args, date="2026-11-10T10:00:00Z"):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@example.com", GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=env).stdout


def write_repo(path: Path, files: dict[str, str]):
    path.mkdir(parents=True, exist_ok=True)
    for rel, text in files.items():
        f = path / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text, encoding="utf-8")
    if not (path / ".git").exists():
        git(path, "init", "-q", "-b", "main")
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "обновление", "--allow-empty")


class FakeGitHub:
    """Поддельный GitHub API поверх локальных git-репозиториев (как в тестах airl-progress)."""

    def __init__(self, base: Path, visibility: dict[str, bool] | None = None):
        self.base, self.visibility = base, visibility or {}
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
        self.httpd.server_close()

    def g(self, repo, *args):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True).stdout

    def route(self, path, headers):
        from urllib.parse import unquote, urlparse
        u = urlparse(path)
        parts = [unquote(p) for p in u.path.strip("/").split("/")]
        js = {"Content-Type": "application/json"}
        if len(parts) < 3 or parts[0] != "repos":
            return 404, b"{}", {}
        full = f"{parts[1]}/{parts[2]}"
        if full in self.visibility and len(parts) == 3:
            priv = self.visibility[full]
            return 200, json.dumps({"full_name": full, "private": priv,
                                    "visibility": "private" if priv else "public"}).encode(), js
        repo = self.base / f"{parts[1]}__{parts[2]}"
        if not repo.is_dir():
            return 404, b'{"message":"Not Found"}', {}
        rest = parts[3:]
        if not rest:
            return 200, json.dumps({"default_branch": "main", "private": True}).encode(), js
        if rest[0] == "branches" and len(rest) == 2:
            sha = self.g(repo, "rev-parse", rest[1]).decode().strip()
            return 200, json.dumps({"name": rest[1], "commit": {"sha": sha}}).encode(), js
        if rest[:2] == ["git", "trees"]:
            sha = rest[2]
            etag = '"' + sha + '"'
            if headers.get("If-None-Match") == etag:
                return 304, b"", {"ETag": etag}
            tree = []
            for ln in self.g(repo, "ls-tree", "-r", "-l", sha).decode().splitlines():
                meta, name = ln.split("\t", 1)
                _m, typ, bsha, size = meta.split()
                tree.append({"path": name, "type": typ, "sha": bsha, "size": int(size)})
            return 200, json.dumps({"sha": sha, "tree": tree}).encode(), dict(js, ETag=etag)
        if rest[:2] == ["git", "blobs"]:
            return 200, self.g(repo, "cat-file", "-p", rest[2]), {"Content-Type": "application/octet-stream"}
        return 404, b"{}", {}


def run(*args) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = collect.main(list(args))
    return code, out.getvalue(), err.getvalue()


def snapshot(d: Path) -> dict[str, str]:
    return {p.relative_to(d).as_posix(): p.read_text(encoding="utf-8")
            for p in sorted(d.rglob("*")) if p.is_file() and ".git" not in p.parts and ".airl-collect" not in p.parts}


class CollectTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="airl_collect_"))
        cls.repos = cls.tmp / "repos"
        template = (ROOT / "skills" / "airl-spec" / "templates" / "SPEC.md").read_text(encoding="utf-8")
        service = json.dumps({"id": "support", "hub": {"metrics": ["lost_requests", "csat_avg"]}})
        write_repo(cls.repos / "acme__sales-crm", {
            "SPEC.md": SPEC_ACME, "ARCHITECTURE.md": "# Архитектура\n\nОдин сервис и база.\n",
            ".env": "DATABASE_URL=postgres://u:supersecret1@db/x\n",
            "src/app.py": "SECRET = 'код не собираем'\n"})
        write_repo(cls.repos / "beta__mono", {
            "SPEC.md": SPEC_ROOT_MONO,
            "services/support/SPEC.md": SPEC_BETA,
            "services/support/ARCHITECTURE.md": "# Архитектура поддержки\n",
            "services/support/airl.service.json": service,
            "services/support/airl/COMPANY_MAP.md": "# Карта компании Beta\n",
            "services/support/main.go": "package main\n"})
        write_repo(cls.repos / "gamma__nospec", {"README.md": "# Пока пусто\n"})
        write_repo(cls.repos / "delta__draft", {"SPEC.md": template})
        cls.roster = cls.tmp / "roster.csv"
        cls.roster.write_text(
            "name,company,department,mode,repo,branch,live_url,cohort,path\n"
            "Айгерим С.,Acme,Продажи,solo,acme/sales-crm,,,VibeOps-2026-11,\n"
            "Бахтияр К.,Beta,Сервис,hub,beta/mono,,,VibeOps-2026-11,services/support\n"
            "Гульнара Т.,Gamma,Склад,solo,gamma/nospec,,,VibeOps-2026-11,\n"
            "Данияр Е.,Delta,Финансы,solo,delta/draft,,,VibeOps-2026-11,\n"
            "Ерлан Ж.,Echo,HR,solo,echo/missing,,,VibeOps-2026-11,\n", encoding="utf-8")
        cls.out = cls.tmp / "collection"
        code, cls.stdout, cls.stderr = run("collect", "--roster", str(cls.roster), "--out", str(cls.out),
                                           "--local", str(cls.repos), "--now", NOW[0])
        assert code == 0, cls.stderr
        cls.base = cls.out / "vibeops-2026-11"

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def meta(self, rel):
        return json.loads((self.base / rel / "meta.json").read_text(encoding="utf-8"))

    # 2. раскладка, meta, маскирование, готовность ----------------------------
    def test_layout_and_meta(self):
        self.assertTrue((self.base / "acme" / "aigerim-s" / "SPEC.md").is_file())
        self.assertTrue((self.base / "acme" / "aigerim-s" / "ARCHITECTURE.md").is_file())
        self.assertFalse((self.base / "acme" / "aigerim-s" / ".env").exists())
        self.assertEqual(sorted(p.name for p in (self.base / "acme" / "aigerim-s").iterdir()),
                         ["ARCHITECTURE.md", "CHANGELOG.md", "SPEC.md", "meta.json"])
        m = self.meta("acme/aigerim-s")
        self.assertEqual(m["source"]["repo"], "acme/sales-crm")
        self.assertEqual(len(m["source"]["commit"]), 40)
        self.assertEqual(m["fetched_at"], NOW[0])
        self.assertEqual(m["found"], ["SPEC.md", "ARCHITECTURE.md"])
        self.assertEqual(m["missing"], [])
        self.assertEqual(m["product"], "Заявки без потерь")
        self.assertIn("теряются", m["pain"])
        self.assertIn("было 12", m["metric"])

    def test_monorepo_path(self):
        d = self.base / "beta" / "bahtiyar-k"
        self.assertIn("Обращения в одном окне", (d / "SPEC.md").read_text(encoding="utf-8"))
        self.assertTrue((d / "airl" / "COMPANY_MAP.md").is_file())
        self.assertTrue((d / "airl.service.json").is_file())
        self.assertFalse((d / "main.go").exists())
        m = self.meta("beta/bahtiyar-k")
        self.assertEqual(m["source"]["path"], "services/support")
        self.assertEqual(m["missing"], [])
        self.assertEqual(m["files"]["SPEC.md"]["source"], "SPEC.md")

    def test_masking(self):
        text = (self.base / "acme" / "aigerim-s" / "SPEC.md").read_text(encoding="utf-8")
        for bad in (SECRET_IN_SPEC, PHONE, EMAIL, IIN):
            self.assertNotIn(bad, text)
        for mark in ("‹ключ скрыт›", "‹телефон скрыт›", "‹почта скрыта›", "‹ИИН скрыт›"):
            self.assertIn(mark, text)
        self.assertIn("900 000 тенге", text, "обычные числа не должны маскироваться")
        m = self.meta("acme/aigerim-s")
        self.assertEqual(m["masked"], {"secret": 1, "email": 1, "iin": 1, "phone": 1})
        self.assertIn("Скрыто в копиях", self.stdout)
        # все копии во всей коллекции
        for p in self.out.rglob("*"):
            if p.is_file():
                t = p.read_text(encoding="utf-8")
                self.assertNotIn(SECRET_IN_SPEC, t, p)
                self.assertNotIn("supersecret1", t, p)
                self.assertNotIn("код не собираем", t, p)

    def test_mask_unit(self):
        t, c = collect.mask_text("Пароль: хранится у директора. password=Qwerty12345 "
                                 "postgres://app:S3cr3tPass@db:5432/x 8 701 555 66 77 сумма 8 500 000")
        self.assertIn("Пароль: хранится", t)
        self.assertNotIn("Qwerty12345", t)
        self.assertNotIn("S3cr3tPass", t)
        self.assertNotIn("555 66 77", t)
        self.assertIn("8 500 000", t)
        self.assertEqual(c["secret"], 2)
        self.assertEqual(c["phone"], 1)

    def test_completeness(self):
        full = self.meta("acme/aigerim-s")["completeness"]
        draft = self.meta("delta/daniyar-e")["completeness"]
        self.assertGreaterEqual(full["percent"], 85)
        self.assertEqual(full["pain_in_numbers"], 1.0)
        self.assertEqual(full["metric_before_after"], 1.0)
        self.assertEqual(full["acceptance_criteria"], 1.0)
        self.assertLessEqual(draft["percent"], 15, draft)
        self.assertGreater(draft["unfilled_markers"], 20)
        self.assertEqual(draft["pain_in_numbers"], 0.0)
        self.assertEqual(self.meta("delta/daniyar-e")["product"], "")

    def test_missing_spec_and_no_access(self):
        m = self.meta("gamma/gulnara-t")
        self.assertEqual(m["missing"], ["SPEC.md", "ARCHITECTURE.md"])
        self.assertEqual(m["found"], [])
        e = self.meta("echo/erlan-zh")
        self.assertIn("error", e)
        self.assertIn("Нет SPEC.md: Гульнара Т.", self.stdout)

    # 3. оглавление ------------------------------------------------------------
    def test_readme_index(self):
        r = (self.out / "README.md").read_text(encoding="utf-8")
        self.assertIn("## Поток VibeOps-2026-11", r)
        self.assertIn("| Участник | Компания | Отдел | Режим | Продукт | Главная боль | Метрика |", r)
        row = next(ln for ln in r.splitlines() if ln.startswith("| Айгерим С."))
        self.assertIn("Заявки без потерь", row)
        self.assertIn("[открыть](vibeops-2026-11/acme/aigerim-s/)", row)
        self.assertIn("| хаб |", next(ln for ln in r.splitlines() if ln.startswith("| Бахтияр К.")))
        self.assertIn("нет SPEC.md", next(ln for ln in r.splitlines() if ln.startswith("| Гульнара Т.")))
        self.assertIn("нет доступа", next(ln for ln in r.splitlines() if ln.startswith("| Ерлан Ж.")))
        self.assertIn("Закрытый репозиторий", r)
        for bad in (PHONE, EMAIL, IIN):
            self.assertNotIn(bad, r)

    def test_pains_cluster(self):
        p = (self.out / "PAINS.md").read_text(encoding="utf-8")
        cand = p.split("## Кандидаты в модуль")[1].split("\n## ")[0]
        self.assertIn("повторяется у 2 компаний → кандидат в модуль", cand)
        self.assertIn("**Acme**", cand)
        self.assertIn("**Beta**", cand)
        self.assertIn("заявки", cand.lower())
        self.assertNotIn("журнал", cand, "«как замерили» не входит в боль")
        self.assertNotIn("Delta", cand)
        self.assertIn("### продажи", p)
        self.assertIn("### сервис", p)
        s = json.loads((self.out / "summary.json").read_text(encoding="utf-8"))
        c = [x for x in s["pain_clusters"] if x["module_candidate"]]
        self.assertEqual(len(c), 1)
        self.assertEqual(c[0]["companies"], ["Acme", "Beta"])

    def test_metrics(self):
        m = (self.out / "METRICS.md").read_text(encoding="utf-8")
        row = next(ln for ln in m.splitlines() if ln.startswith("| `lost_requests`"))
        self.assertTrue(row.startswith("| `lost_requests` | 2 | 2 |"), row)
        self.assertIn("| `csat_avg` | 1 | 1 |", m)
        self.assertNotIn("[название]", m)
        self.assertNotIn("whatsapp", m, "раздел 7 своего продукта — внешние сервисы, а не показатели")
        hub = ("## 6. Показатели\n| id из карты | Где | Светофор |\n|---|---|---|\n| `revenue` | главный | > 0 |\n"
               "## 7. Что отдаёт в хаб\n| id | Название | Период |\n|---|---|---|\n| `ar_overdue` | долг | месяц |\n"
               "| `[id]` | [название] | [период] |\n")
        self.assertEqual(collect.metrics_declared(hub, None), ["revenue", "ar_overdue"])

    # 4. повторный запуск -----------------------------------------------------
    def test_second_run_changelog_and_idempotent(self):
        out = self.tmp / "coll2"
        repos = self.tmp / "repos2"
        shutil.copytree(self.repos, repos)
        args = ["collect", "--roster", str(self.roster), "--out", str(out), "--local", str(repos)]
        self.assertEqual(run(*args, "--now", NOW[0])[0], 0)
        changed = SPEC_BETA.replace("было 20 потерянных заявок в месяц → стало 0",
                                    "было 20 потерянных заявок в месяц → стало 1").replace(
            "## 11. Не делаем сейчас", "## 11. Не делаем сейчас\n- чат-бот — после пилота")
        changed += "\n## 14. Модули\n| Модуль | Требования | Владелец | Приёмка |\n|---|---|---|---|\n" \
                   "| `complaints` | обращения | Бахтияр | [ ] |\n"
        write_repo(repos / "beta__mono", {"services/support/SPEC.md": changed}, )
        code, so, _ = run(*args, "--now", NOW[1])
        self.assertEqual(code, 0)
        self.assertIn("Бахтияр К. — изменены: SPEC.md", so)
        cl = (out / "vibeops-2026-11/beta/bahtiyar-k/CHANGELOG.md").read_text(encoding="utf-8")
        self.assertIn("## 2026-11-16", cl)
        self.assertIn("## 2026-11-18", cl)
        self.assertIn("Первый сбор", cl)
        self.assertIn("Разделы добавлены: «14. Модули»", cl)
        self.assertIn("«1. Боль и результат»", cl)
        self.assertIn("«11. Не делаем сейчас»", cl)
        m = json.loads((out / "vibeops-2026-11/beta/bahtiyar-k/meta.json").read_text(encoding="utf-8"))
        self.assertEqual(m["spec_changed_at"], NOW[1])
        acme = json.loads((out / "vibeops-2026-11/acme/aigerim-s/meta.json").read_text(encoding="utf-8"))
        self.assertEqual(acme["spec_changed_at"], NOW[0], "чужое ТЗ не менялось")
        # запуск без изменений — ни один файл не меняется
        before = snapshot(out)
        code, so, _ = run(*args, "--now", NOW[2])
        self.assertEqual(snapshot(out), before)
        self.assertIn("Изменений нет", so)
        # что изменилось
        code, so, _ = run("changes", "--out", str(out), "--since", "2026-11-17")
        self.assertIn("Бахтияр К.", so)
        self.assertNotIn("Айгерим", so)
        code, so, _ = run(*args, "--now", NOW[2], "--since", "2026-11-17")
        self.assertIn("ТЗ, изменённые с 2026-11-17: 1", so)

    # 5. GitHub API --------------------------------------------------------------
    def test_github_api_path(self):
        fake = FakeGitHub(self.repos)
        keys = ("GITHUB_API_URL", "GITHUB_TOKEN", "GH_TOKEN", "COLLECTION_TOKEN", "GITHUB_REPOSITORY")
        old = {k: os.environ.get(k) for k in keys}
        os.environ["GITHUB_API_URL"] = fake.url
        os.environ["GITHUB_TOKEN"] = FAKE_TOKEN
        for k in ("GH_TOKEN", "COLLECTION_TOKEN", "GITHUB_REPOSITORY"):
            os.environ.pop(k, None)
        out = self.tmp / "coll-gh"
        try:
            args = ["collect", "--roster", str(self.roster), "--out", str(out), "--now", NOW[0]]
            c1, so1, se1 = run(*args)
            blobs1 = [x for x in fake.log if "/git/blobs/" in x]
            fake.log.clear()
            c2, so2, se2 = run(*args)
            blobs2 = [x for x in fake.log if "/git/blobs/" in x]
            trees2 = [x for x in fake.log if "/git/trees/" in x]
        finally:
            fake.close()
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.assertEqual((c1, c2), (0, 0), se1 + se2)
        self.assertIn("Bearer " + FAKE_TOKEN, fake.auth)
        # acme: SPEC + ARCHITECTURE; beta: 4 документа; delta: SPEC
        self.assertEqual(len(blobs1), 7, blobs1)
        self.assertEqual(blobs2, [], "неизменённые документы не скачиваются повторно")
        self.assertEqual(len(trees2), 4)
        for rel in ("vibeops-2026-11/acme/aigerim-s/SPEC.md", "vibeops-2026-11/beta/bahtiyar-k/SPEC.md",
                    "vibeops-2026-11/beta/bahtiyar-k/airl/COMPANY_MAP.md"):
            self.assertEqual((out / rel).read_text(encoding="utf-8"),
                             (self.out / rel).read_text(encoding="utf-8"), rel)
        m = json.loads((out / "vibeops-2026-11/beta/bahtiyar-k/meta.json").read_text(encoding="utf-8"))
        self.assertEqual(m["source"]["url"], "https://github.com/beta/mono/tree/main/services/support")
        self.assertIn(".airl-collect/", (out / ".gitignore").read_text(encoding="utf-8"))
        for text in [so1, se1, so2, se2] + [p.read_bytes().decode("utf-8", "replace")
                                            for p in out.rglob("*") if p.is_file()]:
            self.assertNotIn(FAKE_TOKEN, text)
        cache = (out / ".airl-collect" / "cache.json").read_text(encoding="utf-8")
        self.assertNotIn("main.go", cache, "в кеш попадают только документы")

    # 6. приватность репозитория коллекции -------------------------------------
    def test_public_collection_refused(self):
        fake = FakeGitHub(self.repos, {"airl/public-specs": False, "airl/airl-specs": True})
        keys = ("GITHUB_API_URL", "GITHUB_TOKEN", "GH_TOKEN", "COLLECTION_TOKEN", "GITHUB_REPOSITORY")
        old = {k: os.environ.get(k) for k in keys}
        os.environ["GITHUB_API_URL"] = fake.url
        os.environ["COLLECTION_TOKEN"] = FAKE_TOKEN
        for k in ("GITHUB_TOKEN", "GH_TOKEN", "GITHUB_REPOSITORY"):
            os.environ.pop(k, None)
        try:
            pub = self.tmp / "public-clone"
            pub.mkdir()
            git(pub, "init", "-q", "-b", "main")
            git(pub, "remote", "add", "origin", "https://github.com/airl/public-specs.git")
            base = ["collect", "--roster", str(self.roster), "--local", str(self.repos), "--now", NOW[0]]
            code, so, se = run(*base, "--out", str(pub))
            self.assertEqual(code, 2)
            self.assertIn("ПУБЛИЧНЫЙ", se)
            self.assertEqual([p.name for p in pub.iterdir()], [".git"], "в публичный репозиторий ничего не пишем")
            code, so, se = run(*base, "--out", str(pub), "--allow-public")
            self.assertEqual(code, 0)
            self.assertTrue((pub / "README.md").exists())
            priv = self.tmp / "private-clone"
            code, so, se = run(*base, "--out", str(priv), "--repo", "airl/airl-specs")
            self.assertEqual(code, 0)
            self.assertIn("закрытый — хорошо", se)
            self.assertIn("Bearer " + FAKE_TOKEN, fake.auth)
            self.assertNotIn(FAKE_TOKEN, so + se)
        finally:
            fake.close()
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    # 7. прочее --------------------------------------------------------------------
    def test_on_secret_skip(self):
        out = self.tmp / "coll-skip"
        code, so, _ = run("collect", "--roster", str(self.roster), "--out", str(out), "--local",
                          str(self.repos), "--now", NOW[0], "--on-secret", "skip")
        self.assertEqual(code, 0)
        self.assertFalse((out / "vibeops-2026-11/acme/aigerim-s/SPEC.md").exists())
        self.assertIn("SPEC.md пропущен — найдены ключи или пароли", so)
        m = json.loads((out / "vibeops-2026-11/acme/aigerim-s/meta.json").read_text(encoding="utf-8"))
        self.assertEqual(m["skipped"][0]["file"], "SPEC.md")

    def test_index_rebuild(self):
        out = self.tmp / "coll-index"
        shutil.copytree(self.out, out)
        before = (out / "README.md").read_text(encoding="utf-8")
        for f in ("README.md", "PAINS.md", "METRICS.md", "summary.json"):
            (out / f).unlink()
        code, so, _ = run("index", "--out", str(out))
        self.assertEqual(code, 0)
        self.assertEqual((out / "README.md").read_text(encoding="utf-8"), before)
        self.assertTrue((out / "PAINS.md").exists() and (out / "METRICS.md").exists())

    def test_roster_yaml_same_format(self):
        y = self.tmp / "roster.yml"
        y.write_text("participants:\n  - name: Бахтияр К.\n    company: Beta\n    mode: hub\n"
                     "    repo: beta/mono\n    path: services/support\n    cohort: VibeOps-2026-11\n",
                     encoding="utf-8")
        r = collect.load_roster(str(y))
        self.assertEqual((r[0]["id"], r[0]["mode"], r[0]["path"]), ("beta/mono:services/support", "hub",
                                                                     "services/support"))

    def test_progress_roster_example_works(self):
        ex = ROOT / "skills" / "airl-progress" / "templates" / "roster.example.csv"
        self.assertTrue(collect.load_roster(str(ex)), "пример списка /airl-progress читается")


if __name__ == "__main__":
    res = unittest.main(argv=sys.argv[:1] + (["-v"] if "-v" in sys.argv else []), exit=False).result
    sys.exit(0 if res.wasSuccessful() else 1)
