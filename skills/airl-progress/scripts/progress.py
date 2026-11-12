#!/usr/bin/env python3
"""Прогресс участников курса VibeOps по их репозиториям на GitHub.

Смотрит в репозиторий каждого участника (только чтение), отмечает пункты
чек-листа курса (SPEC.md, DWH.md, SECURITY.md, REVIEW.md и т. д.), считает
процент и этап, сигналы активности (коммиты, ветки, PR) и флаги «отстаёт»,
«застрял N дней», «впереди». Добавляет снимок в data/progress.jsonl и рисует
report/index.html (графики), report/summary.md и текст для Telegram.

Команды:
  python3 progress.py check  --roster roster.csv [--weights weights.yml]
                             [--local DIR] [--data data/progress.jsonl]
                             [--out report] [--no-live] [--telegram-text]
  python3 progress.py report --data data/progress.jsonl [--out report] [--telegram-text]
  python3 progress.py laggards --data data/progress.jsonl   # кто отстаёт и что делать

Доступ к GitHub: переменная GITHUB_TOKEN (fine-grained, только чтение
Contents и Metadata). Нет токена — `gh api` (если gh вошёл), иначе без
токена (только публичные репозитории, 60 запросов в час).
GITHUB_API_URL меняет адрес API (GitHub Enterprise или тесты).

Что НЕ делает: не клонирует код, не пишет в репозитории участников, не
печатает и не сохраняет токен, не хранит содержимое файлов — только итоги
проверок (число от 0 до 1 на пункт) и метаданные активности.

Только стандартная библиотека Python 3.9+. PyYAML используется, если стоит.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "1.0"
UA = "airl-progress/" + VERSION

# ---------------------------------------------------------------------------
# Модель курса: этапы и пункты чек-листа
# ---------------------------------------------------------------------------

STAGES = [
    ("start", "Старт"),
    ("plan", "План"),
    ("data", "Данные"),
    ("security", "Защита"),
    ("launch", "Запуск"),
    ("demo", "Demo Day"),
]
STAGE_LABEL = dict(STAGES)
STAGE_ORDER = [s for s, _ in STAGES]

# id, этап, подпись, режим (both | solo | hub | live), навык-подсказка, что сделать
ITEMS = [
    ("repo", "start", "Репозиторий", "both", "/airl-spec", "создать репозиторий на GitHub и дать доступ на чтение"),
    ("claude_md", "start", "CLAUDE.md", "both", "/airl-context", "завести память проекта: /airl-context начать проект"),
    ("spec", "plan", "SPEC.md", "both", "/airl-spec", "написать ТЗ продукта"),
    ("spec_pain", "plan", "Боль в цифрах", "both", "/airl-spec", "в SPEC.md, раздел 1, указать цену боли числом"),
    ("spec_metric", "plan", "Метрика было→стало", "both", "/airl-spec", "в SPEC.md записать метрику успеха «было X → стало Y»"),
    ("spec_criteria", "plan", "Критерии готовности", "both", "/airl-spec", "в SPEC.md, раздел 10, записать 3+ проверяемых критерия"),
    ("arch_context", "plan", "ARCHITECTURE.md", "both", "/airl-spec", "схема архитектуры с блоком airl-context"),
    ("service_json", "plan", "airl.service.json", "hub", "/airl-spec", "контракт сервиса для хаба (режим B)"),
    ("company_map", "plan", "Карта компании", "hub", "/airl-spec", "положить копию карты в airl/COMPANY_MAP.md"),
    ("dwh", "data", "DWH.md", "both", "/airl-dwh", "спроектировать базу и записать DWH.md"),
    ("migrations", "data", "Миграции", "both", "/airl-dwh", "миграции базы в репозитории"),
    ("module", "data", "Модуль / система", "both", "/airl-modules", "поставить готовый модуль (/airl-modules) или подключить систему (/airl-connect)"),
    ("pwa_manifest", "data", "PWA: манифест", "both", "/airl-pwa", "манифест приложения для установки на телефон"),
    ("pwa_sw", "data", "PWA: service worker", "both", "/airl-pwa", "service worker и работа без сети"),
    ("healthz", "data", "/healthz", "both", "/airl-pwa", "служебный адрес /healthz"),
    ("hub_summary", "data", "/api/hub/summary", "hub", "/airl-pwa", "адрес /api/hub/summary для хаба"),
    ("security_md", "security", "SECURITY.md", "both", "/airl-cybersecurity", "пройти проверку безопасности"),
    ("security_ok", "security", "Вердикт «можно открывать»", "both", "/airl-cybersecurity", "закрыть СРОЧНЫЕ находки и перепроверить"),
    ("docker", "launch", "Docker", "both", "/airl-devops", "Dockerfile или docker-compose"),
    ("ci", "launch", "Автовыкладка (CI)", "both", "/airl-devops", "workflow в .github/workflows"),
    ("devops_md", "launch", "DEVOPS.md", "both", "/airl-devops", "памятка по серверу и выкладке"),
    ("review_ok", "launch", "REVIEW.md без блокирующих", "both", "/airl-code-review", "код-ревью: 0 блокирующих замечаний"),
    ("live", "launch", "Живой /healthz", "live", "/airl-devops", "адрес продукта отвечает 200 на /healthz"),
    ("demo", "demo", "Готов к Demo Day", "both", "/airl-hub", "solo: отметить Demo Day в SPEC.md, раздел 12; хаб: приёмка /airl-hub"),
]
ITEM_BY_ID = {i[0]: i for i in ITEMS}

MODULE_IDS = [
    "appointments", "approvals", "bank-reconciliation", "churn-risk", "complaints",
    "deliveries", "demand-forecast", "inspection-journal", "leads", "onboarding",
    "picking", "plan-fact", "pnl-cashflow", "purchasing", "receivables",
    "service-requests", "stock-levels",
]

DEFAULT_CONFIG = {
    "stages": {"start": 5, "plan": 20, "data": 25, "security": 15, "launch": 25, "demo": 10},
    "items": {i[0]: 1 for i in ITEMS},
    "thresholds": {"stage_done": 0.75, "stall_days": 4, "behind_margin": 15,
                   "ahead_margin": 10, "median_margin": 20},
    "schedule": {"start_date": "", "expected_end_of_week": [5, 25, 50, 65, 90, 100]},
}
DEFAULT_CONFIG["items"].update({"spec": 1, "spec_pain": 2, "spec_metric": 2, "spec_criteria": 2,
                                "arch_context": 2, "migrations": 2, "security_ok": 3,
                                "review_ok": 2, "live": 2, "repo": 1, "claude_md": 1})

SKIP_DIRS = {".git", "node_modules", "dist", "build", ".next", "vendor", "__pycache__",
             ".venv", "venv", "coverage", ".cache", "target", "out"}
SRC_EXT = {".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".go", ".rb", ".php",
           ".java", ".kt", ".cs", ".rs", ".vue", ".svelte"}
MAX_TEXT = 256 * 1024
MAX_SRC = 64 * 1024
MAX_SRC_FILES = 25


# ---------------------------------------------------------------------------
# Мини-YAML (подмножество): словари с отступами, списки словарей, [a, b]
# ---------------------------------------------------------------------------

def _scalar(v: str):
    v = v.strip()
    if v == "" or v in ("~", "null"):
        return None
    if (v[0] == v[-1]) and v[0] in "\"'" and len(v) >= 2:
        return v[1:-1]
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        return [_scalar(x) for x in inner.split(",")] if inner else []
    low = v.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        return v


def _strip_comment(line: str) -> str:
    out, q = [], None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def mini_yaml(text: str):
    lines = []
    for raw in text.splitlines():
        s = _strip_comment(raw)
        if s.strip():
            lines.append((len(s) - len(s.lstrip(" ")), s.strip()))
    pos = 0

    def block(indent):
        nonlocal pos
        if pos >= len(lines):
            return None
        if lines[pos][1].startswith("- ") or lines[pos][1] == "-":
            res = []
            while pos < len(lines) and lines[pos][0] == indent and lines[pos][1].startswith("-"):
                item = lines[pos][1][1:].strip()
                if not item:
                    pos += 1
                    res.append(block(lines[pos][0]) if pos < len(lines) and lines[pos][0] > indent else None)
                    continue
                if re.match(r"^[^\s\"'][^:]*:(\s|$)", item):
                    # словарь: первая пара на строке с «-»
                    lines[pos] = (indent + 2, item)
                    res.append(block(indent + 2))
                else:
                    res.append(_scalar(item))
                    pos += 1
            return res
        res = {}
        while pos < len(lines) and lines[pos][0] == indent and not lines[pos][1].startswith("- "):
            key, _, val = lines[pos][1].partition(":")
            key = key.strip().strip("\"'")
            pos += 1
            if val.strip():
                res[key] = _scalar(val)
            elif pos < len(lines) and lines[pos][0] > indent:
                res[key] = block(lines[pos][0])
            elif pos < len(lines) and lines[pos][0] == indent and lines[pos][1].startswith("- "):
                res[key] = block(indent)
            else:
                res[key] = None
        return res

    return block(lines[0][0]) if lines else {}


def load_yaml(path: Path):
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text)
    except ImportError:
        return mini_yaml(text)


def load_config(path: str | None) -> dict:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if not path:
        return cfg
    p = Path(path)
    data = json.loads(p.read_text(encoding="utf-8")) if p.suffix == ".json" else load_yaml(p)
    for sect in ("stages", "items", "thresholds", "schedule"):
        if isinstance((data or {}).get(sect), dict):
            cfg[sect].update(data[sect])
    return cfg


# ---------------------------------------------------------------------------
# Список участников
# ---------------------------------------------------------------------------

def parse_repo(value: str) -> tuple[str, str]:
    v = (value or "").strip()
    v = re.sub(r"^https?://[^/]+/", "", v)
    v = re.sub(r"^git@[^:]+:", "", v)
    v = v.removesuffix(".git").strip("/")
    parts = v.split("/")
    if len(parts) < 2 or not parts[0] or not parts[1]:
        raise ValueError(f"не понял адрес репозитория: {value!r} (нужно owner/name или ссылка)")
    return parts[0], parts[1]


def load_roster(path: str) -> list[dict]:
    p = Path(path)
    if p.suffix in (".yml", ".yaml"):
        data = load_yaml(p) or {}
        rows = data.get("participants", data) if isinstance(data, dict) else data
    else:
        with p.open(encoding="utf-8-sig", newline="") as f:
            rows = [r for r in csv.DictReader(f)]
    out, seen = [], set()
    for r in rows or []:
        r = {k.strip(): ("" if v is None else str(v).strip()) for k, v in r.items() if k}
        if not r.get("repo") or r.get("name", "").startswith("#"):
            continue
        owner, name = parse_repo(r["repo"])
        pid = f"{owner}/{name}"
        if pid in seen:
            continue
        seen.add(pid)
        mode = (r.get("mode") or "solo").lower()
        out.append({
            "id": pid, "owner": owner, "repo": name,
            "name": r.get("name") or pid, "company": r.get("company", ""),
            "department": r.get("department", ""),
            "mode": "hub" if mode == "hub" else "solo",
            "branch": r.get("branch", ""), "live_url": r.get("live_url", ""),
            "cohort": r.get("cohort", ""),
        })
    return out


# ---------------------------------------------------------------------------
# Источники: локальная папка и GitHub API
# ---------------------------------------------------------------------------

class LocalRepo:
    """Репозиторий в локальной папке (клон). Для тестов и работы без сети."""

    def __init__(self, path: Path, branch: str, now: dt.datetime):
        self.path, self.branch, self.now = path, branch, now

    def files(self) -> dict[str, dict]:
        res = {}
        for root, dirs, fnames in os.walk(self.path):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for fn in fnames:
                full = Path(root) / fn
                rel = full.relative_to(self.path).as_posix()
                try:
                    size = full.stat().st_size
                except OSError:
                    continue
                res[rel] = {"size": size, "sha": None}
        return res

    def read(self, path: str, limit: int = MAX_TEXT) -> str | None:
        full = self.path / path
        try:
            if full.stat().st_size > limit:
                return None
            return full.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return None

    def _git(self, *args) -> str:
        r = subprocess.run(["git", "-C", str(self.path), *args], capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else ""

    def activity(self) -> dict:
        if not (self.path / ".git").exists():
            return {"last_commit": None, "commits_7d": None, "branches": None, "open_prs": None}
        ref = self.branch or "HEAD"
        last = self._git("log", "-1", "--format=%cI", ref)
        since = (self.now - dt.timedelta(days=7)).isoformat()
        until = self.now.isoformat()
        cnt = self._git("rev-list", "--count", f"--since={since}", f"--until={until}", ref)
        br = self._git("branch", "--list", "--format=%(refname:short)")
        return {"last_commit": last or None, "commits_7d": int(cnt or 0),
                "branches": len([b for b in br.splitlines() if b.strip()]) or None,
                "open_prs": None}


class ApiError(Exception):
    pass


class GitHub:
    """Только чтение через REST API. ETag для дерева, итоги проверок — по SHA файла."""

    def __init__(self, cache: dict, log=print):
        self.base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        self.token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
        self.use_gh = False
        if not self.token and shutil.which("gh") and "GITHUB_API_URL" not in os.environ:
            ok = subprocess.run(["gh", "auth", "status"], capture_output=True).returncode == 0
            self.use_gh = ok
        self.cache = cache
        self.log = log
        self.calls = 0
        self.remaining = None

    def mode(self) -> str:
        return "token" if self.token else ("gh" if self.use_gh else "anonymous")

    def _req(self, path: str, accept="application/vnd.github+json", etag=None):
        """Возвращает (status, body_bytes, headers). 304 — тело пустое."""
        self.calls += 1
        if self.remaining is not None and self.remaining < 5:
            raise ApiError("лимит запросов GitHub почти исчерпан — остановились, повторите позже")
        if self.use_gh:
            cmd = ["gh", "api", "-i", "-H", f"Accept: {accept}", path.lstrip("/")]
            if etag:
                cmd[3:3] = ["-H", f"If-None-Match: {etag}"]
            r = subprocess.run(cmd, capture_output=True)
            raw = r.stdout
            head, _, body = raw.partition(b"\r\n\r\n")
            if not body and b"\n\n" in raw:
                head, _, body = raw.partition(b"\n\n")
            lines = head.decode("utf-8", "replace").splitlines()
            m = re.match(r"HTTP/\S+\s+(\d+)", lines[0] if lines else "")
            status = int(m.group(1)) if m else (200 if r.returncode == 0 else 500)
            hdrs = {}
            for ln in lines[1:]:
                k, _, v = ln.partition(":")
                hdrs[k.strip().lower()] = v.strip()
            self._rate(hdrs)
            return status, body, hdrs
        url = self.base + path
        req = urllib.request.Request(url, headers={"Accept": accept, "User-Agent": UA,
                                                   "X-GitHub-Api-Version": "2022-11-28"})
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        if etag:
            req.add_header("If-None-Match", etag)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    hdrs = {k.lower(): v for k, v in resp.headers.items()}
                    self._rate(hdrs)
                    return resp.status, resp.read(), hdrs
            except urllib.error.HTTPError as e:
                hdrs = {k.lower(): v for k, v in (e.headers or {}).items()}
                self._rate(hdrs)
                if e.code == 304:
                    return 304, b"", hdrs
                if e.code in (403, 429) and attempt < 2 and (
                        hdrs.get("retry-after") or hdrs.get("x-ratelimit-remaining") == "0"):
                    wait = int(hdrs.get("retry-after") or 0)
                    if not wait and hdrs.get("x-ratelimit-reset"):
                        wait = int(hdrs["x-ratelimit-reset"]) - int(time.time())
                    if 0 < wait <= 90:
                        time.sleep(wait)
                        continue
                    raise ApiError("лимит запросов GitHub исчерпан — повторите позже")
                return e.code, b"", hdrs
            except urllib.error.URLError as e:
                if attempt < 2:
                    time.sleep(2 * (attempt + 1))
                    continue
                raise ApiError(f"GitHub недоступен: {e.reason}")
        raise ApiError("GitHub не ответил")

    def _rate(self, hdrs):
        if "x-ratelimit-remaining" in hdrs:
            try:
                self.remaining = int(hdrs["x-ratelimit-remaining"])
            except ValueError:
                pass

    def json(self, path: str):
        status, body, _ = self._req(path)
        if status == 404:
            return None
        if status >= 400:
            raise ApiError(f"GitHub ответил {status} на {path.split('?')[0]}")
        return json.loads(body or b"null")


class GitHubRepo:
    def __init__(self, gh: GitHub, owner: str, name: str, branch: str, now: dt.datetime):
        self.gh, self.owner, self.name, self.now = gh, owner, name, now
        self.p = f"/repos/{urllib.parse.quote(owner)}/{urllib.parse.quote(name)}"
        meta = gh.json(self.p)
        if meta is None:
            raise ApiError("репозиторий не найден или нет доступа на чтение")
        self.branch = branch or meta.get("default_branch") or "main"
        b = gh.json(f"{self.p}/branches/{urllib.parse.quote(self.branch, safe='')}")
        if b is None:
            raise ApiError(f"ветка {self.branch} не найдена")
        self.head_sha = b["commit"]["sha"]
        c = b["commit"].get("commit", {})
        self.last_commit = (c.get("committer") or c.get("author") or {}).get("date")
        self._files = None
        self.rc = gh.cache.setdefault("repos", {}).setdefault(f"{owner}/{name}", {})

    def files(self) -> dict[str, dict]:
        if self._files is not None:
            return self._files
        tree_cache = self.rc.get("tree") or {}
        etag = tree_cache.get("etag") if tree_cache.get("head") == self.head_sha else None
        status, body, hdrs = self.gh._req(f"{self.p}/git/trees/{self.head_sha}?recursive=1", etag=etag)
        if status == 304 and tree_cache.get("files"):
            files = tree_cache["files"]
        elif status == 200:
            data = json.loads(body)
            files = {}
            for e in data.get("tree", []):
                if e.get("type") != "blob":
                    continue
                parts = e["path"].split("/")
                if any(x in SKIP_DIRS for x in parts[:-1]):
                    continue
                files[e["path"]] = {"size": e.get("size", 0), "sha": e.get("sha")}
            self.rc["tree"] = {"head": self.head_sha, "etag": hdrs.get("etag"), "files": files}
        else:
            raise ApiError(f"не удалось прочитать список файлов (код {status})")
        self._files = files
        return files

    def read(self, path: str, limit: int = MAX_TEXT) -> str | None:
        f = self.files().get(path)
        if not f or f["size"] > limit:
            return None
        status, body, _ = self.gh._req(f"{self.p}/git/blobs/{f['sha']}", accept="application/vnd.github.raw")
        if status != 200:
            return None
        return body.decode("utf-8", "replace")

    def activity(self) -> dict:
        since = (self.now - dt.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
        q = urllib.parse.quote(self.branch, safe="")
        commits = self.gh.json(f"{self.p}/commits?sha={q}&since={since}&per_page=100") or []
        branches = self.gh.json(f"{self.p}/branches?per_page=100") or []
        pulls = self.gh.json(f"{self.p}/pulls?state=open&per_page=100") or []
        return {"last_commit": self.last_commit, "commits_7d": len(commits),
                "branches": len(branches), "open_prs": len(pulls)}


# ---------------------------------------------------------------------------
# Проверки содержимого
# ---------------------------------------------------------------------------

PLACEHOLDER = re.compile(r"\[[^\]]{2,}\]")


def _filled(line: str) -> bool:
    s = re.sub(r"\[[ xX]\]", "", line)              # чекбоксы
    s = re.sub(r"\[[^\]]*\]\([^)]*\)", "", s)        # ссылки
    return not PLACEHOLDER.search(s) and "..." not in s and "…" not in s


def section(text: str, num: str) -> str:
    m = re.search(rf"^##\s*{re.escape(num)}\.?\s.*$", text, re.M)
    if not m:
        return ""
    rest = text[m.end():]
    n = re.search(r"^##\s", rest, re.M)
    return rest[: n.start()] if n else rest


def check_spec_pain(spec: str) -> float:
    sec = section(spec, "1")
    for ln in sec.splitlines():
        if re.search(r"цена боли", ln, re.I) and _filled(ln) and re.search(r"\d", ln):
            return 1.0
    body = [ln for ln in sec.splitlines() if ln.strip() and _filled(ln)]
    return 0.5 if len(" ".join(body)) > 60 else 0.0


def check_spec_metric(spec: str) -> float:
    for ln in spec.splitlines():
        if re.search(r"метрика успеха", ln, re.I):
            if _filled(ln) and re.search(r"\d", ln):
                return 1.0
            if _filled(ln) and len(ln) > 40:
                return 0.5
    return 0.0


def check_spec_criteria(spec: str) -> float:
    sec = section(spec, "10")
    n = sum(1 for ln in sec.splitlines()
            if re.match(r"\s*-\s*\[[ xX]\]\s*\S", ln) and _filled(ln) and len(ln.strip()) > 12)
    return 1.0 if n >= 3 else (0.5 if n >= 1 else 0.0)


def check_security_verdict(text: str) -> float:
    for ln in text.splitlines():
        low = ln.lower()
        if "открывать нельзя" in low or "пока открывать нельзя" in low:
            return 0.0
        if "можно открывать" in low or "подключать к хабу" in low:
            if not _filled(ln):
                continue
            m = re.search(r":\s*(да|нет)\b", low.replace("*", ""))
            if m:
                return 1.0 if m.group(1) == "да" else 0.0
            if low.strip().startswith("продукт можно открывать"):
                return 1.0
    return 0.0


def check_review(text: str) -> float:
    m = re.search(r"Блокирующих замечаний\**\s*:\s*\**\s*(\d+)", text)
    if not m:
        return 0.3
    return 1.0 if int(m.group(1)) == 0 else 0.3


def check_hub_decision(text: str) -> float:
    m = re.search(r"Решение\**\s*:\s*\**\s*([^\n]+)", text)
    if not m:
        return 0.0
    v = m.group(1).lower()
    if "не подключ" in v:
        return 0.25
    if "подключ" in v:
        return 1.0
    if "degraded" in v:
        return 0.75
    if "готов к приёмке" in v or "готов к приемке" in v:
        return 0.5
    return 0.0


def http_ok(url: str, timeout: int = 10) -> bool:
    if not url:
        return False
    u = url.rstrip("/")
    if not u.endswith("healthz"):
        u += "/healthz"
    if not re.match(r"^https?://", u):
        u = "https://" + u
    try:
        req = urllib.request.Request(u, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def _find(files: dict, *names) -> str | None:
    """Первый путь, совпадающий с именем: сначала в корне, затем где угодно."""
    for n in names:
        if n in files:
            return n
    low = {k.lower(): k for k in files}
    for n in names:
        if n.lower() in low:
            return low[n.lower()]
    for n in names:
        for k in files:
            if k.lower().endswith("/" + n.lower()) and k.count("/") <= 2:
                return k
    return None


def evaluate(src, part: dict, cache_repo: dict, live: bool) -> dict:
    """Итог по каждому пункту: число 0..1 или None (пункт не относится к участнику)."""
    files = src.files()
    hub = part["mode"] == "hub"
    rc_checks = cache_repo.setdefault("checks", {})

    def text(path):
        return src.read(path) if path else None

    def cached(path, fn):
        """Итог проверки файла по его SHA: файл не менялся — не скачиваем снова."""
        if not path:
            return 0.0
        sha = files[path].get("sha")
        key = f"{fn.__name__}:{path}"
        if sha and rc_checks.get(key, {}).get("sha") == sha:
            return rc_checks[key]["v"]
        t = text(path)
        v = fn(t) if t is not None else 0.0
        if sha:
            rc_checks[key] = {"sha": sha, "v": v}
        return v

    r: dict[str, float | None] = {}
    r["repo"] = 1.0
    cm = _find(files, "CLAUDE.md")
    r["claude_md"] = 0.0 if not cm else (1.0 if files[cm]["size"] >= 200 else 0.5)

    spec = _find(files, "SPEC.md")
    r["spec"] = 1.0 if spec else 0.0
    if spec:
        r["spec_pain"] = cached(spec, check_spec_pain)
        r["spec_metric"] = cached(spec, check_spec_metric)
        r["spec_criteria"] = cached(spec, check_spec_criteria)
    else:
        r["spec_pain"] = r["spec_metric"] = r["spec_criteria"] = 0.0

    arch = _find(files, "ARCHITECTURE.md")

    def _ctx(t):
        return 1.0 if re.search(r"#\s*airl-context", t) and re.search(r"^\s*mode:\s*\w", t, re.M) else 0.5
    r["arch_context"] = cached(arch, _ctx) if arch else 0.0

    if hub:
        sj = _find(files, "airl.service.json")

        def _svc(t):
            try:
                d = json.loads(t)
            except ValueError:
                return 0.3
            ok = d.get("id") and (d.get("hub") or {}).get("health") and (d.get("data") or {}).get("writes") is not None
            return 1.0 if ok else 0.5
        r["service_json"] = cached(sj, _svc) if sj else 0.0
        r["company_map"] = 1.0 if ("airl/COMPANY_MAP.md" in files or "COMPANY_MAP.md" in files) else 0.0
    else:
        r["service_json"] = r["company_map"] = None

    dwh = _find(files, "DWH.md")
    r["dwh"] = 0.0 if not dwh else (1.0 if files[dwh]["size"] >= 300 else 0.5)

    mig_re = re.compile(r"(^|/)(migrations?|db|sql|schema|supabase|prisma|alembic)(/|$)", re.I)
    has_mig = any((p.endswith(".sql") or p.endswith("schema.prisma") or
                   (mig_re.search(p) and Path(p).suffix in {".sql", ".py", ".ts", ".js"}))
                  for p in files)
    r["migrations"] = 1.0 if has_mig else 0.0

    mod = any(p.endswith(".sql") and (re.search(r"(^|[_\-.])kit([_\-.]|$)", Path(p).stem) or
                                      any(m in p for m in MODULE_IDS)) for p in files)
    mod = mod or bool(_find(files, "CONNECT.md"))
    if not mod and spec:
        def _mods(t):
            return 1.0 if re.search(r"^#+\s.*Модул", t, re.M) else 0.0
        mod = cached(spec, _mods) == 1.0
    r["module"] = 1.0 if mod else 0.0

    pkg = _find(files, "package.json")

    def _pwa_plugin(t):
        return 1.0 if re.search(r"vite-plugin-pwa|@vite-pwa|next-pwa|workbox", t) else 0.0
    pwa_plugin = bool(pkg and "/" not in pkg and cached(pkg, _pwa_plugin) == 1.0)
    has_manifest = any(p.endswith(".webmanifest") or re.search(r"(^|/)(public|static|app|src|web)/(.*/)?manifest\.json$", p)
                       for p in files)
    r["pwa_manifest"] = 1.0 if (has_manifest or pwa_plugin) else 0.0
    sw_names = {"sw.js", "sw.ts", "service-worker.js", "service-worker.ts", "serviceworker.js", "ngsw-config.json"}
    r["pwa_sw"] = 1.0 if (pwa_plugin or any(Path(p).name.lower() in sw_names for p in files)) else 0.0

    # Служебные адреса: ищем строку в небольшом наборе исходников
    cands = [p for p, f in files.items()
             if Path(p).suffix in SRC_EXT and f["size"] <= MAX_SRC and
             not re.search(r"(^|/)(tests?|__tests__|spec|e2e)/|\.(test|spec)\.", p)]
    prio = re.compile(r"health|server|api|route|app|main|index|hub", re.I)
    cands.sort(key=lambda p: (0 if prio.search(p) else 1, p.count("/"), p))
    found = {"healthz": False, "summary": False}
    for p in cands[:MAX_SRC_FILES]:
        sha = files[p].get("sha")
        key = f"src:{p}"
        if sha and rc_checks.get(key, {}).get("sha") == sha:
            hz, sm = rc_checks[key]["v"]
        else:
            t = text(p) or ""
            hz, sm = "healthz" in t, "hub/summary" in t
            if sha:
                rc_checks[key] = {"sha": sha, "v": [hz, sm]}
        found["healthz"] |= hz
        found["summary"] |= sm
        if found["healthz"] and (found["summary"] or not hub):
            break

    live_ok = None
    if part.get("live_url"):
        live_ok = http_ok(part["live_url"]) if live else None
    r["healthz"] = 1.0 if (found["healthz"] or live_ok) else 0.0
    r["hub_summary"] = (1.0 if found["summary"] else 0.0) if hub else None

    sec = _find(files, "SECURITY.md")
    r["security_md"] = 1.0 if sec else 0.0
    r["security_ok"] = cached(sec, check_security_verdict) if sec else 0.0

    docker = any(Path(p).name.lower() in {"dockerfile", "docker-compose.yml", "docker-compose.yaml",
                                          "compose.yml", "compose.yaml"} for p in files)
    r["docker"] = 1.0 if docker else 0.0
    r["ci"] = 1.0 if any(re.match(r"\.github/workflows/[^/]+\.ya?ml$", p) for p in files) else 0.0
    dv = _find(files, "DEVOPS.md", "DEPLOY.md")
    r["devops_md"] = 0.0 if not dv else (1.0 if files[dv]["size"] >= 300 else 0.5)
    rv = _find(files, "REVIEW.md")
    r["review_ok"] = cached(rv, check_review) if rv else 0.0
    r["live"] = (1.0 if live_ok else 0.0) if (part.get("live_url") and live) else None

    if hub:
        hc = _find(files, "HUB_CHECK.md")
        r["demo"] = cached(hc, check_hub_decision) if hc else 0.0
    else:
        def _demo(t):
            return 1.0 if re.search(r"-\s*\[[xX]\]\s*Demo Day", t) else 0.0
        r["demo"] = cached(spec, _demo) if spec else 0.0
    return r


# ---------------------------------------------------------------------------
# Процент, этап, флаги
# ---------------------------------------------------------------------------

def score(items: dict, cfg: dict) -> dict:
    sw, iw = cfg["stages"], cfg["items"]
    per_stage = {}
    for st in STAGE_ORDER:
        num = den = 0.0
        for iid, stage, *_ in ITEMS:
            if stage != st or items.get(iid) is None:
                continue
            w = float(iw.get(iid, 1))
            num += w * items[iid]
            den += w
        per_stage[st] = (num / den) if den else 0.0
    total_w = sum(float(sw.get(s, 0)) for s in STAGE_ORDER) or 1.0
    percent = sum(float(sw.get(s, 0)) * per_stage[s] for s in STAGE_ORDER) * 100.0 / total_w
    thr = float(cfg["thresholds"]["stage_done"])
    done = None
    for s in STAGE_ORDER:
        if per_stage[s] >= thr:
            done = s
        else:
            break
    idx = STAGE_ORDER.index(done) + 1 if done else 0
    current = STAGE_ORDER[idx] if idx < len(STAGE_ORDER) else "finished"
    return {"percent": round(percent, 1), "stages": {k: round(v, 3) for k, v in per_stage.items()},
            "stage_done": done, "stage": current}


def expected_percent(cfg: dict, now: dt.datetime) -> float | None:
    sch = cfg.get("schedule") or {}
    start = str(sch.get("start_date") or "").strip()
    exp = sch.get("expected_end_of_week") or []
    if not start or not exp:
        return None
    try:
        d0 = dt.datetime.fromisoformat(start).replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None
    days = (now - d0).total_seconds() / 86400.0
    # неделя 0 заканчивается в день старта; дальше — линейно по неделям
    pts = [(0.0, float(exp[0]))] + [(7.0 * i, float(v)) for i, v in enumerate(exp[1:], 1)]
    if days <= 0:
        return pts[0][1] * max(0.0, 1 + days / 7.0)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if days <= x1:
            return y0 + (y1 - y0) * (days - x0) / (x1 - x0)
    return pts[-1][1]


def parse_ts(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def flags_for(rows: list[dict], history: list[dict], cfg: dict, now: dt.datetime) -> None:
    th = cfg["thresholds"]
    exp = expected_percent(cfg, now)
    pcts = sorted(r["percent"] for r in rows if not r.get("error"))
    median = pcts[len(pcts) // 2] if pcts else 0.0
    for r in rows:
        fl = []
        if r.get("error"):
            r["flags"] = [{"kind": "error", "label": "нет доступа"}]
            continue
        act = r["activity"]
        lc = parse_ts(act.get("last_commit"))
        days_commit = int((now - lc).total_seconds() // 86400) if lc else None
        act["days_since_commit"] = days_commit
        # сколько дней процент не растёт (по прошлым снимкам)
        flat_since = now
        for snap in reversed(history):
            prev = next((p for p in snap["participants"] if p["id"] == r["id"]), None)
            if prev is None or prev.get("error") or abs(prev["percent"] - r["percent"]) > 0.05:
                break
            flat_since = parse_ts(snap["ts"]) or flat_since
        days_flat = int((now - flat_since).total_seconds() // 86400)
        r["days_flat"] = days_flat
        stall_n = 0
        if r["stage"] != "finished":
            if days_commit is not None and days_commit >= th["stall_days"]:
                stall_n = days_commit
            if days_flat >= th["stall_days"]:
                stall_n = max(stall_n, days_flat)
        if stall_n:
            fl.append({"kind": "stalled", "days": stall_n, "label": f"застрял {stall_n} дн."})
        ref = exp if exp is not None else median
        r["expected"] = round(exp, 1) if exp is not None else None
        behind_m = th["behind_margin"] if exp is not None else th["median_margin"]
        ahead_m = th["ahead_margin"] if exp is not None else th["median_margin"]
        if len(pcts) >= 2 or exp is not None:
            if r["percent"] < ref - behind_m:
                fl.append({"kind": "behind", "label": "отстаёт"})
            elif r["percent"] >= ref + ahead_m:
                fl.append({"kind": "ahead", "label": "впереди"})
        r["flags"] = fl


def next_steps(r: dict, limit: int = 2) -> list[dict]:
    """Первые невыполненные пункты по порядку курса — что делать дальше."""
    out = []
    for iid, stage, label, _mode, skill, todo in ITEMS:
        v = r["items"].get(iid)
        if v is None or v >= 1.0:
            continue
        out.append({"item": iid, "stage": stage, "label": label, "skill": skill, "todo": todo})
        if len(out) >= limit:
            break
    return out


# ---------------------------------------------------------------------------
# Сбор снимка
# ---------------------------------------------------------------------------

def load_history(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for ln in path.read_text(encoding="utf-8").splitlines():
        ln = ln.strip()
        if ln:
            try:
                out.append(json.loads(ln))
            except ValueError:
                continue
    return out


def find_local(base: Path, p: dict) -> Path | None:
    for c in (base / f"{p['owner']}__{p['repo']}", base / p["owner"] / p["repo"], base / p["repo"]):
        if c.is_dir():
            return c
    return None


def collect(args, cfg) -> dict:
    now = parse_ts(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
    roster = load_roster(args.roster)
    data_path = Path(args.data)
    cache_path = data_path.parent / ".cache" / "github.json"
    try:
        cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
    except ValueError:
        cache = {}
    gh = None if args.local else GitHub(cache)
    if gh:
        print(f"GitHub: доступ — {gh.mode()}", file=sys.stderr)
    rows = []
    for p in roster:
        row = {k: p[k] for k in ("id", "name", "company", "department", "mode", "cohort")}
        row["live"] = bool(p.get("live_url"))
        try:
            if args.local:
                path = find_local(Path(args.local), p)
                if not path:
                    raise ApiError("нет локальной папки репозитория")
                src = LocalRepo(path, p["branch"], now)
                rc = {}
            else:
                src = GitHubRepo(gh, p["owner"], p["repo"], p["branch"], now)
                rc = cache.setdefault("repos", {}).setdefault(p["id"], {})
            items = evaluate(src, p, rc, live=not args.no_live)
            row["items"] = items
            row.update(score(items, cfg))
            row["activity"] = src.activity()
        except ApiError as e:
            row.update({"items": {}, "percent": 0.0, "stages": {}, "stage_done": None,
                        "stage": "start", "activity": {}, "error": str(e)})
            print(f"  {p['id']}: {e}", file=sys.stderr)
        rows.append(row)
    history = load_history(data_path)
    flags_for(rows, history, cfg, now)
    for r in rows:
        r["next"] = next_steps(r) if not r.get("error") else []
    if gh:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
        print(f"GitHub: запросов {gh.calls}, осталось в лимите {gh.remaining}", file=sys.stderr)
    cohort = args.cohort or next((r["cohort"] for r in rows if r.get("cohort")), "") or "VibeOps"
    snap = {"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "version": VERSION, "cohort": cohort,
            "expected": (round(expected_percent(cfg, now), 1) if expected_percent(cfg, now) is not None else None),
            "weights_hash": hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest()[:12],
            "participants": rows}
    data_path.parent.mkdir(parents=True, exist_ok=True)
    with data_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(snap, ensure_ascii=False) + "\n")
    return snap


# ---------------------------------------------------------------------------
# Отчёты
# ---------------------------------------------------------------------------

def stage_name(s: str | None) -> str:
    if s == "finished":
        return "Всё готово"
    return STAGE_LABEL.get(s or "", "—")


def summary_md(hist: list[dict]) -> str:
    snap = hist[-1]
    rows = sorted(snap["participants"], key=lambda r: -r["percent"])
    ok = [r for r in rows if not r.get("error")]
    avg = sum(r["percent"] for r in ok) / len(ok) if ok else 0
    prev = hist[-2] if len(hist) > 1 else None
    lines = [f"# Прогресс когорты «{snap['cohort']}»", "",
             f"Снимок: {snap['ts'][:16].replace('T', ' ')} UTC · участников: {len(rows)} · "
             f"средний прогресс: **{avg:.0f}%**" +
             (f" · ожидается по плану: {snap['expected']:.0f}%" if snap.get("expected") is not None else ""), ""]
    lines += ["| # | Участник | Компания | Этап | % | Δ к прошлому | Коммитов за 7 дн. | Флаги |",
              "|---|---|---|---|---|---|---|---|"]
    for i, r in enumerate(rows, 1):
        d = ""
        if prev:
            pr = next((p for p in prev["participants"] if p["id"] == r["id"]), None)
            if pr is not None:
                d = f"{r['percent'] - pr['percent']:+.0f}"
        fl = ", ".join(f["label"] for f in r.get("flags", []))
        c7 = r.get("activity", {}).get("commits_7d")
        lines.append(f"| {i} | {r['name']} | {r['company']} | {stage_name(r['stage'])} | "
                     f"{r['percent']:.0f} | {d} | {'' if c7 is None else c7} | {fl} |")
    stalled = [r for r in rows if any(f["kind"] in ("stalled", "behind", "error") for f in r.get("flags", []))]
    lines += ["", "## Кому помочь", ""]
    if not stalled:
        lines.append("Все идут по плану.")
    for r in stalled:
        fl = ", ".join(f["label"] for f in r["flags"])
        if r.get("error"):
            lines.append(f"- **{r['name']}** — {fl}: {r['error']}. Проверьте доступ на чтение.")
            continue
        steps = "; ".join(f"{s['skill']} — {s['todo']}" for s in r.get("next", []))
        lines.append(f"- **{r['name']}** ({stage_name(r['stage'])}, {r['percent']:.0f}%) — {fl}. Дальше: {steps}")
    ahead = [r for r in rows if any(f["kind"] == "ahead" for f in r.get("flags", []))]
    if ahead:
        lines += ["", "## Впереди", ""] + [f"- {r['name']} — {r['percent']:.0f}%, {stage_name(r['stage'])}" for r in ahead]
    by_co = {}
    for r in ok:
        by_co.setdefault(r["company"] or "—", []).append(r["percent"])
    lines += ["", "## По компаниям", "", "| Компания | Участников | Средний % |", "|---|---|---|"]
    for co, v in sorted(by_co.items(), key=lambda kv: -sum(kv[1]) / len(kv[1])):
        lines.append(f"| {co} | {len(v)} | {sum(v) / len(v):.0f} |")
    funnel = funnel_counts(snap)
    lines += ["", "## Воронка этапов (сколько участников прошли этап)", ""]
    for s, n in funnel:
        lines.append(f"- {STAGE_LABEL[s]}: {n}")
    return "\n".join(lines) + "\n"


def funnel_counts(snap: dict) -> list[tuple[str, int]]:
    res = []
    for s in STAGE_ORDER:
        idx = STAGE_ORDER.index(s)
        n = sum(1 for r in snap["participants"]
                if r.get("stage_done") and STAGE_ORDER.index(r["stage_done"]) >= idx)
        res.append((s, n))
    return res


def telegram_text(hist: list[dict]) -> str:
    snap = hist[-1]
    rows = sorted(snap["participants"], key=lambda r: -r["percent"])
    ok = [r for r in rows if not r.get("error")]
    avg = sum(r["percent"] for r in ok) / len(ok) if ok else 0
    out = [f"Прогресс «{snap['cohort']}» на {snap['ts'][:10]}",
           f"Средний: {avg:.0f}%" + (f" (план {snap['expected']:.0f}%)" if snap.get("expected") is not None else ""),
           ""]
    top = [r for r in rows if any(f["kind"] == "ahead" for f in r.get("flags", []))][:5]
    if top:
        out.append("Впереди: " + ", ".join(f"{r['name']} {r['percent']:.0f}%" for r in top))
    help_ = [r for r in rows if any(f["kind"] in ("stalled", "behind", "error") for f in r.get("flags", []))]
    if help_:
        out.append("Нужна помощь:")
        for r in help_[:10]:
            fl = ", ".join(f["label"] for f in r["flags"])
            nxt = r["next"][0]["skill"] if r.get("next") else "проверить доступ"
            out.append(f"• {r['name']} — {r['percent']:.0f}%, {fl} → {nxt}")
    else:
        out.append("Все идут по плану.")
    out.append("")
    out.append("Этапы: " + " · ".join(f"{STAGE_LABEL[s]} {n}" for s, n in funnel_counts(snap)))
    return "\n".join(out)


def render_html(hist: list[dict]) -> str:
    tpl = (Path(__file__).resolve().parent.parent / "templates" / "report.html").read_text(encoding="utf-8")
    keep = []
    for snap in hist[-120:]:
        keep.append({"ts": snap["ts"], "cohort": snap["cohort"], "expected": snap.get("expected"),
                     "participants": [{k: r.get(k) for k in ("id", "name", "company", "department", "mode",
                                                              "percent", "stage", "stage_done", "items",
                                                              "activity", "flags", "next", "error")}
                                      for r in snap["participants"]]})
    meta = {"stages": STAGES, "items": [{"id": i[0], "stage": i[1], "label": i[2], "skill": i[4]} for i in ITEMS]}
    blob = json.dumps({"history": keep, "meta": meta}, ensure_ascii=False)
    blob = blob.replace("</", "<\\/").replace("<!--", "<\\!--")
    title = html.escape(hist[-1]["cohort"])
    return tpl.replace("__TITLE__", title).replace("__DATA__", blob)


def write_reports(hist: list[dict], out: Path, telegram: bool) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(render_html(hist), encoding="utf-8")
    (out / "summary.md").write_text(summary_md(hist), encoding="utf-8")
    if telegram:
        t = telegram_text(hist)
        (out / "telegram.txt").write_text(t + "\n", encoding="utf-8")
        print(t)
    print(f"Отчёт: {out / 'index.html'} и {out / 'summary.md'}", file=sys.stderr)


def laggards(hist: list[dict]) -> str:
    snap = hist[-1]
    out = []
    for r in sorted(snap["participants"], key=lambda r: r["percent"]):
        kinds = {f["kind"] for f in r.get("flags", [])}
        if not kinds & {"stalled", "behind", "error"}:
            continue
        fl = ", ".join(f["label"] for f in r["flags"])
        out.append(f"{r['name']} ({r['company'] or '—'}) — {r['percent']:.0f}%, этап «{stage_name(r['stage'])}», {fl}")
        if r.get("error"):
            out.append(f"  причина: {r['error']}")
        a = r.get("activity") or {}
        if a.get("days_since_commit") is not None:
            out.append(f"  последний коммит {a['days_since_commit']} дн. назад, за неделю коммитов: {a.get('commits_7d')}")
        for s in r.get("next", []):
            out.append(f"  дальше: {s['skill']} — {s['todo']}")
    return "\n".join(out) or "Отстающих нет."


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Прогресс участников VibeOps по репозиториям")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="проверить репозитории, добавить снимок и обновить отчёт")
    c.add_argument("--roster", required=True)
    c.add_argument("--weights")
    c.add_argument("--local", help="папка с локальными клонами вместо GitHub")
    c.add_argument("--data", default="data/progress.jsonl")
    c.add_argument("--out", default="report")
    c.add_argument("--cohort")
    c.add_argument("--now", help="время снимка ISO (для тестов)")
    c.add_argument("--no-live", action="store_true", help="не проверять живые адреса /healthz")
    c.add_argument("--telegram-text", action="store_true")
    r = sub.add_parser("report", help="только перерисовать отчёт из истории")
    r.add_argument("--data", default="data/progress.jsonl")
    r.add_argument("--out", default="report")
    r.add_argument("--telegram-text", action="store_true")
    lg = sub.add_parser("laggards", help="кто отстаёт и какой навык следующий")
    lg.add_argument("--data", default="data/progress.jsonl")
    a = ap.parse_args(argv)

    if a.cmd == "check":
        cfg = load_config(a.weights)
        collect(a, cfg)
    hist = load_history(Path(a.data))
    if not hist:
        print("Истории нет: сначала запустите check", file=sys.stderr)
        return 2
    if a.cmd == "laggards":
        print(laggards(hist))
        return 0
    write_reports(hist, Path(a.out), a.telegram_text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
