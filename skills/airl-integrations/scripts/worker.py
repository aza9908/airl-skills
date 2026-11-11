#!/usr/bin/env python3
"""Воркер outbox интеграционного сервиса AIRL (образец).

Забирает записи из int_outbox пачками (int_claim_batch, FOR UPDATE SKIP LOCKED),
вызывает обработчик своей цели, отмечает int_mark_done / int_mark_failed.
Несколько воркеров на одну цель работают параллельно без дублей.

Нужны Python 3.9+ и psycopg 3:  pip install "psycopg[binary]"

  DATABASE_URL=postgresql://svc_int@db/hub INT_KASPI_URL=https://... INT_KASPI_TOKEN=... \\
    python3 worker.py --schema int --target kaspi --handler http_json

  # свой обработчик: модуль с функцией register(handlers), см. HANDLERS ниже
  python3 worker.py --schema int --target 1c --plugin handlers_1c

Обработчик — функция handler(job: dict) -> Result. Ошибки:
  RetryableError  — сеть, таймаут, 429, 5xx: повтор с растущей паузой;
  PermanentError  — данные неверны, 4xx, закрытый период: сразу в dead, нужен человек.
Любое другое исключение считается повторяемым (лучше повторить, чем потерять).

Логи — JSON-строки в stderr: ID записи, цель, попытка, итог, длительность, код HTTP.
Тело запроса, ответ, токены и персональные данные в лог не пишутся никогда.

SIGTERM / SIGINT: воркер дорабатывает текущую запись, остальные записи пачки
возвращает в очередь (int_release) и выходит с кодом 0.

Код выхода: 0 — штатная остановка, 2 — ошибка запуска.
"""
import argparse
import importlib
import json
import os
import signal
import socket
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Dict, Optional

try:
    import psycopg
    from psycopg.rows import dict_row
except ImportError:  # pragma: no cover
    print('Нужен psycopg 3: pip install "psycopg[binary]"', file=sys.stderr)
    sys.exit(2)


# ───────────────────────────── контракт обработчика ─────────────────────────────

@dataclass
class Result:
    external_id: Optional[str] = None          # ID объекта во внешней системе
    response: Optional[dict] = field(default=None)  # минимум: номер, статус — без персональных данных


class RetryableError(Exception):
    def __init__(self, message, retry_after: Optional[float] = None, http_status: Optional[int] = None):
        super().__init__(message)
        self.retry_after = retry_after
        self.http_status = http_status


class PermanentError(Exception):
    def __init__(self, message, http_status: Optional[int] = None):
        super().__init__(message)
        self.http_status = http_status


Handler = Callable[[dict], Result]

# Цель → обработчик. Заполняется плагинами (--plugin) или прямо здесь:
#   HANDLERS["1c"] = post_payment_status_to_1c
HANDLERS: Dict[str, Handler] = {}


def register(target: str, handler: Handler) -> None:
    HANDLERS[target] = handler


# ───────────────────────────── логирование ─────────────────────────────

def log(level: str, event: str, **fields) -> None:
    rec = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
           "level": level, "event": event}
    rec.update({k: v for k, v in fields.items() if v is not None})
    print(json.dumps(rec, ensure_ascii=False), file=sys.stderr, flush=True)


def short_error(exc: BaseException) -> str:
    """Короткое описание ошибки для last_error: класс и текст, без тела ответа."""
    return f"{type(exc).__name__}: {exc}"[:300]


# ───────────────────────────── образец обработчика: HTTP JSON POST ─────────────────────────────

def http_json_post(job: dict) -> Result:
    """POST payload как JSON на адрес из INT_<TARGET>_URL.

    Заголовки: Idempotency-Key = idempotency_key записи (тот же при каждом
    повторе), X-Operation = operation, Authorization: Bearer INT_<TARGET>_TOKEN,
    если токен задан. В адресе можно использовать {operation}.
    Таймаут — INT_<TARGET>_TIMEOUT секунд (по умолчанию 10).

    Как ответ превращается в итог (поменяйте под документацию системы):
      2xx            → done; external_id из поля "id" ответа, если есть;
      409            → done, если система так сообщает «уже создано по этому ключу»
                       (проверить в документации системы!), иначе поменяйте на PermanentError;
      408, 425, 429  → повтор (уважая Retry-After);
      5xx, сеть      → повтор;
      прочие 4xx     → dead: запрос неверен, повтор не поможет.
    """
    prefix = "INT_" + job["target"].upper()
    url_tpl = os.environ.get(prefix + "_URL")
    if not url_tpl:
        raise PermanentError(f"не задан {prefix}_URL")
    url = url_tpl.replace("{operation}", job["operation"])
    timeout = float(os.environ.get(prefix + "_TIMEOUT", "10"))
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Idempotency-Key": job["idempotency_key"],
        "X-Operation": job["operation"],
        "User-Agent": "airl-integrations-worker/1",
    }
    token = os.environ.get(prefix + "_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    body = json.dumps(job["payload"], ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read(1_000_000)
            data = json.loads(raw) if raw else {}
            ext = data.get("id") if isinstance(data, dict) else None
            return Result(external_id=str(ext) if ext is not None else None,
                          response={"http_status": r.status, **({"id": ext} if ext is not None else {})})
    except urllib.error.HTTPError as e:
        e.read(10_000)  # дочитать и выбросить: тело может содержать персональные данные
        if e.code == 409:
            return Result(response={"http_status": 409, "note": "already processed"})
        if e.code in (408, 425, 429) or e.code >= 500:
            ra = e.headers.get("Retry-After")
            retry_after = float(ra) if ra and ra.isdigit() else None
            raise RetryableError(f"HTTP {e.code}", retry_after=retry_after, http_status=e.code) from None
        raise PermanentError(f"HTTP {e.code}", http_status=e.code) from None
    except (urllib.error.URLError, TimeoutError, socket.timeout, ConnectionError) as e:
        reason = getattr(e, "reason", e)
        raise RetryableError(f"сеть: {type(reason).__name__}") from None
    except ValueError:
        raise RetryableError("ответ не JSON") from None


BUILTIN = {"http_json": http_json_post}


# ───────────────────────────── предохранитель (circuit breaker) ─────────────────────────────

class CircuitBreaker:
    """После N повторяемых ошибок подряд перестаём дёргать систему на cooldown секунд.

    Система лежит — нет смысла сжигать попытки всех записей очереди. После паузы
    пробуем одну пачку («полуоткрыто»): успех закрывает предохранитель.
    """

    def __init__(self, threshold: int, cooldown: float):
        self.threshold = threshold
        self.cooldown = cooldown
        self.failures = 0
        self.open_until = 0.0

    def allow(self) -> bool:
        return time.monotonic() >= self.open_until

    def success(self) -> None:
        self.failures = 0

    def failure(self) -> bool:
        self.failures += 1
        if self.failures >= self.threshold:
            self.open_until = time.monotonic() + self.cooldown
            self.failures = 0
            return True
        return False


# ───────────────────────────── цикл воркера ─────────────────────────────

class Worker:
    def __init__(self, conn, target: str, handler: Handler, worker_id: str, batch: int,
                 lease: int, backoff_base: float, backoff_cap: float, breaker: CircuitBreaker):
        self.conn = conn
        self.target = target
        self.handler = handler
        self.worker_id = worker_id
        self.batch = batch
        self.lease = lease
        self.backoff_base = backoff_base
        self.backoff_cap = backoff_cap
        self.breaker = breaker
        self.stopping = False
        self.stats = {"done": 0, "retry": 0, "dead": 0, "lost_lease": 0}

    def stop(self, signum=None, frame=None):
        if not self.stopping:
            log("info", "stop_requested", target=self.target, signal=signum)
        self.stopping = True

    def claim(self):
        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT * FROM int_claim_batch(%s, %s, %s, make_interval(secs => %s))",
                        (self.target, self.batch, self.worker_id, self.lease))
            return cur.fetchall()

    def unfinished(self) -> int:
        return self.conn.execute(
            "SELECT count(*) FROM int_outbox WHERE target = %s AND status IN ('pending','retry','processing')",
            (self.target,)).fetchone()[0]

    def process(self, job: dict) -> None:
        started = time.monotonic()
        common = dict(target=self.target, job_id=job["id"], operation=job["operation"],
                      attempt=job["attempts"], max_attempts=job["max_attempts"])
        try:
            res = self.handler(job)
        except PermanentError as e:
            status = self.conn.execute(
                "SELECT int_mark_failed(%s, %s, false, %s)", (job["id"], short_error(e), self.worker_id)).fetchone()[0]
            self._count(status)
            log("error", "job_failed", outcome=status or "lost_lease", retryable=False, http_status=e.http_status,
                error=short_error(e), duration_ms=int((time.monotonic() - started) * 1000), **common)
            return
        except Exception as e:  # noqa: BLE001 — неизвестная ошибка = повторяемая
            http_status = getattr(e, "http_status", None)
            retry_after = getattr(e, "retry_after", None)
            status = self.conn.execute(
                "SELECT int_mark_failed(%s, %s, true, %s, make_interval(secs => %s),"
                " make_interval(secs => %s), make_interval(secs => %s))",
                (job["id"], short_error(e), self.worker_id, retry_after or 0,
                 self.backoff_base, self.backoff_cap)).fetchone()[0]
            self._count(status)
            tripped = self.breaker.failure()
            log("warning", "job_failed", outcome=status or "lost_lease", retryable=True, http_status=http_status,
                error=short_error(e), duration_ms=int((time.monotonic() - started) * 1000), **common)
            if tripped:
                log("warning", "circuit_open", target=self.target, cooldown_s=self.breaker.cooldown)
            return
        self.breaker.success()
        ok = self.conn.execute(
            "SELECT int_mark_done(%s, %s, %s, %s)",
            (job["id"], self.worker_id, res.external_id,
             json.dumps(res.response, ensure_ascii=False) if res.response is not None else None)).fetchone()[0]
        self._count("done" if ok else None)
        log("info", "job_done" if ok else "job_lost_lease", outcome="done" if ok else "lost_lease",
            external_id=res.external_id, duration_ms=int((time.monotonic() - started) * 1000), **common)

    def _count(self, status):
        key = status if status in self.stats else "lost_lease"
        self.stats[key] += 1

    def run(self, poll: float, drain: bool, max_seconds: Optional[float]) -> None:
        deadline = time.monotonic() + max_seconds if max_seconds else None
        log("info", "worker_started", target=self.target, worker=self.worker_id, batch=self.batch)
        while not self.stopping:
            if deadline and time.monotonic() >= deadline:
                log("warning", "max_seconds_reached", target=self.target)
                break
            if not self.breaker.allow():
                self._sleep(min(poll, self.breaker.open_until - time.monotonic()))
                continue
            jobs = self.claim()
            if not jobs:
                if drain and self.unfinished() == 0:
                    break
                self._sleep(poll)
                continue
            for i, job in enumerate(jobs):
                if self.stopping or not self.breaker.allow():
                    for rest in jobs[i:]:
                        self.conn.execute("SELECT int_release(%s, %s)", (rest["id"], self.worker_id))
                    log("info", "released", target=self.target, count=len(jobs) - i)
                    break
                self.process(job)
        log("info", "worker_stopped", target=self.target, **self.stats)

    def _sleep(self, seconds: float) -> None:
        end = time.monotonic() + max(seconds, 0)
        while not self.stopping:
            left = end - time.monotonic()
            if left <= 0:
                break
            time.sleep(min(0.2, left))


def main() -> int:
    p = argparse.ArgumentParser(description="Воркер outbox AIRL")
    p.add_argument("--target", required=True, help="цель: 1c, kaspi, bank_halyk ...")
    p.add_argument("--schema", default="int", help="схема, куда установлен outbox.sql (по умолчанию int)")
    p.add_argument("--handler", choices=sorted(BUILTIN), help="встроенный обработчик, если цели нет в HANDLERS")
    p.add_argument("--plugin", action="append", default=[],
                   help="модуль Python с функцией register(handlers: dict); можно несколько")
    p.add_argument("--batch", type=int, default=10)
    p.add_argument("--lease", type=int, default=300, help="аренда записи, с; дольше самого медленного вызова")
    p.add_argument("--poll", type=float, default=2.0, help="пауза при пустой очереди, с")
    p.add_argument("--backoff-base", type=float, default=30.0, help="первая пауза перед повтором, с")
    p.add_argument("--backoff-cap", type=float, default=6 * 3600.0, help="предел паузы, с")
    p.add_argument("--breaker-threshold", type=int, default=5, help="ошибок подряд до паузы цели")
    p.add_argument("--breaker-cooldown", type=float, default=60.0, help="пауза цели после серии ошибок, с")
    p.add_argument("--drain", action="store_true", help="выйти, когда незавершённых записей цели не осталось")
    p.add_argument("--max-seconds", type=float, help="выйти через столько секунд (для cron и тестов)")
    p.add_argument("--worker-id", default=f"{socket.gethostname()}:{os.getpid()}")
    a = p.parse_args()

    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        print("Задайте DATABASE_URL", file=sys.stderr)
        return 2
    if not a.schema.replace("_", "").isalnum():
        print("Странное имя схемы", file=sys.stderr)
        return 2

    for mod in a.plugin:
        importlib.import_module(mod).register(HANDLERS)
    handler = HANDLERS.get(a.target) or (BUILTIN.get(a.handler) if a.handler else None)
    if handler is None:
        print(f"Нет обработчика для цели {a.target}: добавьте его в HANDLERS (--plugin) или укажите --handler",
              file=sys.stderr)
        return 2

    try:
        conn = psycopg.connect(dsn, autocommit=True, application_name=f"airl-int-worker:{a.target}",
                               options=f"-c search_path={a.schema}")
    except psycopg.Error as e:
        print(f"Нет подключения к базе: {type(e).__name__}", file=sys.stderr)
        return 2

    w = Worker(conn, a.target, handler, a.worker_id, a.batch, a.lease, a.backoff_base, a.backoff_cap,
               CircuitBreaker(a.breaker_threshold, a.breaker_cooldown))
    signal.signal(signal.SIGTERM, w.stop)
    signal.signal(signal.SIGINT, w.stop)
    try:
        w.run(a.poll, a.drain, a.max_seconds)
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
