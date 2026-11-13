#!/usr/bin/env python3
"""Коллекция ТЗ: SPEC.md и документы плана всех участников курса в одном закрытом репозитории.

Читает репозитории участников из того же списка, что /airl-progress (roster.csv
или roster.yml: name, company, department, mode, repo, branch, path, live_url,
cohort), берёт только документы плана (SPEC.md, ARCHITECTURE.md,
airl.service.json, SCOPE.md, PRD_FINAL.md, BACKLOG.md, COMPANY_MAP.md …) и
раскладывает их в рабочую копию репозитория коллекции:

  <поток>/<компания>/<участник>/SPEC.md, …, meta.json, CHANGELOG.md
  README.md   — оглавление: таблица по потокам
  PAINS.md    — боли по отделам и повторяющиеся боли («кандидат в модуль»)
  METRICS.md  — показатели из всех ТЗ и сколько участников их используют
  summary.json — то же для других программ

Команды:
  python3 collect.py collect --roster roster.csv --out DIR [--local DIR] [--since ДАТА]
                             [--repo owner/name] [--allow-public] [--on-secret mask|skip]
  python3 collect.py index   --out DIR                  # только пересобрать оглавление
  python3 collect.py changes --out DIR [--since ДАТА]   # чьи ТЗ менялись (по умолчанию за 7 дней)

Доступ к GitHub: GITHUB_TOKEN (fine-grained, только чтение Contents и Metadata
в репозиториях участников). Нет токена — `gh api` (если gh вошёл), иначе без
токена (только публичные репозитории). GITHUB_API_URL меняет адрес API (тесты).
COLLECTION_TOKEN (необязательно) — токен для проверки, что репозиторий
коллекции закрытый (в GitHub Actions — встроенный github.token).

Правила безопасности (зашиты в код):
  * в репозитории участников ничего не пишем; читаем только документы из списка
    DOCS, каждый не больше 300 КБ; код, .env и ключи не берём никогда;
  * пишем только в папку --out; коммит и push делает GitHub Actions или человек;
  * репозиторий коллекции должен быть закрытым: если API говорит «публичный» —
    отказ (код 2), пока не передан --allow-public;
  * в собранных копиях ключи, пароли, телефоны, ИИН и почта заменяются на
    «‹… скрыт›» (или файл пропускается целиком: --on-secret skip);
  * токен не печатается и не сохраняется.

Только стандартная библиотека Python 3.9+.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
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
UA = "airl-collect/" + VERSION
MAX_DOC = 300 * 1024

# Документ в коллекции → где искать у участника (относительно корня или подпапки path).
DOCS = [
    ("SPEC.md", ["SPEC.md", "SPEC.hub.md", "docs/SPEC.md"]),
    ("ARCHITECTURE.md", ["ARCHITECTURE.md", "docs/ARCHITECTURE.md"]),
    ("airl.service.json", ["airl.service.json"]),
    ("SCOPE.md", ["SCOPE.md", "docs/SCOPE.md"]),
    ("PRD_CONTEXT.md", ["PRD_CONTEXT.md", "docs/PRD_CONTEXT.md"]),
    ("PRD_FINAL.md", ["PRD_FINAL.md", "docs/PRD_FINAL.md"]),
    ("BACKLOG.md", ["BACKLOG.md", "docs/BACKLOG.md"]),
    ("COMPANY_MAP.md", ["COMPANY_MAP.md"]),
    ("airl/COMPANY_MAP.md", ["airl/COMPANY_MAP.md"]),
]
DOC_KEYS = [k for k, _ in DOCS]
# Что ожидаем увидеть (иначе — «нет» в meta.json): остальное необязательно.
EXPECTED = {"solo": ["SPEC.md", "ARCHITECTURE.md"],
            "hub": ["SPEC.md", "ARCHITECTURE.md", "airl.service.json", "airl/COMPANY_MAP.md"],
            "airl": ["SCOPE.md", "COMPANY_MAP.md"]}
# Запасная защита: такие пути не берём, даже если кто-то добавит их в DOCS.
FORBIDDEN = re.compile(r"(^|/)(\.env[^/]*|.*\.(pem|key|p12|pfx|crt|sqlite|db)|id_rsa[^/]*|"
                       r".*secret[^/]*|.*credential[^/]*)$", re.I)
CACHE_DIR = ".airl-collect"
SKIP_TREE = {".git", "node_modules", "dist", "build", ".next", "vendor", "__pycache__", ".venv", "venv"}


# ---------------------------------------------------------------------------
# Мини-YAML для roster.yml (тот же формат, что у /airl-progress)
# ---------------------------------------------------------------------------

def _scalar(v: str):
    v = v.strip()
    if v == "" or v in ("~", "null"):
        return None
    if v[0] == v[-1] and v[0] in "\"'" and len(v) >= 2:
        return v[1:-1]
    return v


def mini_yaml_list(text: str) -> list[dict]:
    """Подмножество YAML: `participants:` и список словарей `- key: value`."""
    rows, cur = [], None
    for raw in text.splitlines():
        line = re.sub(r"(^|\s)#.*$", "", raw).rstrip()
        if not line.strip() or re.match(r"^\S[^:]*:\s*$", line):
            continue
        s = line.strip()
        if s.startswith("- "):
            cur = {}
            rows.append(cur)
            s = s[2:].strip()
        if cur is not None and ":" in s:
            k, _, v = s.partition(":")
            cur[k.strip()] = _scalar(v) or ""
    return rows


# ---------------------------------------------------------------------------
# Список участников — тот же, что у /airl-progress
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


def parse_repo_loose(value: str) -> tuple[str, str]:
    try:
        return parse_repo(value)
    except ValueError:
        v = re.sub(r"^https?://[^/]+/", "", (value or "").strip()).removesuffix(".git").strip("/")
        if v and "/" not in v and re.match(r"^[\w.\-]+$", v):
            return "", v
        raise


def clean_subpath(value: str) -> str:
    v = (value or "").strip().replace("\\", "/").strip("/")
    v = re.sub(r"/+", "/", v)
    if v in ("", "."):
        return ""
    if any(x == ".." for x in v.split("/")):
        raise ValueError(f"подпапка {value!r}: «..» не допускается")
    return v.removeprefix("./")


def load_roster(path: str) -> list[dict]:
    p = Path(path)
    if p.suffix in (".yml", ".yaml"):
        text = p.read_text(encoding="utf-8")
        try:
            import yaml  # type: ignore
            data = yaml.safe_load(text) or {}
            rows = data.get("participants", data) if isinstance(data, dict) else data
        except ImportError:
            rows = mini_yaml_list(text)
    else:
        with p.open(encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
    out, seen = [], set()
    for r in rows or []:
        r = {k.strip(): ("" if v is None else str(v).strip()) for k, v in r.items() if k}
        if not r.get("repo") or r.get("name", "").startswith("#"):
            continue
        owner, name = parse_repo_loose(r["repo"])
        sub = clean_subpath(r.get("path", ""))
        pid = f"{owner}/{name}" if owner else name
        if sub:
            pid += ":" + sub
        if pid in seen:
            continue
        seen.add(pid)
        mode = (r.get("mode") or "solo").lower()
        out.append({
            "id": pid, "owner": owner, "repo": name, "path": sub,
            "name": r.get("name") or pid, "company": r.get("company", ""),
            "department": r.get("department", ""),
            "mode": "hub" if mode == "hub" else ("airl" if mode in ("airl", "airl-hub", "команда airl") else "solo"),
            "branch": r.get("branch", ""), "cohort": r.get("cohort", ""),
        })
    return out


# ---------------------------------------------------------------------------
# Имена папок
# ---------------------------------------------------------------------------

TRANSLIT = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюяәғқңөұүһі",
                    ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "i", "k", "l", "m", "n", "o", "p",
                     "r", "s", "t", "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya",
                     "a", "g", "q", "n", "o", "u", "u", "h", "i"]))


def slug(text: str, fallback: str = "x") -> str:
    s = "".join(TRANSLIT.get(ch, ch) for ch in (text or "").lower())
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s[:60] or fallback


def assign_slugs(roster: list[dict]) -> None:
    """Папка участника: <поток>/<компания>/<имя>; одинаковые имена — с именем репозитория."""
    for p in roster:
        p["dir"] = "/".join([slug(p["cohort"], "bez-potoka"), slug(p["company"], "bez-kompanii"),
                             slug(p["name"], slug(p["repo"]))])
    seen: dict[str, int] = {}
    for p in roster:
        seen[p["dir"]] = seen.get(p["dir"], 0) + 1
    for p in roster:
        if seen[p["dir"]] > 1:
            extra = slug(p["repo"] + ("-" + p["path"] if p["path"] else ""))
            p["dir"] = p["dir"] + "-" + extra


# ---------------------------------------------------------------------------
# Источники: локальная папка и GitHub API (только чтение)
# ---------------------------------------------------------------------------

class ApiError(Exception):
    pass


def blob_sha(data: bytes) -> str:
    """Тот же SHA, что у git и GitHub для содержимого файла."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


class LocalRepo:
    """Клон репозитория участника в локальной папке (тесты, работа без сети)."""

    def __init__(self, path: Path, branch: str, sub: str = ""):
        self.base = path
        self.path = path / sub if sub else path
        if not self.path.is_dir():
            raise ApiError(f"в папке {path.name} нет подпапки {sub}")
        ref = branch or "HEAD"
        r = subprocess.run(["git", "-C", str(path), "rev-parse", ref], capture_output=True, text=True)
        self.head = r.stdout.strip() if r.returncode == 0 else None
        self.source_url = ""

    def find(self, candidates: list[str]) -> dict | None:
        for rel in candidates:
            f = self.path / rel
            if f.is_file():
                return {"path": rel, "size": f.stat().st_size, "sha": blob_sha(f.read_bytes())}
        return None

    def read(self, info: dict) -> bytes:
        return (self.path / info["path"]).read_bytes()


class GitHub:
    """Мини-клиент REST API GitHub (как в /airl-progress): токен, `gh api` или без токена."""

    def __init__(self, token_env: tuple[str, ...] = ("GITHUB_TOKEN", "GH_TOKEN")):
        self.base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        self.token = next((os.environ[k] for k in token_env if os.environ.get(k)), "")
        self.use_gh = False
        if not self.token and shutil.which("gh") and "GITHUB_API_URL" not in os.environ:
            self.use_gh = subprocess.run(["gh", "auth", "status"], capture_output=True).returncode == 0
        self.calls = 0
        self.remaining = None

    def mode(self) -> str:
        return "токен" if self.token else ("gh" if self.use_gh else "без токена")

    def _rate(self, hdrs):
        try:
            self.remaining = int(hdrs["x-ratelimit-remaining"])
        except (KeyError, ValueError):
            pass

    def req(self, path: str, accept="application/vnd.github+json", etag=None):
        """(status, body, headers). 304 — тело пустое."""
        self.calls += 1
        if self.remaining is not None and self.remaining < 5:
            raise ApiError("лимит запросов GitHub почти исчерпан — повторите позже")
        if self.use_gh:
            cmd = ["gh", "api", "-i", "-H", f"Accept: {accept}", path.lstrip("/")]
            if etag:
                cmd[3:3] = ["-H", f"If-None-Match: {etag}"]
            r = subprocess.run(cmd, capture_output=True)
            head, _, body = r.stdout.partition(b"\r\n\r\n")
            if not body and b"\n\n" in r.stdout:
                head, _, body = r.stdout.partition(b"\n\n")
            lines = head.decode("utf-8", "replace").splitlines()
            m = re.match(r"HTTP/\S+\s+(\d+)", lines[0] if lines else "")
            status = int(m.group(1)) if m else (200 if r.returncode == 0 else 500)
            hdrs = {}
            for ln in lines[1:]:
                k, _, v = ln.partition(":")
                hdrs[k.strip().lower()] = v.strip()
            self._rate(hdrs)
            return status, body, hdrs
        req = urllib.request.Request(self.base + path, headers={
            "Accept": accept, "User-Agent": UA, "X-GitHub-Api-Version": "2022-11-28"})
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
                e.close()
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

    def json(self, path: str):
        status, body, _ = self.req(path)
        if status == 404:
            return None
        if status >= 400:
            raise ApiError(f"GitHub ответил {status} на {path.split('?')[0]}")
        return json.loads(body or b"null")


class GitHubRepo:
    def __init__(self, gh: GitHub, owner: str, name: str, branch: str, sub: str, cache: dict):
        self.gh, self.sub = gh, sub
        self.p = f"/repos/{urllib.parse.quote(owner)}/{urllib.parse.quote(name)}"
        meta = gh.json(self.p)
        if meta is None:
            raise ApiError("репозиторий не найден или нет доступа на чтение")
        self.branch = branch or meta.get("default_branch") or "main"
        b = gh.json(f"{self.p}/branches/{urllib.parse.quote(self.branch, safe='')}")
        if b is None:
            raise ApiError(f"ветка {self.branch} не найдена")
        self.head = b["commit"]["sha"]
        host = "https://github.com"
        self.source_url = f"{host}/{owner}/{name}/tree/{self.branch}" + (f"/{sub}" if sub else "")
        self.rc = cache.setdefault("repos", {}).setdefault(f"{owner}/{name}", {})
        self._tree = None

    def tree(self) -> dict:
        if self._tree is not None:
            return self._tree
        tc = self.rc.get("tree") or {}
        etag = tc.get("etag") if tc.get("head") == self.head else None
        status, body, hdrs = self.gh.req(f"{self.p}/git/trees/{self.head}?recursive=1", etag=etag)
        if status == 304 and tc.get("files"):
            files = tc["files"]
        elif status == 200:
            files = {}
            for e in json.loads(body).get("tree", []):
                if e.get("type") != "blob" or any(x in SKIP_TREE for x in e["path"].split("/")[:-1]):
                    continue
                if not e["path"].endswith((".md", ".json")):
                    continue        # нам нужны только документы — остальное даже не запоминаем
                files[e["path"]] = {"size": e.get("size", 0), "sha": e.get("sha")}
            self.rc["tree"] = {"head": self.head, "etag": hdrs.get("etag"), "files": files}
        else:
            raise ApiError(f"не удалось прочитать список файлов (код {status})")
        self._tree = files
        return files

    def find(self, candidates: list[str]) -> dict | None:
        files = self.tree()
        pre = self.sub + "/" if self.sub else ""
        for rel in candidates:
            f = files.get(pre + rel)
            if f:
                return {"path": rel, "size": f["size"], "sha": f["sha"]}
        return None

    def read(self, info: dict) -> bytes:
        status, body, _ = self.gh.req(f"{self.p}/git/blobs/{info['sha']}", accept="application/vnd.github.raw")
        if status != 200:
            raise ApiError(f"не удалось скачать {info['path']} (код {status})")
        return body


# ---------------------------------------------------------------------------
# Маскирование ключей и персональных данных
# ---------------------------------------------------------------------------

def _iin_ok(d: str) -> bool:
    """Контрольная цифра ИИН/БИН Казахстана и правдоподобная дата рождения."""
    if len(d) != 12 or not d.isdigit():
        return False
    if not (1 <= int(d[2:4]) <= 12 and 1 <= int(d[4:6]) <= 31):
        return False
    n = [int(x) for x in d]
    s = sum(n[i] * (i + 1) for i in range(11)) % 11
    if s == 10:
        s = sum(n[i] * ((i + 2) % 11 or 11) for i in range(11)) % 11
        if s == 10:
            return False
    return s == n[11]


SECRET_RES = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)", re.S),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bsk-(?:ant-|proj-|live_|test_)?[A-Za-z0-9_\-]{20,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bAIza[0-9A-Za-z_\-]{35}"),
    re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b"),                    # токен Telegram-бота
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),   # JWT
]
URL_PASS_RE = re.compile(r"(://[^/\s:@]+):([^@\s/]+)@")
ASSIGN_RE = re.compile(r"(?i)\b(password|passwd|pwd|пароль|secret|token|api[_-]?key|access[_-]?key|"
                       r"client[_-]?secret|private[_-]?key)(\s*[:=]\s*[\"'`]?)"
                       r"((?=[A-Za-z0-9_\-+/=.]*\d)[A-Za-z0-9_\-+/=.]{8,})")
EMAIL_RE = re.compile(r"(?<![\w.+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
IIN_LABEL_RE = re.compile(r"(?i)((?:ИИН|ПИНФЛ|IIN|PINFL)[\s:№#-]*)(\d{12,14})(?!\d)")
DIGITS12_RE = re.compile(r"(?<!\d)\d{12}(?!\d)")
PHONE_RE = re.compile(r"(?<![\w+])(?:\+7|8|\+998|\+996|\+992|\+993|\+375|\+380)[\s\-(]*\d{2,3}[\s\-)]*"
                      r"\d{3}[\s\-]*\d{2}[\s\-]*\d{2}(?!\d)")

MASK = {"secret": "‹ключ скрыт›", "email": "‹почта скрыта›", "iin": "‹ИИН скрыт›", "phone": "‹телефон скрыт›"}


def mask_text(text: str) -> tuple[str, dict]:
    """Заменить ключи, пароли, почту, ИИН и телефоны. Возвращает (текст, счётчики)."""
    counts = {"secret": 0, "email": 0, "iin": 0, "phone": 0}

    def sub(rx, kind, t, repl=None):
        def f(m):
            counts[kind] += 1
            return repl(m) if repl else MASK[kind]
        return rx.sub(f, t)

    for rx in SECRET_RES:
        text = sub(rx, "secret", text)
    text = sub(URL_PASS_RE, "secret", text, lambda m: m.group(1) + ":" + MASK["secret"] + "@")
    text = sub(ASSIGN_RE, "secret", text, lambda m: m.group(1) + m.group(2) + MASK["secret"])
    text = sub(EMAIL_RE, "email", text)
    text = sub(IIN_LABEL_RE, "iin", text, lambda m: m.group(1) + MASK["iin"])

    def iin(m):
        if _iin_ok(m.group(0)):
            counts["iin"] += 1
            return MASK["iin"]
        return m.group(0)
    text = DIGITS12_RE.sub(iin, text)
    text = sub(PHONE_RE, "phone", text)
    return text, counts


# ---------------------------------------------------------------------------
# Разбор ТЗ: готовность по разделам, продукт, боль, метрика
# ---------------------------------------------------------------------------

PLACEHOLDER = re.compile(r"\[[^\]\n]{2,}\]")
SEP_RE = re.compile(r"^\s*\|?[\s:\-|]+\|?\s*$")


def _clean(line: str) -> str:
    s = re.sub(r"\[[ xX]\]", "", line)              # чекбоксы
    return re.sub(r"\[[^\]]*\]\([^)]*\)", "", s)     # ссылки


def _filled(line: str) -> bool:
    s = _clean(line)
    return not PLACEHOLDER.search(s) and "..." not in s and "…" not in s


def strip_comments(text: str) -> str:
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def sections(text: str) -> dict[str, str]:
    """{номер раздела: текст} для заголовков «## N. …». Подсказки <!-- --> не считаются."""
    text = strip_comments(text)
    out = {}
    heads = list(re.finditer(r"^##\s*(\d+)\.?\s.*$", text, re.M))
    allh = [m.start() for m in re.finditer(r"^##\s", text, re.M)]
    for m in heads:
        nxt = [p for p in allh if p > m.start()]
        out.setdefault(m.group(1), text[m.end(): nxt[0] if nxt else len(text)])
    return out


def section_score(body: str) -> float:
    filled = unfilled = 0
    lines = body.splitlines()
    for i, ln in enumerate(lines):
        s = ln.strip()
        if not s or s.startswith("#") or SEP_RE.match(s) and "-" in s:
            continue
        if s.startswith("|") and i + 1 < len(lines) and SEP_RE.match(lines[i + 1]) and "-" in lines[i + 1]:
            continue        # строка заголовков таблицы — из шаблона
        if not re.search(r"\w", s):
            continue
        if _filled(s):
            filled += 1
        else:
            unfilled += 1
    if filled == 0:
        return 0.0
    return round(filled / (filled + unfilled), 2)


def check_pain(secs: dict) -> float:
    sec = secs.get("1", "")
    for ln in sec.splitlines():
        if re.search(r"цена боли", ln, re.I) and _filled(ln) and re.search(r"\d", ln):
            return 1.0
    body = [ln for ln in sec.splitlines() if ln.strip() and _filled(ln)]
    return 0.5 if len(" ".join(body)) > 60 else 0.0


def check_metric(text: str) -> float:
    for ln in strip_comments(text).splitlines():
        if re.search(r"метрика успеха", ln, re.I):
            if _filled(ln) and re.search(r"\d", ln):
                return 1.0
            if _filled(ln) and len(ln) > 40:
                return 0.5
    return 0.0


def check_criteria(secs: dict) -> float:
    n = sum(1 for ln in secs.get("10", "").splitlines()
            if re.match(r"\s*-\s*\[[ xX]\]\s*\S", ln) and _filled(ln) and len(ln.strip()) > 12)
    return 1.0 if n >= 3 else (0.5 if n >= 1 else 0.0)


def completeness(text: str) -> dict:
    """Готовность ТЗ: 70% — разделы 1–12 заполнены, по 10% — боль в цифрах, метрика, критерии."""
    secs = sections(text)
    per = {str(n): section_score(secs[str(n)]) if str(n) in secs else 0.0 for n in range(1, 13)}
    pain, metric, crit = check_pain(secs), check_metric(text), check_criteria(secs)
    pct = 100 * (0.7 * sum(per.values()) / 12 + 0.1 * pain + 0.1 * metric + 0.1 * crit)
    markers = len(PLACEHOLDER.findall(_clean(strip_comments(text))))
    comments = len(re.findall(r"<!--", text))
    return {"percent": round(pct), "sections": per,
            "sections_missing": [n for n in per if n not in secs],
            "pain_in_numbers": pain, "metric_before_after": metric, "acceptance_criteria": crit,
            "unfilled_markers": markers, "template_comments": comments}


def _value(line: str) -> str:
    v = line.split(":", 1)[1] if ":" in line else line
    v = re.sub(r"[*_`]", "", v).strip(" —-\t")
    return v


def _oneline(s: str, n: int = 140) -> str:
    s = re.sub(r"\s+", " ", s).strip()
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def extract(text: str) -> dict:
    """Продукт (первый H1), главная боль, метрика, текст боли для поиска похожих."""
    body = strip_comments(text)
    product = ""
    m = re.search(r"^#\s+(.+)$", body, re.M)
    if m and _filled(m.group(1)):
        h1 = m.group(1).strip()
        q = re.search(r"«([^»]+)»", h1)
        product = _oneline(q.group(1) if q else h1, 80)
    sec1 = sections(text).get("1", "")
    now = price = ""
    for ln in sec1.splitlines():
        if not _filled(ln):
            continue
        if re.search(r"\*\*Сейчас\*\*|^Сейчас", ln.strip()):
            now = _value(ln)
        elif re.search(r"цена боли", ln, re.I):
            price = re.split(r"\s+[—-]\s+как замерили", _value(ln), flags=re.I)[0].strip()
    metric = ""
    for ln in body.splitlines():
        if re.search(r"метрика успеха", ln, re.I) and _filled(ln):
            metric = _oneline(_value(ln), 100)
            break
    pain = _oneline(now or price or "")
    if now and price:
        pain = _oneline(f"{now} Цена: {price}")
    return {"product": product, "pain": pain, "metric": metric, "pain_text": " ".join([now, price]).strip()}


def metrics_declared(spec: str, service_json: str | None) -> list[str]:
    """id или названия показателей: hub.metrics из airl.service.json и первая колонка разделов 6–7."""
    out = []
    if service_json:
        try:
            d = json.loads(service_json)
            out += [str(x) for x in (d.get("hub") or {}).get("metrics") or []]
        except (ValueError, AttributeError):
            pass
    secs = sections(spec) if spec else {}
    # раздел 7 — показатели только в ТЗ сервиса отдела («Что отдаёт в хаб»); у своего продукта там API
    hub7 = bool(spec) and re.search(r"^##\s*7\.?\s.*хаб", strip_comments(spec), re.M | re.I)
    for num in (("6", "7") if hub7 else ("6",)):
        lines = secs.get(num, "").splitlines()
        for i, ln in enumerate(lines):
            s = ln.strip()
            if not s.startswith("|") or SEP_RE.match(s):
                continue
            if i + 1 < len(lines) and SEP_RE.match(lines[i + 1]) and "-" in lines[i + 1]:
                continue
            cell = s.strip("|").split("|")[0].strip()
            out.append(cell)
    res = []
    for x in out:
        x = re.sub(r"[`*]", "", x).strip().lower()
        if not x or not _filled(x) or "‹" in x or len(x) > 60:
            continue
        if x not in res:
            res.append(x)
    return res


def changed_sections(old: str, new: str) -> dict:
    def split(t):
        res, cur, buf = {}, "шапка", []
        for ln in strip_comments(t).splitlines():
            if ln.startswith("## "):
                res[cur] = "\n".join(buf).strip()
                cur, buf = ln[3:].strip(), []
            else:
                buf.append(ln)
        res[cur] = "\n".join(buf).strip()
        return res
    a, b = split(old), split(new)
    return {"added": [k for k in b if k not in a], "removed": [k for k in a if k not in b],
            "changed": [k for k in b if k in a and a[k] != b[k]]}


# ---------------------------------------------------------------------------
# Повторяющиеся боли: простые ключевые слова, без ИИ
# ---------------------------------------------------------------------------

ENDINGS = sorted("ются ется ится ятся ают яют ешь ете ить ать ять ться лись ами ями ого его ому ему "
                 "ых их ах ях ов ев ей ий ый ой ая яя ое ее ые ие ым им ом ем ую юю ам ям ок "
                 "ут ют ет ит ла ли ло а я о е ы и у ю ь".split(), key=len, reverse=True)
STOP = set()


def stem(word: str) -> str:
    w = word.lower().replace("ё", "е")
    for e in ENDINGS:
        if w.endswith(e) and len(w) - len(e) >= 3:
            w = w[: -len(e)]
            break
    return w[:5] if len(w) >= 6 else w[:4]


for _w in ("сейчас после через когда который которые которых чтобы потом очень каждый каждую каждое "
           "неделю неделя недели часов часа минут минуты день дней месяц месяца тенге рублей сумма "
           "также этого этот эта эти всех всего много меньше больше нужно можно есть было будет "
           "стало станет часто время руками вручную сотрудник сотрудники руководитель отдел отдела "
           "компания компании число замер замерили запуска среднем около примерно штук цена "
           "процентов процент человек людей работы работа делаем делают тратим тратят теряем").split():
    STOP.add(stem(_w))


def keywords(text: str) -> set[str]:
    words = re.findall(r"[A-Za-zА-Яа-яЁёӘәҒғҚқҢңӨөҰұҮүҺһІі]{4,}", text or "")
    return {s for s in (stem(w) for w in words) if len(s) >= 3 and s not in STOP}


def cluster_pains(rows: list[dict], min_shared: int = 2) -> list[dict]:
    """Участники в одну группу, если в их болях не меньше min_shared общих ключевых слов."""
    items = [(r, keywords(r.get("pain_text") or r.get("pain") or "")) for r in rows]
    items = [(r, k) for r, k in items if k]
    parent = list(range(len(items)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            if len(items[i][1] & items[j][1]) >= min_shared:
                parent[find(i)] = find(j)
    groups: dict[int, list] = {}
    for i in range(len(items)):
        groups.setdefault(find(i), []).append(i)
    out = []
    for idx in groups.values():
        if len(idx) < 2:
            continue
        freq: dict[str, int] = {}
        forms: dict[str, dict[str, int]] = {}
        for i in idx:
            for k in items[i][1]:
                freq[k] = freq.get(k, 0) + 1
            for w in re.findall(r"[A-Za-zА-Яа-яЁё]{4,}", items[i][0].get("pain_text") or ""):
                s = stem(w)
                forms.setdefault(s, {})
                forms[s][w.lower()] = forms[s].get(w.lower(), 0) + 1
        shared = sorted([k for k, v in freq.items() if v >= 2], key=lambda k: (-freq[k], k))[:5]
        label = [max(forms.get(k, {k: 1}).items(), key=lambda kv: (kv[1], -len(kv[0])))[0] for k in shared]
        members = [items[i][0] for i in idx]
        companies = sorted({m.get("company") or "—" for m in members})
        out.append({"keywords": label, "companies": companies, "n_companies": len(companies),
                    "participants": [{"name": m["name"], "company": m.get("company", ""),
                                      "department": m.get("department", ""), "pain": m.get("pain", ""),
                                      "dir": m.get("dir", "")} for m in members],
                    "module_candidate": len(companies) >= 2})
    out.sort(key=lambda c: (-c["n_companies"], -len(c["participants"]), c["keywords"]))
    return out


# ---------------------------------------------------------------------------
# Сбор
# ---------------------------------------------------------------------------

def now_utc(value: str | None) -> dt.datetime:
    if value:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt.datetime.now(dt.timezone.utc)


def iso(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_candidates(base: Path, p: dict) -> list[Path]:
    o, n = p.get("owner"), p["repo"]
    c = [base / f"{o}__{n}", base / o / n] if o else []
    c.append(base / n)
    if not o:
        c += sorted(x for x in base.glob(f"*__{n}") if x.is_dir())
    return c


def find_local(base: Path, p: dict) -> Path | None:
    return next((c for c in local_candidates(base, p) if c.is_dir()), None)


def collection_repo(out: Path, explicit: str | None) -> str | None:
    if explicit:
        o, n = parse_repo(explicit)
        return f"{o}/{n}"
    if os.environ.get("GITHUB_REPOSITORY"):
        return os.environ["GITHUB_REPOSITORY"]
    r = subprocess.run(["git", "-C", str(out), "remote", "get-url", "origin"], capture_output=True, text=True)
    url = r.stdout.strip()
    if r.returncode == 0 and url:
        try:
            o, n = parse_repo(url)
            return f"{o}/{n}"
        except ValueError:
            return None
    return None


def check_private(out: Path, explicit: str | None, allow_public: bool) -> tuple[bool, str]:
    """(можно писать, сообщение). Публичный репозиторий коллекции — отказ без --allow-public."""
    repo = collection_repo(out, explicit)
    if not repo:
        return True, ("ВНИМАНИЕ: не знаю, какой репозиторий у коллекции (нет remote origin и --repo) — "
                      "не смог проверить, что он закрытый. Убедитесь сами: Settings → General → Danger Zone.")
    try:
        gh = GitHub(("COLLECTION_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"))
        meta = gh.json("/repos/" + "/".join(urllib.parse.quote(x) for x in repo.split("/")))
    except ApiError as e:
        meta, err = None, str(e)
    else:
        err = ""
    if meta is None:
        return True, (f"ВНИМАНИЕ: не смог проверить, закрыт ли {repo} ({err or 'нет доступа к описанию'}). "
                      "Закрытый репозиторий без токена выглядит как «не найден» — это нормально, "
                      "но проверьте настройки руками.")
    public = meta.get("private") is False or meta.get("visibility") == "public"
    if public and not allow_public:
        return False, (f"СТОП: репозиторий коллекции {repo} ПУБЛИЧНЫЙ. В ТЗ бывают данные клиентов и "
                       "персональные данные — сделайте репозиторий закрытым (Settings → General → "
                       "Change visibility → Private) и запустите снова. Ничего не записано.")
    if public:
        return True, f"ВНИМАНИЕ: {repo} публичный, запись разрешена флагом --allow-public."
    return True, f"Репозиторий коллекции {repo}: закрытый — хорошо."


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def write_if_changed(path: Path, text: str) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return False
    path.write_text(text, encoding="utf-8")
    return True


def dump(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def collect_one(p: dict, src, out: Path, now: dt.datetime, on_secret: str) -> dict:
    """Собрать документы одного участника. Возвращает отчёт о том, что изменилось."""
    dest = out / p["dir"]
    old = read_json(dest / "meta.json")
    old_files = old.get("files") or {}
    files, found, missing, skipped = {}, [], [], []
    masked_total = {"secret": 0, "email": 0, "iin": 0, "phone": 0}
    changes = {"new": [], "changed": [], "removed": []}
    old_spec = (dest / "SPEC.md").read_text(encoding="utf-8") if (dest / "SPEC.md").exists() else ""
    for key, cands in DOCS:
        info = src.find(cands)
        target = dest / key
        if info is None:
            if key in EXPECTED.get(p["mode"], []):
                missing.append(key)
            if target.exists():
                target.unlink()
                changes["removed"].append(key)
            continue
        if FORBIDDEN.search(info["path"]):
            skipped.append({"file": info["path"], "reason": "запрещённое имя файла"})
            continue
        if info["size"] > MAX_DOC:
            skipped.append({"file": info["path"], "reason": f"больше {MAX_DOC // 1024} КБ"})
            continue
        prev = old_files.get(key) or {}
        if prev.get("sha") == info["sha"] and target.exists() and prev.get("source") == info["path"]:
            files[key] = prev          # не изменился — не скачиваем снова
            found.append(key)
            for k, v in (prev.get("masked") or {}).items():
                masked_total[k] = masked_total.get(k, 0) + v
            continue
        raw = src.read(info)
        if b"\0" in raw[:4096]:
            skipped.append({"file": info["path"], "reason": "не текстовый файл"})
            continue
        text, counts = mask_text(raw.decode("utf-8", "replace"))
        if counts["secret"] and on_secret == "skip":
            skipped.append({"file": info["path"], "reason": f"найдены ключи или пароли ({counts['secret']}) — "
                                                            "файл не собран"})
            if target.exists():
                target.unlink()
                changes["removed"].append(key)
            continue
        existed = target.exists()
        if write_if_changed(target, text):
            changes["changed" if existed else "new"].append(key)
        files[key] = {"source": info["path"], "sha": info["sha"], "size": info["size"],
                      "masked": {k: v for k, v in counts.items() if v}}
        found.append(key)
        for k, v in counts.items():
            masked_total[k] += v
    spec = (dest / "SPEC.md").read_text(encoding="utf-8") if (dest / "SPEC.md").exists() else ""
    sj = (dest / "airl.service.json").read_text(encoding="utf-8") if (dest / "airl.service.json").exists() else None
    comp = completeness(spec) if spec else {"percent": 0, "sections": {}, "sections_missing": [],
                                            "pain_in_numbers": 0, "metric_before_after": 0,
                                            "acceptance_criteria": 0, "unfilled_markers": 0,
                                            "template_comments": 0}
    ex = extract(spec) if spec else {"product": "", "pain": "", "metric": "", "pain_text": ""}
    any_change = any(changes.values())
    spec_changed = "SPEC.md" in changes["new"] + changes["changed"] + changes["removed"]
    meta = {
        "id": p["id"], "name": p["name"], "company": p["company"], "department": p["department"],
        "mode": p["mode"], "cohort": p["cohort"],
        "source": {"repo": f"{p['owner']}/{p['repo']}" if p["owner"] else p["repo"],
                   "branch": getattr(src, "branch", "") or p["branch"], "path": p["path"],
                   "url": src.source_url,
                   "commit": src.head if any_change or not old else (old.get("source") or {}).get("commit")},
        "fetched_at": iso(now) if any_change or not old else old.get("fetched_at"),
        "spec_changed_at": iso(now) if spec_changed else old.get("spec_changed_at"),
        "files": files, "found": found, "missing": missing, "skipped": skipped,
        "masked": {k: v for k, v in masked_total.items() if v},
        "completeness": comp,
        "product": ex["product"], "pain": ex["pain"], "metric": ex["metric"],
        "metrics": metrics_declared(spec, sj),
    }
    write_if_changed(dest / "meta.json", dump(meta))
    if any_change:
        append_changelog(dest, p, meta, changes, old_spec, spec, old)
    return {"id": p["id"], "name": p["name"], "dir": p["dir"], "changes": changes, "spec_changed": spec_changed,
            "masked": meta["masked"], "skipped": skipped, "missing": missing,
            "percent": comp["percent"], "old_percent": (old.get("completeness") or {}).get("percent")}


def append_changelog(dest: Path, p: dict, meta: dict, changes: dict, old_spec: str, spec: str, old: dict):
    path = dest / "CHANGELOG.md"
    head = "" if path.exists() else (f"# История ТЗ — {p['name']} ({p['company'] or 'без компании'})\n\n"
                                     "Пишет airl-collect при каждом изменении документов. "
                                     "Полная история — в git этого репозитория.\n")
    commit = (meta["source"].get("commit") or "")[:7]
    lines = [f"\n## {meta['fetched_at'][:10]}" + (f" · коммит {commit}" if commit else "")]
    if not old:
        lines.append("- Первый сбор.")
    if spec and old_spec and spec != old_spec:
        d = changed_sections(old_spec, spec)
        for k, label in (("added", "Разделы добавлены"), ("changed", "Разделы изменены"),
                         ("removed", "Разделы удалены")):
            if d[k]:
                lines.append(f"- {label}: " + ", ".join(f"«{x}»" for x in d[k]))
    op = (old.get("completeness") or {}).get("percent")
    if old and op != meta["completeness"]["percent"]:
        lines.append(f"- Готовность ТЗ: {op or 0}% → {meta['completeness']['percent']}%")
    for k, label in (("new", "новый"), ("changed", "изменён"), ("removed", "удалён в источнике")):
        for f in changes[k]:
            lines.append(f"- {f}: {label}")
    if meta["masked"]:
        lines.append("- Скрыто при сборе: " + human_masked(meta["masked"]))
    with path.open("a", encoding="utf-8") as f:
        f.write(head + "\n".join(lines) + "\n")


def human_masked(m: dict) -> str:
    names = {"secret": "ключей/паролей", "phone": "телефонов", "iin": "ИИН", "email": "адресов почты"}
    return ", ".join(f"{names.get(k, k)} — {v}" for k, v in m.items() if v)


def ensure_gitignore(out: Path):
    gi = out / ".gitignore"
    text = gi.read_text(encoding="utf-8") if gi.exists() else ""
    if CACHE_DIR + "/" not in text.splitlines():
        gi.write_text(text + ("" if not text or text.endswith("\n") else "\n") + CACHE_DIR + "/\n",
                      encoding="utf-8")


def cmd_collect(a) -> int:
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    ok, msg = check_private(out, a.repo, a.allow_public)
    print(msg, file=sys.stderr)
    if not ok:
        return 2
    now = now_utc(a.now)
    roster = load_roster(a.roster)
    assign_slugs(roster)
    cache_path = out / CACHE_DIR / "cache.json"
    cache = read_json(cache_path)
    gh = None
    if not a.local:
        gh = GitHub()
        print(f"GitHub: доступ — {gh.mode()}", file=sys.stderr)
    reports, errors = [], []
    for p in roster:
        try:
            if a.local:
                path = find_local(Path(a.local), p)
                if not path:
                    raise ApiError("нет локальной папки репозитория")
                src = LocalRepo(path, p["branch"], p["path"])
            else:
                if not p["owner"]:
                    raise ApiError("для GitHub нужен адрес owner/name")
                src = GitHubRepo(gh, p["owner"], p["repo"], p["branch"], p["path"], cache)
            reports.append(collect_one(p, src, out, now, a.on_secret))
        except ApiError as e:
            errors.append((p, str(e)))
            mark_error(out, p, str(e), now)
            print(f"  {p['name']} ({p['id']}): {e}", file=sys.stderr)
    if gh:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
        ensure_gitignore(out)
    build_index(out)
    print(run_report(reports, errors, out, a.since))
    return 0


def mark_error(out: Path, p: dict, err: str, now: dt.datetime):
    """Нет доступа: прошлые копии не трогаем, в meta.json — пометка."""
    path = out / p["dir"] / "meta.json"
    meta = read_json(path) or {"id": p["id"], "files": {}, "found": [], "missing": [],
                               "completeness": {"percent": 0}, "source": {
                                   "repo": f"{p['owner']}/{p['repo']}" if p["owner"] else p["repo"],
                                   "branch": p["branch"], "path": p["path"], "url": "", "commit": None}}
    meta.update({k: p[k] for k in ("name", "company", "department", "mode", "cohort")})
    if meta.get("error") != err:
        meta["error"] = err
        meta["error_since"] = iso(now)
    write_if_changed(path, dump(meta))


def run_report(reports: list, errors: list, out: Path, since: str | None) -> str:
    lines = [f"Собрано участников: {len(reports)}, без доступа: {len(errors)}."]
    changed = [r for r in reports if any(r["changes"].values())]
    if since:
        lines.append(changes_since(out, since))
    elif changed:
        lines.append("Что изменилось в этом запуске:")
        for r in changed:
            parts = []
            for k, label in (("new", "новые"), ("changed", "изменены"), ("removed", "удалены")):
                if r["changes"][k]:
                    parts.append(f"{label}: {', '.join(r['changes'][k])}")
            pc = f"готовность ТЗ {r['old_percent'] or 0}% → {r['percent']}%" if r["spec_changed"] else ""
            lines.append(f"  • {r['name']} — " + "; ".join(parts + ([pc] if pc else [])))
    else:
        lines.append("Изменений нет.")
    masked = [r for r in reports if r["masked"]]
    if masked:
        lines.append("Скрыто в копиях (ключи и персональные данные):")
        for r in masked:
            lines.append(f"  • {r['name']}: {human_masked(r['masked'])}")
    for r in reports:
        for s in r["skipped"]:
            lines.append(f"  ! {r['name']}: {s['file']} пропущен — {s['reason']}")
    nospec = [r["name"] for r in reports if "SPEC.md" in r["missing"]]
    if nospec:
        lines.append("Нет SPEC.md: " + ", ".join(nospec))
    for p, e in errors:
        lines.append(f"  ✗ {p['name']}: {e}")
    lines.append(f"Оглавление: {out / 'README.md'} · боли: PAINS.md · показатели: METRICS.md")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Оглавление: README.md, PAINS.md, METRICS.md, summary.json
# ---------------------------------------------------------------------------

def load_all(out: Path) -> list[dict]:
    rows = []
    for mp in sorted(out.glob("*/*/*/meta.json")):
        m = read_json(mp)
        if not m.get("id"):
            continue
        m["dir"] = mp.parent.relative_to(out).as_posix()
        spec_path = mp.parent / "SPEC.md"
        if spec_path.exists():           # пересчитать из копии — так `index` подхватывает новые правила
            spec = spec_path.read_text(encoding="utf-8")
            sj = mp.parent / "airl.service.json"
            m.update({k: v for k, v in extract(spec).items()})
            m["completeness"] = completeness(spec)
            m["metrics"] = metrics_declared(spec, sj.read_text(encoding="utf-8") if sj.exists() else None)
        else:
            m.setdefault("pain_text", "")
        rows.append(m)
    rows.sort(key=lambda r: ((r.get("cohort") or "").lower(), (r.get("company") or "").lower(),
                             (r.get("name") or "").lower()))
    return rows


def cell(s) -> str:
    return re.sub(r"\s+", " ", str(s if s is not None else "")).replace("|", "\\|").strip() or "—"


MODE_LABEL = {"solo": "свой продукт", "hub": "хаб", "airl": "команда AIRL"}
NOTE = ("<!-- Создано airl-collect. Не правьте руками: файл пересобирается при каждом сборе. -->\n")
PRIVATE_NOTE = ("> Закрытый репозиторий AIRL. Здесь ТЗ участников и данные их клиентов. "
                "Не делайте его публичным, не пересылайте файлы за пределы команды AIRL.\n")


def build_index(out: Path) -> dict:
    rows = load_all(out)
    with_spec = [r for r in rows if "SPEC.md" in (r.get("found") or [])]
    avg = round(sum(r["completeness"]["percent"] for r in with_spec) / len(with_spec)) if with_spec else 0
    last = max([r.get("fetched_at") or "" for r in rows] or [""])
    clusters = cluster_pains(with_spec)
    metrics: dict[str, dict] = {}
    for r in rows:
        for mid in r.get("metrics") or []:
            e = metrics.setdefault(mid, {"participants": [], "companies": set()})
            e["participants"].append(r["name"])
            e["companies"].add(r.get("company") or "—")

    # README.md
    L = [NOTE, "# Коллекция ТЗ участников AIRL\n", PRIVATE_NOTE,
         f"Участников: {len(rows)} · с SPEC.md: {len(with_spec)} · средняя готовность ТЗ: {avg}% · "
         f"последнее изменение: {last[:10] or '—'}\n",
         "Ещё: [PAINS.md](PAINS.md) — повторяющиеся боли · [METRICS.md](METRICS.md) — показатели · "
         "[summary.json](summary.json) — то же для программ.\n",
         "Готовность ТЗ — доля заполненных разделов 1–12 (70%) плюс боль в цифрах, метрика «было → стало» "
         "и критерии готовности (по 10%). Строки со скобками `[...]` из шаблона не засчитываются.\n"]
    cohorts: dict[str, list] = {}
    for r in rows:
        cohorts.setdefault(r.get("cohort") or "Без потока", []).append(r)
    for name, items in cohorts.items():
        L.append(f"## Поток {name}\n")
        L.append("| Участник | Компания | Отдел | Режим | Продукт | Главная боль | Метрика | Готовность ТЗ | "
                 "Обновлено | Папка | Источник |")
        L.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for r in items:
            src = r.get("source") or {}
            if r.get("error"):
                pct = "нет доступа"
            elif "SPEC.md" not in (r.get("found") or []):
                pct = "нет SPEC.md"
            else:
                pct = f"{r['completeness']['percent']}%"
            link = f"[{src.get('repo')}]({src['url']})" if src.get("url") else cell(src.get("repo"))
            L.append("| " + " | ".join([
                cell(r.get("name")), cell(r.get("company")), cell(r.get("department")),
                MODE_LABEL.get(r.get("mode"), cell(r.get("mode"))), cell(r.get("product")),
                cell(r.get("pain")), cell(r.get("metric")), pct,
                cell((r.get("spec_changed_at") or r.get("fetched_at") or "")[:10]),
                f"[открыть]({r['dir']}/)", link]) + " |")
        L.append("")
    write_if_changed(out / "README.md", "\n".join(L).rstrip() + "\n")

    # PAINS.md
    P = [NOTE, "# Повторяющиеся боли\n", PRIVATE_NOTE,
         "Похожие боли ищутся по общим словам в разделе 1 ТЗ («Сейчас» и «Цена боли»), без ИИ: "
         "два участника в одной группе, если у них хотя бы два общих ключевых слова. "
         "Это подсказка для разбора глазами, а не вывод.\n",
         "Правило библиотеки модулей: модуль появляется, когда одна и та же боль повторилась "
         "минимум у двух клиентов. Группы, где 2 и больше компаний, отмечены «кандидат в модуль».\n",
         "## Кандидаты в модуль\n"]
    cand = [c for c in clusters if c["module_candidate"]]
    if not cand:
        P.append("Пока нет: похожие боли у двух разных компаний не найдены.\n")
    for c in cand:
        P.append(f"### {' · '.join(c['keywords']) or 'без общих слов'} — повторяется у "
                 f"{c['n_companies']} компаний → кандидат в модуль\n")
        for m in c["participants"]:
            P.append(f"- **{cell(m['company'])}**, {cell(m['department'])} — {cell(m['name'])}: "
                     f"{cell(m['pain'])} ([ТЗ]({m['dir']}/SPEC.md))")
        P.append("")
    inner = [c for c in clusters if not c["module_candidate"]]
    if inner:
        P.append("## Похожие боли внутри одной компании\n")
        for c in inner:
            P.append(f"### {' · '.join(c['keywords'])} — {c['companies'][0]}\n")
            for m in c["participants"]:
                P.append(f"- {cell(m['department'])} — {cell(m['name'])}: {cell(m['pain'])}")
            P.append("")
    words: dict[str, dict] = {}
    for r in with_spec:
        for k in keywords(r.get("pain_text") or ""):
            e = words.setdefault(k, {"companies": set(), "n": 0, "forms": {}})
            e["companies"].add(r.get("company") or "—")
            e["n"] += 1
        for w in re.findall(r"[A-Za-zА-Яа-яЁё]{4,}", r.get("pain_text") or ""):
            s = stem(w)
            if s in words:
                words[s]["forms"][w.lower()] = words[s]["forms"].get(w.lower(), 0) + 1
    freq = sorted([(k, v) for k, v in words.items() if len(v["companies"]) >= 2],
                  key=lambda kv: (-len(kv[1]["companies"]), -kv[1]["n"], kv[0]))
    P.append("## Частые слова в болях (у 2 и больше компаний)\n")
    if freq:
        P.append("| Слово | Компаний | Участников |")
        P.append("|---|---|---|")
        for k, v in freq[:30]:
            form = max(v["forms"].items(), key=lambda kv: kv[1])[0] if v["forms"] else k
            P.append(f"| {form} | {len(v['companies'])} | {v['n']} |")
    else:
        P.append("Пока нет.")
    P.append("\n## Боли по отделам\n")
    deps: dict[str, list] = {}
    for r in with_spec:
        deps.setdefault((r.get("department") or "без отдела").strip().lower(), []).append(r)
    for d in sorted(deps):
        P.append(f"### {d}\n")
        P.append("| Участник | Компания | Боль | Метрика |")
        P.append("|---|---|---|---|")
        for r in deps[d]:
            P.append(f"| {cell(r['name'])} | {cell(r.get('company'))} | {cell(r.get('pain'))} | "
                     f"{cell(r.get('metric'))} |")
        P.append("")
    write_if_changed(out / "PAINS.md", "\n".join(P).rstrip() + "\n")

    # METRICS.md
    M = [NOTE, "# Показатели во всех ТЗ\n", PRIVATE_NOTE,
         "Откуда: `hub.metrics` в airl.service.json, первая колонка раздела 6 SPEC.md и раздела 7 "
         "в ТЗ сервиса отдела («Что отдаёт в хаб»). "
         "Один и тот же показатель у нескольких компаний — повод сделать его общим в модуле.\n"]
    if metrics:
        M.append("| Показатель | Участников | Компаний | У кого |")
        M.append("|---|---|---|---|")
        for mid, e in sorted(metrics.items(), key=lambda kv: (-len(kv[1]["participants"]), kv[0])):
            M.append(f"| `{cell(mid)}` | {len(e['participants'])} | {len(e['companies'])} | "
                     f"{cell(', '.join(e['participants']))} |")
    else:
        M.append("Пока ни в одном ТЗ нет заполненных показателей.")
    write_if_changed(out / "METRICS.md", "\n".join(M).rstrip() + "\n")

    summary = {
        "generator": UA, "last_change": last or None, "participants": [
            {k: r.get(k) for k in ("id", "name", "company", "department", "mode", "cohort", "dir", "product",
                                   "pain", "metric", "metrics", "found", "missing", "error", "fetched_at",
                                   "spec_changed_at")}
            | {"completeness": (r.get("completeness") or {}).get("percent", 0),
               "source": r.get("source")} for r in rows],
        "pain_clusters": clusters,
        "metrics": {k: {"participants": v["participants"], "companies": sorted(v["companies"])}
                    for k, v in sorted(metrics.items())},
    }
    write_if_changed(out / "summary.json", dump(summary))
    return summary


def changes_since(out: Path, since: str) -> str:
    try:
        t0 = now_utc(since if "T" in since else since + "T00:00:00Z")
    except ValueError:
        return f"Не понял дату {since!r}: нужно ГГГГ-ММ-ДД"
    rows = [r for r in load_all(out) if r.get("spec_changed_at") and now_utc(r["spec_changed_at"]) >= t0]
    if not rows:
        return f"С {since[:10]} ни одно ТЗ не менялось."
    lines = [f"ТЗ, изменённые с {since[:10]}: {len(rows)}"]
    for r in sorted(rows, key=lambda r: r["spec_changed_at"], reverse=True):
        lines.append(f"  • {r['spec_changed_at'][:10]} {r['name']} ({r.get('company') or '—'}) — "
                     f"готовность {r['completeness']['percent']}%, история: {r['dir']}/CHANGELOG.md")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Коллекция ТЗ участников AIRL")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect", help="собрать документы и пересобрать оглавление")
    c.add_argument("--roster", required=True, help="тот же список, что у /airl-progress")
    c.add_argument("--out", required=True, help="рабочая копия репозитория коллекции")
    c.add_argument("--local", help="папка с локальными клонами вместо GitHub")
    c.add_argument("--since", help="в итоге показать ТЗ, изменённые с этой даты (ГГГГ-ММ-ДД)")
    c.add_argument("--repo", help="owner/name репозитория коллекции (иначе — из remote origin)")
    c.add_argument("--allow-public", action="store_true", help="разрешить запись в публичный репозиторий")
    c.add_argument("--on-secret", choices=["mask", "skip"], default="mask",
                   help="нашли ключ или пароль: скрыть (по умолчанию) или не брать файл")
    c.add_argument("--now", help="время сбора ISO (для тестов)")
    i = sub.add_parser("index", help="только пересобрать README.md, PAINS.md, METRICS.md, summary.json")
    i.add_argument("--out", required=True)
    ch = sub.add_parser("changes", help="чьи ТЗ менялись с даты")
    ch.add_argument("--out", required=True)
    ch.add_argument("--since", help="ГГГГ-ММ-ДД, по умолчанию — 7 дней назад")
    a = ap.parse_args(argv)
    if a.cmd == "collect":
        return cmd_collect(a)
    out = Path(a.out)
    if not out.is_dir():
        print(f"Нет папки {out}", file=sys.stderr)
        return 2
    if a.cmd == "index":
        s = build_index(out)
        print(f"Оглавление пересобрано: участников {len(s['participants'])}.")
        return 0
    since = a.since or (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=7)).strftime("%Y-%m-%d")
    print(changes_since(out, since))
    return 0


if __name__ == "__main__":
    sys.exit(main())
