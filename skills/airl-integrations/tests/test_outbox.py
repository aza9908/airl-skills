#!/usr/bin/env python3
"""Проверка templates/outbox.sql и scripts/worker.py на тестовой базе PostgreSQL 16.

  python3 tests/test_outbox.py
  DATABASE_URL=postgresql://... python3 tests/test_outbox.py

По умолчанию — тестовая база AIRL. Не запускать на боевой базе: создаёт и удаляет
схему scratch_int_<pid>. Нужны psql и psycopg 3 (pip install "psycopg[binary]").

Что проверяется:
  1. установка дважды подряд без ошибок;
  2. повторный int_enqueue с тем же ключом — одна запись; тот же ключ с другим
     содержимым — ошибка;
  3. два параллельных забирающих (два соединения) не получают одну запись;
     четыре потока до опустошения очереди — каждая запись выдана ровно раз;
  4. пауза перед повтором растёт; после max_attempts — dead и int_dead_letter;
     неповторяемая ошибка — сразу dead;
  5. int_replay возвращает запись в работу с тем же ключом;
  6. ordering_key: следующая запись цепочки ждёт предыдущую;
  7. истёкшая аренда: запись забирает другой воркер, старый не может её отметить;
  8. int_release возвращает запись без штрафа;
  9. inbox: дубль события — одна запись; поддельная подпись не занимает event_id;
 10. worker.py против локального HTTP-сервера: первый ответ 500, второй 200 —
     Idempotency-Key одинаковый в обеих попытках; 400 — dead; в логах нет тела
     запроса и токена;
 11. SIGTERM: воркер доделывает текущую запись, остальные возвращает в очередь.

Код выхода: 0 — всё прошло, 1 — есть провалы, 3 — база недоступна.
"""
import json
import os
import random
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
from psycopg.rows import dict_row

DSN = os.environ.get("DATABASE_URL",
                     "postgresql://admin@/postgres?host=/var/lib/postgresql/airl-test&port=5546")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_FILE = os.path.join(ROOT, "templates", "outbox.sql")
WORKER = os.path.join(ROOT, "scripts", "worker.py")
SCHEMA = f"scratch_int_{os.getpid()}_{random.randint(1000, 9999)}"
MARKER = "PII-MARKER-7f3a"          # не должен попасть в логи воркера
TOKEN = "tok-SECRET-9b1c"           # не должен попасть в логи воркера

failures = []


def check(name, ok, detail=""):
    print(("✔ " if ok else "✖ ") + name + ("" if ok or not detail else f" — {detail}"))
    if not ok:
        failures.append(name)


def connect(autocommit=True):
    return psycopg.connect(DSN, autocommit=autocommit, options=f"-c search_path={SCHEMA}")


def install():
    script = f"SET client_min_messages TO warning;\nSET search_path TO {SCHEMA};\n\\i {SQL_FILE}\n"
    return subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=script,
                          text=True, capture_output=True)


def one(conn, sql, params=()):
    return conn.execute(sql, params).fetchone()[0]


def due_now(conn, ids):
    conn.execute("UPDATE int_outbox SET next_attempt_at = now() WHERE id = ANY(%s)", (list(ids),))


# ───────────────────────────── проверки SQL ─────────────────────────────

def test_install_twice():
    r1, r2 = install(), install()
    check("установка outbox.sql дважды подряд", r1.returncode == 0 and r2.returncode == 0,
          (r1.stderr + r2.stderr).strip()[-300:])
    with connect() as c:
        n = one(c, "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
                   "WHERE n.nspname = %s AND p.proname LIKE 'int\\_%%' "
                   "AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%%')",
                (SCHEMA,))
        check("у каждой функции зафиксирован search_path", n == 0, f"без search_path: {n}")


def test_enqueue_dedup():
    with connect() as c:
        a = one(c, "SELECT int_enqueue('dup', 'order.create', 'dup:1', '{\"n\": 1}')")
        b = one(c, "SELECT int_enqueue('dup', 'order.create', 'dup:1', '{\"n\": 1}')")
        n = one(c, "SELECT count(*) FROM int_outbox WHERE idempotency_key = 'dup:1'")
        check("повторный int_enqueue — та же запись, одна строка", a == b and n == 1, f"{a} {b} {n}")
        try:
            c.execute("SELECT int_enqueue('dup', 'order.create', 'dup:1', '{\"n\": 2}')")
            check("тот же ключ с другим содержимым — ошибка", False, "ошибки не было")
        except psycopg.errors.UniqueViolation:
            check("тот же ключ с другим содержимым — ошибка", True)


def test_concurrent_claim():
    with connect() as c:
        for i in range(20):
            c.execute("SELECT int_enqueue('conc', 'op', %s, %s)", (f"conc:{i}", json.dumps({"i": i})))
    a, b = connect(autocommit=False), connect(autocommit=False)
    try:
        ids_a = [r[0] for r in a.execute("SELECT id FROM int_claim_batch('conc', 5, 'A')").fetchall()]
        ids_b = [r[0] for r in b.execute("SELECT id FROM int_claim_batch('conc', 5, 'B')").fetchall()]
        check("два соединения в открытых транзакциях получают разные записи",
              len(ids_a) == 5 and len(ids_b) == 5 and not set(ids_a) & set(ids_b), f"A={ids_a} B={ids_b}")
        a.commit()
        b.commit()
    finally:
        a.close()
        b.close()

    claimed, lock = [], threading.Lock()

    def drain(name):
        with connect() as c:
            while True:
                rows = c.execute("SELECT id FROM int_claim_batch('conc', 2, %s)", (name,)).fetchall()
                if not rows:
                    return
                for (rid,) in rows:
                    with lock:
                        claimed.append(rid)
                    c.execute("SELECT int_mark_done(%s, %s)", (rid, name))

    threads = [threading.Thread(target=drain, args=(f"T{i}",)) for i in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    check("четыре потока: 10 оставшихся записей выданы ровно по разу",
          len(claimed) == 10 and len(set(claimed)) == 10, f"выдано {len(claimed)}, уникальных {len(set(claimed))}")


def test_backoff_dead_replay():
    with connect() as c:
        jid = one(c, "SELECT int_enqueue('bk', 'op', 'bk:1', '{}', NULL, 3)")
        delays = []
        for attempt in (1, 2):
            due_now(c, [jid])
            got = c.execute("SELECT id, attempts FROM int_claim_batch('bk', 1, 'w')").fetchone()
            st = one(c, "SELECT int_mark_failed(%s, 'HTTP 503', true, 'w', NULL, interval '10 seconds')", (jid,))
            d = one(c, "SELECT extract(epoch FROM next_attempt_at - updated_at) FROM int_outbox WHERE id = %s", (jid,))
            delays.append(float(d))
            check(f"попытка {attempt}: статус retry", st == "retry" and got[1] == attempt, f"{st} {got}")
        check("пауза перед повтором растёт", 8 <= delays[0] <= 12 and 16 <= delays[1] <= 24
              and delays[1] > delays[0], f"паузы {delays}")
        due_now(c, [jid])
        c.execute("SELECT int_claim_batch('bk', 1, 'w')")
        st = one(c, "SELECT int_mark_failed(%s, 'HTTP 503', true, 'w')", (jid,))
        dl = one(c, "SELECT count(*) FROM int_dead_letter WHERE queue = 'outbox' AND id = %s", (jid,))
        check("после max_attempts — dead и запись в int_dead_letter", st == "dead" and dl == 1, f"{st} {dl}")
        due_now(c, [jid])
        again = c.execute("SELECT count(*) FROM int_claim_batch('bk', 1, 'w')").fetchone()[0]
        check("dead не выдаётся воркеру", again == 0)

        ok = one(c, "SELECT int_replay(%s, 'test')", (jid,))
        row = c.execute("SELECT status, attempts, replay_count, idempotency_key FROM int_outbox WHERE id = %s",
                        (jid,)).fetchone()
        check("int_replay: pending, попытки с нуля, тот же ключ",
              ok and row == ("pending", 0, 1, "bk:1"), str(row))
        got = c.execute("SELECT id FROM int_claim_batch('bk', 1, 'w')").fetchone()
        done = one(c, "SELECT int_mark_done(%s, 'w', 'ext-9')", (jid,))
        check("после replay запись уходит и отмечается done", got and got[0] == jid and done)

        pid = one(c, "SELECT int_enqueue('bk', 'op', 'bk:2', '{}')")
        c.execute("SELECT int_claim_batch('bk', 1, 'w')")
        st = one(c, "SELECT int_mark_failed(%s, 'HTTP 400', false, 'w')", (pid,))
        check("неповторяемая ошибка — сразу dead", st == "dead")
        n = one(c, "SELECT int_replay_target('bk', 'test')")
        check("int_replay_target переигрывает все dead цели", n == 1)
        logged = one(c, "SELECT count(*) FROM int_attempt_log WHERE target = 'bk'")
        check("каждая попытка записана в int_attempt_log", logged == 5, f"записей {logged}")  # bk:1 — 3 неудачи и успех, bk:2 — 1


def test_ordering_lease_release():
    with connect() as c:
        a1 = one(c, "SELECT int_enqueue('ord', 'op', 'ord:1', '{}', 'order-77')")
        a2 = one(c, "SELECT int_enqueue('ord', 'op', 'ord:2', '{}', 'order-77')")
        b1 = one(c, "SELECT int_enqueue('ord', 'op', 'ord:3', '{}', 'order-78')")
        got = sorted(r[0] for r in c.execute("SELECT id FROM int_claim_batch('ord', 10, 'w')").fetchall())
        check("из цепочки ordering_key выдаётся только первая запись", got == sorted([a1, b1]), str(got))
        c.execute("SELECT int_mark_done(%s, 'w')", (a1,))
        c.execute("SELECT int_mark_done(%s, 'w')", (b1,))
        got = [r[0] for r in c.execute("SELECT id FROM int_claim_batch('ord', 10, 'w')").fetchall()]
        check("после done следующая запись цепочки выдаётся", got == [a2], str(got))
        c.execute("SELECT int_mark_done(%s, 'w')", (a2,))

        lid = one(c, "SELECT int_enqueue('lease', 'op', 'lease:1', '{}')")
        c.execute("SELECT int_claim_batch('lease', 1, 'old', interval '0 seconds')")
        time.sleep(0.05)
        got = c.execute("SELECT id, attempts FROM int_claim_batch('lease', 1, 'new')").fetchone()
        stale = one(c, "SELECT int_mark_done(%s, 'old')", (lid,))
        fresh = one(c, "SELECT int_mark_done(%s, 'new')", (lid,))
        check("истёкшая аренда: запись забирает другой воркер, попытка засчитана",
              got == (lid, 2), str(got))
        check("старый воркер не может отметить чужую запись", stale is False and fresh is True, f"{stale} {fresh}")

        rid = one(c, "SELECT int_enqueue('rel', 'op', 'rel:1', '{}')")
        c.execute("SELECT int_claim_batch('rel', 1, 'w')")
        ok = one(c, "SELECT int_release(%s, 'w')", (rid,))
        row = c.execute("SELECT status, attempts FROM int_outbox WHERE id = %s", (rid,)).fetchone()
        check("int_release возвращает запись без штрафа", ok and row == ("pending", 0), str(row))


def test_inbox():
    with connect() as c:
        r1 = c.execute("SELECT * FROM int_inbox_receive('tg', '1001', '{\"update_id\":1001}', true)").fetchone()
        r2 = c.execute("SELECT * FROM int_inbox_receive('tg', '1001', '{\"update_id\":1001}', true)").fetchone()
        n = one(c, "SELECT count(*) FROM int_inbox WHERE source = 'tg' AND event_id = '1001'")
        check("inbox: дубль события — одна запись, второй раз is_new = false",
              r1[1] is True and r2 == (r1[0], False) and n == 1, f"{r1} {r2} {n}")
        f = c.execute("SELECT * FROM int_inbox_receive('pay', 'tx-5', 'forged', false)").fetchone()
        g = c.execute("SELECT * FROM int_inbox_receive('pay', 'tx-5', 'real', true)").fetchone()
        st = one(c, "SELECT status FROM int_inbox WHERE id = %s", (f[0],))
        check("поддельная подпись не занимает event_id настоящего события",
              f[1] is False and st == "rejected" and g[1] is True, f"{f} {g} {st}")
        got = [r[0] for r in c.execute("SELECT id FROM int_inbox_claim('pay', 10, 'w')").fetchall()]
        check("в обработку идёт только событие с верной подписью", got == [g[0]], str(got))
        st = one(c, "SELECT int_inbox_mark_failed(%s, 'parse error', false, 'w')", (g[0],))
        rep = one(c, "SELECT int_inbox_replay(%s)", (g[0],))
        c.execute("SELECT int_inbox_claim('pay', 10, 'w')")
        done = one(c, "SELECT int_inbox_mark_done(%s, 'w')", (g[0],))
        check("inbox: dead → replay → done", st == "dead" and rep and done)
        health = c.execute("SELECT count(*) FROM m_int_health WHERE status NOT IN ('ok','warning','danger')").fetchone()[0]
        check("m_int_health в формате показателей AIRL", health == 0)


# ───────────────────────────── worker.py против HTTP-заглушки ─────────────────────────────

class Mock(BaseHTTPRequestHandler):
    seen = []            # (path, Idempotency-Key, Authorization)
    counts = {}
    lock = threading.Lock()
    first_request = threading.Event()

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        key = self.headers.get("Idempotency-Key")
        with Mock.lock:
            Mock.seen.append((self.path, key, self.headers.get("Authorization"), body))
            Mock.counts[key] = Mock.counts.get(key, 0) + 1
            n = Mock.counts[key]
        Mock.first_request.set()
        if self.path.startswith("/flaky"):
            code, resp = (500, b'{"error":"boom"}') if n == 1 else (200, b'{"id":"ext-1"}')
        elif self.path.startswith("/bad"):
            code, resp = 400, b'{"error":"invalid field"}'
        elif self.path.startswith("/slow"):
            time.sleep(1.0)
            code, resp = 200, b'{"id":"slow-ok"}'
        else:
            code, resp = 404, b"{}"
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


def worker_env(target, url):
    env = dict(os.environ)
    env.update({"DATABASE_URL": DSN, f"INT_{target.upper()}_URL": url, f"INT_{target.upper()}_TOKEN": TOKEN,
                "no_proxy": "127.0.0.1,localhost", "NO_PROXY": "127.0.0.1,localhost"})
    return env


def test_worker(port):
    base = f"http://127.0.0.1:{port}"
    with connect() as c:
        ok_id = one(c, "SELECT int_enqueue('mock', 'flaky', 'mock:order:1:v1', %s)",
                    (json.dumps({"order": 1, "phone": MARKER}),))
        bad_id = one(c, "SELECT int_enqueue('mock', 'bad', 'mock:order:2:v1', %s)",
                     (json.dumps({"order": 2, "phone": MARKER}),))
    proc = subprocess.run([sys.executable, WORKER, "--schema", SCHEMA, "--target", "mock", "--handler", "http_json",
                           "--drain", "--poll", "0.2", "--backoff-base", "0.5", "--max-seconds", "30"],
                          env=worker_env("mock", base + "/{operation}"), capture_output=True, text=True, timeout=60)
    check("worker.py завершился штатно", proc.returncode == 0, proc.stderr[-500:])

    flaky = [s for s in Mock.seen if s[0] == "/flaky"]
    keys = {s[1] for s in flaky}
    check("заглушка: первая попытка 500, вторая 200 — два запроса", len(flaky) == 2, f"запросов {len(flaky)}")
    check("Idempotency-Key одинаковый при повторе", keys == {"mock:order:1:v1"}, str(keys))
    check("токен передан в Authorization", all(s[2] == f"Bearer {TOKEN}" for s in flaky))
    with connect() as c:
        row = c.execute("SELECT status, attempts, external_id FROM int_outbox WHERE id = %s", (ok_id,)).fetchone()
        check("запись после повтора — done с ID внешней системы", row == ("done", 2, "ext-1"), str(row))
        row = c.execute("SELECT status, attempts, last_error FROM int_outbox WHERE id = %s", (bad_id,)).fetchone()
        check("ответ 400 — сразу dead без повторов", row[0] == "dead" and row[1] == 1 and "400" in row[2], str(row))

    lines = [ln for ln in proc.stderr.splitlines() if ln.strip()]
    try:
        events = [json.loads(ln) for ln in lines]
        parsed = True
    except ValueError:
        events, parsed = [], False
    check("логи воркера — JSON-строки", parsed and len(events) >= 4, lines[:2] if not parsed else "")
    check("в логах нет тела запроса и токена", MARKER not in proc.stderr and TOKEN not in proc.stderr)
    check("в логах есть итог каждой попытки",
          sum(1 for e in events if e.get("event") in ("job_done", "job_failed")) == 3)


def test_graceful_shutdown(port):
    with connect() as c:
        ids = [one(c, "SELECT int_enqueue('slow', 'op', %s, '{}')", (f"slow:{i}",)) for i in range(3)]
    Mock.first_request.clear()
    proc = subprocess.Popen([sys.executable, WORKER, "--schema", SCHEMA, "--target", "slow", "--handler", "http_json",
                             "--batch", "3", "--poll", "0.2", "--max-seconds", "30"],
                            env=worker_env("slow", f"http://127.0.0.1:{port}/slow"),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    got_request = Mock.first_request.wait(15)
    proc.send_signal(signal.SIGTERM)
    try:
        _, err = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        _, err = proc.communicate()
    check("SIGTERM: воркер вышел с кодом 0", got_request and proc.returncode == 0, err[-300:])
    with connect() as c:
        rows = c.execute("SELECT status, attempts FROM int_outbox WHERE id = ANY(%s) ORDER BY id", (ids,)).fetchall()
    check("SIGTERM: текущая запись доделана, остальные возвращены без штрафа",
          rows == [("done", 1), ("pending", 0), ("pending", 0)], str(rows))


def main():
    try:
        with psycopg.connect(DSN, connect_timeout=5) as c:
            c.execute(f"CREATE SCHEMA {SCHEMA}")
    except psycopg.OperationalError as e:
        print(f"База недоступна: {e}".strip(), file=sys.stderr)
        return 3
    server = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        test_install_twice()
        if failures:
            return 1
        test_enqueue_dedup()
        test_concurrent_claim()
        test_backoff_dead_replay()
        test_ordering_lease_release()
        test_inbox()
        test_worker(server.server_address[1])
        test_graceful_shutdown(server.server_address[1])
    finally:
        server.shutdown()
        with psycopg.connect(DSN, autocommit=True) as c:
            c.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        print(f"Схема {SCHEMA} удалена")
    print(f"Итог: {'всё прошло' if not failures else 'провалов ' + str(len(failures))}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
