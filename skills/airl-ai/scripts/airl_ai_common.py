"""Общая часть ИИ-слоя AIRL: модель, проверка чисел, база, Telegram.

Зависимости: anthropic, psycopg[binary] (pip install anthropic "psycopg[binary]").
Ключ модели — переменная ANTHROPIC_API_KEY на сервере, не в коде.
"""
import json
import os
import re
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation

DEFAULT_MODEL = "claude-opus-5-5"
FALLBACK_BETA = "server-side-fallback-2026-07-01"


# ---------- модель ----------

def make_client():
    import anthropic  # импорт здесь: проверки чисел и шаблоны работают без SDK
    return anthropic.Anthropic()


def ask_model(client, *, model, system, messages, tools=None, effort="medium", max_tokens=16000):
    """Один запрос к модели. Возвращает ответ SDK.

    Включён серверный запасной путь (fallbacks="default"): если модель отказывает
    по соображениям безопасности, запрос продолжает другая модель. Отказ всей
    цепочки виден как stop_reason == "refusal" — вызывающий код это проверяет.
    """
    params = dict(model=model, max_tokens=max_tokens, system=system, messages=messages,
                  output_config={"effort": effort},
                  betas=[FALLBACK_BETA], fallbacks="default")
    if tools:
        params["tools"] = tools
    return client.beta.messages.create(**params)


def text_of(response):
    return "".join(b.text for b in response.content if getattr(b, "type", None) == "text").strip()


# ---------- проверка чисел ----------

_NUM = re.compile(r"(?<![\w\[])[-−]?\d{1,3}(?:[   ]\d{3})+(?:[.,]\d+)?(?![\w])|(?<![\w\[])[-−]?\d+(?:[.,]\d+)?(?![\w])")
_CITE = re.compile(r"\[(?:[FRD]\d+(?:\s*,\s*[FRD]\d+)*)\]")


def _norm(token):
    t = token.replace("−", "-").replace(" ", "").replace(" ", "").replace(" ", "").replace(",", ".")
    try:
        return Decimal(t).normalize()
    except InvalidOperation:
        return None


def allowed_numbers(values):
    """Множество чисел, которые можно упоминать: значения фактов и их округления.

    Строки (названия показателей, текст документов) дают числа, которые в них
    написаны. Даты сюда не передавай — для них есть years_of().
    """
    allowed = set()
    for v in values:
        if v is None or isinstance(v, bool):
            continue
        if isinstance(v, str):
            for tok in _NUM.findall(v):
                n = _norm(tok)
                if n is not None:
                    allowed.add(n)
            continue
        try:
            d = Decimal(str(v))
        except InvalidOperation:
            continue
        # Округления, которые человек считает тем же числом: до 0,01 и 0,1 — всегда,
        # до целого — только для чисел от 10 (7,5 → 8 уже другое число).
        quants = [Decimal("0.1"), Decimal("0.01")] + ([Decimal(1)] if abs(d) >= 10 else [])
        for q in quants:
            allowed.add(d.quantize(q).normalize())
            allowed.add(abs(d).quantize(q).normalize())
        allowed.add(d.normalize())
        allowed.add(abs(d).normalize())
    return allowed


def years_of(*periods):
    """Годы из периодов вида 2026-10 или 2026-11-10 — месяцы и дни не разрешаются."""
    out = []
    for p in periods:
        if p:
            out += [int(y) for y in re.findall(r"(?<!\d)(\d{4})(?!\d)", str(p))]
    return out


def check_numbers(text, allowed):
    """Возвращает список чисел в тексте, которых нет среди разрешённых.

    Ссылки на источники вида [F3] не считаются числами. Номера пунктов списка
    («1.», «2)») в начале строки тоже не считаются.
    """
    stripped = _CITE.sub(" ", text)
    stripped = re.sub(r"(?m)^\s*\d+[.)]\s", " ", stripped)
    bad = []
    for tok in _NUM.findall(stripped):
        n = _norm(tok)
        if n is not None and n not in allowed:
            bad.append(tok.strip())
    return bad


def fmt_number(value, unit=""):
    """Число по-местному: пробелы между разрядами, запятая в дробях."""
    if value is None:
        return "нет данных"
    d = Decimal(str(value))
    if d == d.to_integral_value():
        s = f"{int(d):,}".replace(",", " ")
    else:
        s = f"{d:,.2f}".replace(",", " ").replace(".", ",").rstrip("0").rstrip(",")
    return f"{s} {unit}".strip() if unit and unit != "%" else (s + "%" if unit == "%" else s)


# ---------- база ----------

def connect_readonly(dsn):
    """Соединение только на чтение с ограничением времени запроса."""
    import psycopg
    conn = psycopg.connect(dsn, autocommit=True)
    conn.execute("SET default_transaction_read_only = on")
    conn.execute("SET statement_timeout = '10s'")
    return conn


def fetch(conn, sql, params=None, limit=200):
    with conn.cursor() as cur:
        cur.execute(sql, params or {})
        cols = [c.name for c in cur.description]
        rows = cur.fetchmany(limit)
    return [dict(zip(cols, r)) for r in rows]


def to_jsonable(row):
    out = {}
    for k, v in row.items():
        if isinstance(v, Decimal):
            out[k] = float(v) if v != v.to_integral_value() else int(v)
        elif hasattr(v, "isoformat"):
            out[k] = v.isoformat()
        else:
            out[k] = v
    return out


# ---------- доставка ----------

def send_telegram(text):
    """Отправка в Telegram: TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID из окружения."""
    token, chat = os.environ.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_CHAT_ID")
    if not token or not chat:
        raise RuntimeError("Задайте TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID")
    body = urllib.parse.urlencode({"chat_id": chat, "text": text[:4000],
                                   "disable_web_page_preview": "true"}).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=body)
    with urllib.request.urlopen(req, timeout=30) as r:
        if json.loads(r.read()).get("ok") is not True:
            raise RuntimeError("Telegram не принял сообщение")


def load_config(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)
