#!/usr/bin/env python3
"""Проверка шаблонов документов навыков AIRL.

  python3 tests/test_templates.py

Что проверяется:
  (a) каждый документ, который SKILL.md велит создать, записать или обновить
      («создай / запиши / обнови / положи / дополни … `FILE.md`»), имеет шаблон
      в skills/<навык>/templates/, и навык-владелец ссылается на свои шаблоны;
  (b) репозитории, собранные из ЗАПОЛНЕННЫХ шаблонов (свой продукт, сервис отдела,
      репозиторий хаба команды AIRL), progress.py --local доводит до конца курса:
      маркеры, которые проверяет /airl-progress, в шаблонах на месте;
  (c) вердикты SECURITY.md и REVIEW.md одинаково разбирают progress.py
      (/airl-progress) и check_service.py (ворота 6 и 7 /airl-hub);
  (d) methodology/templates/ совпадает с skills/*/templates/ (scripts/sync_templates.py).

Нужно: Python 3.9+, git. Без сети и без базы. Код выхода: 0 — всё прошло, 1 — есть провалы.
"""
from __future__ import annotations

import csv
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKILLS = ROOT / "skills"
sys.path.insert(0, str(SKILLS / "airl-progress" / "scripts"))
sys.path.insert(0, str(SKILLS / "airl-hub" / "scripts"))
sys.path.insert(0, str(ROOT / "scripts"))
import progress  # noqa: E402
import check_service  # noqa: E402
import sync_templates  # noqa: E402

VERBS = r"(?:Созда|созда|Пиш|пиш|Запиш|запиш|Обнов|обнов|Положи|положи|Дополни|дополни|Заполни|заполни)"
DOC_RE = re.compile(VERBS + r"[а-яё]*[^.\n]{0,60}`([A-Z][A-Z_]+\.md)`")
# Документы режима P: их шаблоны — отдельный справочник режима (references/prd-templates.md)
ELSEWHERE = {"PRD_CONTEXT.md": "airl-spec/references/prd-pipeline.md",
             "PRD_FINAL.md": "airl-spec/references/prd-templates.md",
             "BACKLOG.md": "airl-spec/references/prd-templates.md"}
# Кроме упомянутых глаголом — артефакты, без которых нет приёмки
REQUIRED = {"SPEC.md", "ARCHITECTURE.md", "COMPANY_MAP.md", "SCOPE.md", "SECURITY.md", "REVIEW.md",
            "DWH.md", "DEVOPS.md", "HUB_CHECK.md", "CLAUDE.md", "CONNECT.md", "AI.md", "HUB.md",
            "DEBUG.md", "INTEGRATIONS.md", "airl.service.json", ".env.example", "Dockerfile",
            "docker-compose.yml"}

NOW = "2026-11-20T09:00:00Z"
FILL = "значение 12 (проверено)"
PH = re.compile(r"\[[^\]\n]{2,}\](?!\()")


def template_names() -> dict[str, Path]:
    out = {}
    for p in SKILLS.glob("*/templates/**/*"):
        if p.is_file():
            name = p.name
            if name.endswith(".hub.md"):                      # SPEC.hub.md → SPEC.md
                name = name[: -len(".hub.md")] + ".md"
            out.setdefault(name, p)
    return out


def tpl(skill: str, name: str) -> str:
    return (SKILLS / skill / "templates" / name).read_text(encoding="utf-8")


def fill(text: str, choices: dict[str, str] | None = None) -> str:
    """Заполнить шаблон как участник: выбрать варианты, затем остальные [..] — значением."""
    for a, b in (choices or {}).items():
        text = text.replace(a, b)
    text = re.sub(r"(\*\*Коммит\*\*:\s*)\[[^\]]+\]", r"\g<1>a1b2c3d", text)
    return PH.sub(FILL, text)


SECURITY_YES = {"[да / нет]": "да"}
REVIEW_OK = {"[N — открытых блокирующих; 0 — можно выкладывать]": "0",
             "[можно выкладывать / нельзя]": "можно выкладывать"}


def git(repo: Path, *args):
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_AUTHOR_DATE": "2026-11-19T10:00:00Z",
           "GIT_COMMITTER_DATE": "2026-11-19T10:00:00Z", "PATH": "/usr/bin:/bin:/usr/local/bin"}
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=env)


def write_repo(path: Path, files: dict[str, str]) -> None:
    path.mkdir(parents=True)
    for rel, content in files.items():
        f = path / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(content, encoding="utf-8")
    git(path, "init", "-q", "-b", "main")
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "из шаблонов")


def service_json() -> str:
    t = tpl("airl-spec", "airl.service.json")
    for a, b in {"[id отдела]": "sales", "[Название сервиса]": "Продажи",
                 "[версия карты, например 1.0]": "1.0", "[руководитель отдела]": "РОП",
                 "core.[таблица](колонка, колонка)": "core.deals(deal_id, amount)",
                 "metrics.m_[id показателя]": "metrics.m_revenue",
                 "[id показателя 1]": "revenue", "[id показателя 2]": "revenue",
                 "[поле с персональными данными]": "client_phone"}.items():
        t = t.replace(a, b)
    d = json.loads(t)
    d["hub"]["metrics"] = ["revenue"]
    return json.dumps(d, ensure_ascii=False, indent=2)


def common_files(spec_tpl: str, arch_tpl: str) -> dict[str, str]:
    spec = fill(tpl("airl-spec", spec_tpl), {"- [ ] Demo Day": "- [x] Demo Day"})
    return {
        "CLAUDE.md": fill(tpl("airl-context", "CLAUDE.md")),
        "SPEC.md": spec,
        "ARCHITECTURE.md": fill(tpl("airl-spec", arch_tpl)),
        "DWH.md": fill(tpl("airl-dwh", "DWH.md")),
        "migrations/001_init.sql": "CREATE TABLE deals (id bigint PRIMARY KEY);\n",
        "public/manifest.webmanifest": "{}",
        "public/sw.js": tpl("airl-pwa", "sw.js"),
        "src/server.js": "app.get('/healthz', h);\napp.get('/sales/api/hub/summary', s);\n",
        "SECURITY.md": fill(tpl("airl-cybersecurity", "SECURITY.md"), SECURITY_YES),
        "REVIEW.md": fill(tpl("airl-code-review", "REVIEW.md"), REVIEW_OK),
        "DEVOPS.md": fill(tpl("airl-devops", "DEVOPS.md")),
        "Dockerfile": tpl("airl-devops", "Dockerfile"),
        "docker-compose.yml": tpl("airl-devops", "docker-compose.yml"),
        ".env.example": tpl("airl-devops", ".env.example"),
        ".github/workflows/ci-cd.yml": tpl("airl-devops", "ci-cd.yml"),
    }


class TemplatesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="airl_tpl_"))
        base = cls.tmp / "repos"
        base.mkdir()
        write_repo(base / "solo-tpl", common_files("SPEC.md", "ARCHITECTURE.md"))
        hub = common_files("SPEC.hub.md", "ARCHITECTURE.hub.md")
        hub.update({
            "airl.service.json": service_json(),
            "airl/COMPANY_MAP.md": tpl("airl-spec", "COMPANY_MAP.md"),
            "HUB_CHECK.md": fill(tpl("airl-hub", "HUB_CHECK.md"),
                                 {"[готов к приёмке / подключён / не подключён / degraded до ГГГГ-ММ-ДД]": "подключён"}),
        })
        write_repo(base / "hub-tpl", hub)
        cmap = tpl("airl-spec", "COMPANY_MAP.md")
        cmap = cmap.replace("| Публичные ключи (JWKS) | [адрес] |", "| Публичные ключи (JWKS) | https://auth.hub.example.kz/jwks |")
        cmap = re.sub(r"(\| Тестовое хранилище[^|]*\|)[^\n]*", r"\1 строку выдаёт инженер AIRL, кладётся в .env |", cmap)
        write_repo(base / "airl-tpl", {
            "SCOPE.md": fill(tpl("airl-spec", "SCOPE.md")).replace("**Утвердил**: " + FILL + ", " + FILL,
                                                                   "**Утвердил**: А. Директор, 2026-10-20"),
            "COMPANY_MAP.md": cmap,
            "DWH.md": fill(tpl("airl-dwh", "DWH.md")),
            "DEVOPS.md": fill(tpl("airl-devops", "DEVOPS.md")),
            "hub/services.json": '{"services": []}',
        })
        roster = cls.tmp / "roster.csv"
        with roster.open("w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(["name", "company", "department", "mode", "repo", "branch", "live_url", "cohort", "path"])
            w.writerow(["Свой продукт", "Тест", "продажи", "solo", "solo-tpl", "main", "", "Т", ""])
            w.writerow(["Сервис отдела", "Тест", "продажи", "hub", "hub-tpl", "main", "", "Т", ""])
            w.writerow(["Хаб команды AIRL", "Тест", "команда AIRL", "airl", "airl-tpl", "main", "", "Т", ""])
        data = cls.tmp / "data" / "p.jsonl"
        r = subprocess.run([sys.executable, str(SKILLS / "airl-progress" / "scripts" / "progress.py"), "check",
                            "--roster", str(roster), "--local", str(base), "--data", str(data),
                            "--out", str(cls.tmp / "report"), "--now", NOW, "--no-live"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr)
        cls.snap = json.loads(data.read_text(encoding="utf-8").splitlines()[-1])
        cls.by = {p["name"]: p for p in cls.snap["participants"]}
        cls.base = base

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    # (a) ---------------------------------------------------------------------
    def test_a_every_document_has_template(self):
        names = template_names()
        mentioned = set()
        for sk in SKILLS.glob("*/SKILL.md"):
            mentioned |= set(DOC_RE.findall(sk.read_text(encoding="utf-8")))
        self.assertTrue(mentioned, "регулярное выражение ничего не нашло")
        missing = []
        for doc in sorted(mentioned | REQUIRED):
            if doc in names:
                continue
            if doc in ELSEWHERE and (SKILLS / ELSEWHERE[doc]).is_file():
                continue
            missing.append(doc)
        self.assertEqual(missing, [], f"нет шаблона: {missing}")

    def test_a_skill_points_to_its_templates(self):
        for tdir in SKILLS.glob("*/templates"):
            text = (tdir.parent / "SKILL.md").read_text(encoding="utf-8")
            text += "".join(p.read_text(encoding="utf-8") for p in (tdir.parent / "references").glob("*.md")) \
                if (tdir.parent / "references").is_dir() else ""
            for f in tdir.rglob("*"):
                if f.is_file() and "__pycache__" not in f.parts:
                    rel = f.relative_to(tdir).as_posix()
                    top = rel.split("/")[0] + "/" if "/" in rel else rel
                    self.assertTrue(f.name in text or rel in text or top in text,
                                    f"{tdir.parent.name}: SKILL.md и справочники не ссылаются на templates/{rel}")

    def test_a_document_templates_have_fill_hints(self):
        for p in SKILLS.glob("*/templates/*.md"):
            t = p.read_text(encoding="utf-8")
            self.assertIn("<!--", t, f"{p}: нет комментария «как заполнить»")
            self.assertRegex(t, r"\[[^\]]{2,}\]", f"{p}: нет заготовок [..]")

    # (b) ---------------------------------------------------------------------
    def test_b_solo_reaches_end(self):
        r = self.by["Свой продукт"]
        missing = {k: v for k, v in r["items"].items() if v is not None and v < 1.0 and k != "live"}
        self.assertEqual(missing, {}, "пункты не засчитаны")
        self.assertEqual(r["stage"], "finished")

    def test_b_hub_service_reaches_end(self):
        r = self.by["Сервис отдела"]
        missing = {k: v for k, v in r["items"].items() if v is not None and v < 1.0 and k != "live"}
        self.assertEqual(missing, {}, "пункты не засчитаны")
        self.assertEqual(r["stage"], "finished")

    def test_b_airl_team_separate(self):
        self.assertNotIn("Хаб команды AIRL", self.by)          # в средние потока не входит
        team = {t["name"]: t for t in self.snap["airl_team"]}
        self.assertEqual(team["Хаб команды AIRL"]["percent"], 100.0, team["Хаб команды AIRL"])
        md = (self.tmp / "report" / "summary.md").read_text(encoding="utf-8")
        self.assertIn("Команда AIRL: готовность хаба", md)

    def test_b_unfilled_templates_do_not_count(self):
        self.assertEqual(progress.check_review(tpl("airl-code-review", "REVIEW.md")), 0.3)
        self.assertEqual(progress.check_security_verdict(tpl("airl-cybersecurity", "SECURITY.md")), 0.0)
        self.assertEqual(progress.check_hub_decision(tpl("airl-hub", "HUB_CHECK.md")), 0.0)
        spec = tpl("airl-spec", "SPEC.md")
        self.assertEqual(progress.check_spec_pain(spec), 0.0)
        self.assertEqual(progress.check_spec_criteria(spec), 0.0)

    # (c) ---------------------------------------------------------------------
    def test_c_verdicts_agree(self):
        sec_t = tpl("airl-cybersecurity", "SECURITY.md")
        samples = [
            fill(sec_t, SECURITY_YES),
            fill(sec_t, {"[да / нет]": "нет"}),
            sec_t,                                                    # не заполнен
            fill(sec_t).replace(FILL + ", потому что", "да / нет, потому что"),
            "# Безопасность\n\nПока открывать нельзя: ключ в репозитории\n",
            "# Безопасность\n\nПродукт можно открывать людям. До Demo Day — заголовки.\n",
        ]
        for s in samples:
            p = progress.check_security_verdict(s) == 1.0
            c = check_service.security_verdict(s) == "да"
            self.assertEqual(p, c, s[:400])
        rev_t = tpl("airl-code-review", "REVIEW.md")
        for s, ok in [(fill(rev_t, REVIEW_OK), True),
                      (fill(rev_t, {**REVIEW_OK, "[N — открытых блокирующих; 0 — можно выкладывать]": "2"}), False),
                      (rev_t, False),
                      (fill(rev_t, REVIEW_OK).replace("a1b2c3d", "[хеш]"), False)]:
            self.assertEqual(progress.check_review(s) == 1.0, ok)
            self.assertEqual(check_service.review_blocking(s) == 0, ok)

    def test_c_check_service_on_filled_hub_repo(self):
        repo = self.base / "hub-tpl"
        cmd = [sys.executable, str(SKILLS / "airl-hub" / "scripts" / "check_service.py"),
               "--service", str(repo / "airl.service.json"), "--map", str(repo / "airl" / "COMPANY_MAP.md"),
               "--files-only"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("6 Безопасность", r.stdout)
        self.assertIn("7 Код-ревью", r.stdout)
        bad = self.tmp / "bad_review.md"
        bad.write_text(tpl("airl-code-review", "REVIEW.md"), encoding="utf-8")
        r = subprocess.run(cmd + ["--review", str(bad)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout)

    # (d) ---------------------------------------------------------------------
    def test_d_methodology_in_sync(self):
        diff, extra = sync_templates.differences()
        self.assertEqual([str(p) for p in diff + extra], [],
                         "methodology/templates устарел: python3 scripts/sync_templates.py")


if __name__ == "__main__":
    res = unittest.main(argv=sys.argv[:1] + ["-v"] if "-v" in sys.argv else sys.argv[:1], exit=False).result
    sys.exit(0 if res.wasSuccessful() else 1)
