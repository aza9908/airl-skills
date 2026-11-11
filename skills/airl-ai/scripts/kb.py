#!/usr/bin/env python3
"""Ответы по базе знаний компании — только из утверждённых документов, со ссылкой на источник.

  DATABASE_URL=... python3 kb.py index --docs ai/kb            # загрузить документы
  AI_READER_DATABASE_URL=... python3 kb.py ask --role staff_sales "Как оформить возврат?"

Документы — файлы .md и .txt. В начале файла — шапка:

  ---
  title: Регламент возврата товара
  version: 3
  url: https://.../vozvrat
  roles: [all]            # или [ceo, head_sales, staff_sales]
  ---

Поиск — полнотекстовый поиск PostgreSQL (без внешних сервисов, данные не покидают
сервер до вопроса). В модель уходят только найденные фрагменты, доступные роли
спрашивающего. Модель отвечает только по ним со ссылками [D1]; нет ссылки или есть
число, которого нет во фрагментах, — ответ не показывается. Ничего не найдено —
«в утверждённых документах ответа нет», модель не вызывается.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import airl_ai_common as ai  # noqa: E402

NOT_FOUND = "В утверждённых документах ответа нет. Спросите ответственного за регламент."

SCHEMA_SQL = """
CREATE SCHEMA IF NOT EXISTS ai;
CREATE TABLE IF NOT EXISTS ai.kb_docs (
    doc_id     text PRIMARY KEY,
    title      text NOT NULL,
    version    text NOT NULL,
    url        text,
    roles      text[] NOT NULL,
    lang       regconfig NOT NULL DEFAULT 'russian',
    indexed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS ai.kb_chunks (
    doc_id   text NOT NULL REFERENCES ai.kb_docs (doc_id) ON DELETE CASCADE,
    chunk_no int  NOT NULL,
    heading  text,
    body     text NOT NULL,
    lang     regconfig NOT NULL DEFAULT 'russian',
    tsv      tsvector GENERATED ALWAYS AS (to_tsvector(lang, coalesce(heading, '') || ' ' || body)) STORED,
    PRIMARY KEY (doc_id, chunk_no)
);
CREATE INDEX IF NOT EXISTS kb_chunks_tsv_idx ON ai.kb_chunks USING gin (tsv);
"""

SEARCH_SQL = """
WITH q AS (
    SELECT to_tsquery(%(lang)s::regconfig,
             NULLIF(replace(plainto_tsquery(%(lang)s::regconfig, %(q)s)::text, ' & ', ' | '), '')) AS tsq
)
SELECT c.doc_id, d.title, d.version, d.url, c.chunk_no, c.heading, c.body,
       ts_rank(c.tsv, q.tsq) AS rank
FROM ai.kb_chunks c
JOIN ai.kb_docs d USING (doc_id)
CROSS JOIN q
WHERE q.tsq IS NOT NULL
  AND c.tsv @@ q.tsq
  AND ('all' = ANY (d.roles) OR %(role)s = ANY (d.roles))
ORDER BY rank DESC
LIMIT %(k)s
"""

SYSTEM = """Ты отвечаешь сотруднику компании «{company}» по её утверждённым документам.

Правила:
- Отвечай только по фрагментам из блока DOCS. Ничего не добавляй от себя и из общих знаний.
- После каждого утверждения ставь ссылку на фрагмент, например [D2].
- Если во фрагментах нет ответа — ответь ровно: «{not_found}»
- Отвечай на языке вопроса, коротко: 1–5 предложений или короткий список шагов."""


def parse_doc(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    meta = {}
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
        text = text[m.end():]
    roles = [r.strip() for r in meta.get("roles", "[all]").strip("[]").split(",") if r.strip()]
    return {"doc_id": os.path.splitext(os.path.basename(path))[0],
            "title": meta.get("title") or os.path.basename(path),
            "version": meta.get("version", "1"), "url": meta.get("url"),
            "roles": roles or ["all"], "lang": meta.get("lang", "russian"), "text": text}


def chunks(text, max_chars=1200):
    """Режем по заголовкам, длинные разделы — по абзацам."""
    parts, heading, buf = [], None, []
    for line in text.splitlines():
        if re.match(r"^#{1,4}\s", line):
            if "".join(buf).strip():
                parts.append((heading, "\n".join(buf).strip()))
            heading, buf = line.lstrip("#").strip(), []
        else:
            buf.append(line)
    if "".join(buf).strip():
        parts.append((heading, "\n".join(buf).strip()))
    out = []
    for h, body in parts:
        while len(body) > max_chars:
            cut = body.rfind("\n\n", 0, max_chars)
            cut = cut if cut > max_chars // 3 else max_chars
            out.append((h, body[:cut].strip()))
            body = body[cut:].strip()
        if body:
            out.append((h, body))
    return out


def index(conn, folder):
    conn.execute(SCHEMA_SQL)
    n_docs = n_chunks = 0
    for name in sorted(os.listdir(folder)):
        if not name.endswith((".md", ".txt")):
            continue
        d = parse_doc(os.path.join(folder, name))
        with conn.transaction():
            conn.execute("DELETE FROM ai.kb_docs WHERE doc_id = %s", (d["doc_id"],))
            conn.execute("INSERT INTO ai.kb_docs (doc_id, title, version, url, roles, lang) VALUES (%s, %s, %s, %s, %s, %s)",
                         (d["doc_id"], d["title"], d["version"], d["url"], d["roles"], d["lang"]))
            for i, (h, body) in enumerate(chunks(d["text"]), 1):
                conn.execute("INSERT INTO ai.kb_chunks (doc_id, chunk_no, heading, body, lang) VALUES (%s, %s, %s, %s, %s)",
                             (d["doc_id"], i, h, body, d["lang"]))
                n_chunks += 1
        n_docs += 1
    return n_docs, n_chunks


def answer(client, conf, question, found):
    """found — фрагменты из поиска. Возвращает (ответ, источники, проблема)."""
    if not found:
        return NOT_FOUND, [], None
    docs = []
    for i, r in enumerate(found, 1):
        docs.append(f"[D{i}] {r['title']} (версия {r['version']}) — {r.get('heading') or ''}\n{r['body']}")
    system = SYSTEM.format(company=conf["company"], not_found=NOT_FOUND)
    resp = ai.ask_model(client, model=conf.get("model", ai.DEFAULT_MODEL), system=system,
                        messages=[{"role": "user", "content": "DOCS:\n" + "\n\n".join(docs) +
                                   "\n\nВопрос: " + question}],
                        effort=conf.get("effort", "medium"), max_tokens=4000)
    if resp.stop_reason == "refusal":
        return None, [], "модель отказала"
    text = ai.text_of(resp)
    if text.strip() == NOT_FOUND:
        return NOT_FOUND, [], None
    cited = sorted({int(x) for x in re.findall(r"\[D(\d+)\]", text) if 0 < int(x) <= len(found)})
    if not cited:
        return None, [], "в ответе нет ссылок на документы"
    bad = ai.check_numbers(text, ai.allowed_numbers([question] + [r["body"] for r in found] +
                                                    [r["title"] for r in found] + [r["version"] for r in found]))
    if bad:
        return None, [], "в ответе числа, которых нет в документах: " + ", ".join(bad)
    sources = [{"id": f"D{i}", "title": found[i - 1]["title"], "version": found[i - 1]["version"],
                "url": found[i - 1].get("url")} for i in cited]
    return text, sources, None


def main():
    p = argparse.ArgumentParser(description="База знаний: индекс и вопросы")
    sub = p.add_subparsers(dest="cmd", required=True)
    pi = sub.add_parser("index")
    pi.add_argument("--docs", required=True)
    pa = sub.add_parser("ask")
    pa.add_argument("--config", required=True)
    pa.add_argument("--role", required=True)
    pa.add_argument("--lang", default="russian", help="russian или simple (для узбекского и казахского)")
    pa.add_argument("question")
    a = p.parse_args()

    if a.cmd == "index":
        import psycopg
        dsn = os.environ.get("DATABASE_URL")
        if not dsn:
            print("Задайте DATABASE_URL (пользователь с правом записи в схему ai)", file=sys.stderr)
            return 2
        with psycopg.connect(dsn, autocommit=True) as conn:
            n_docs, n_chunks = index(conn, a.docs)
        print(f"✔ документов: {n_docs}, фрагментов: {n_chunks}")
        return 0

    conf = ai.load_config(a.config)
    dsn = os.environ.get("AI_READER_DATABASE_URL")
    if not dsn:
        print("Задайте AI_READER_DATABASE_URL (пользователь только на чтение)", file=sys.stderr)
        return 2
    with ai.connect_readonly(dsn) as conn:
        found = ai.fetch(conn, SEARCH_SQL, {"q": a.question, "role": a.role, "lang": a.lang, "k": 5})
    text, sources, problem = answer(ai.make_client() if found else None, conf, a.question, found)
    if text is None:
        print("Не получилось ответить надёжно: " + problem)
        return 1
    print(text)
    for s in sources:
        print(f"[{s['id']}] {s['title']}, версия {s['version']}" + (f" — {s['url']}" if s["url"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
