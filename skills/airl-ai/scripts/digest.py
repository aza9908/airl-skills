#!/usr/bin/env python3
"""Ежедневная сводка руководителю по единым показателям.

  python3 digest.py --config ai/digest.json                 # собрать, написать, напечатать
  python3 digest.py --config ai/digest.json --send          # и отправить в Telegram
  python3 digest.py --config ai/digest.json --dry-run       # без модели: шаблонная сводка
  python3 digest.py --config ai/digest.json --facts f.json  # факты из файла вместо базы

Как работает:
1. Берёт факты запросами из конфигурации (только чтение, пользователь ai_reader).
   Каждый запрос возвращает колонки metric_id, period, value, unit, status —
   как представления m_<…> модулей и показатели карты.
2. Считает изменения к прошлому периоду сам — модель ничего не вычисляет.
3. Модель пишет короткий текст только из этих фактов и после каждого числа
   ставит ссылку на факт [F3].
4. Каждое число в тексте сверяется с фактами. Есть лишнее число — модель
   переписывает один раз; не помогло или модель отказала — уходит шаблонная
   сводка без модели. Выдуманная цифра руководителю не уходит никогда.
"""
import argparse
import datetime as dt
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import airl_ai_common as ai  # noqa: E402

SEVERITY = {"danger": 0, "warning": 1, "ok": 2}

SYSTEM = """Ты пишешь утреннюю сводку для руководителя компании «{company}» на языке: {language}.

Правила, без исключений:
- Используй только факты из блока FACTS. Не добавляй других чисел: ни сумм, ни процентов,
  ни количеств, ни дат. Не вычисляй ничего сам — изменения уже посчитаны в фактах.
- После каждого числа ставь ссылку на факт в квадратных скобках, например [F3].
- Сначала то, что требует внимания (status = danger, затем warning), потом коротко — что в порядке.
- Для каждого красного пункта — одна фраза, что стоит проверить сегодня, без выдуманных причин.
  Если причина в фактах не видна, так и скажи: «причину нужно выяснить у <отдел>».
- Не больше {max_lines} строк. Без вступлений и прощаний. Без markdown-таблиц.
- Числа пиши так же, как в поле display у факта."""


def collect(conf, conn):
    facts = []
    for src in conf["sources"]:
        rows = ai.fetch(conn, src["sql"], limit=50)
        by_metric = {}
        for r in rows:
            by_metric.setdefault(r["metric_id"], []).append(r)
        for metric_id, items in by_metric.items():
            items.sort(key=lambda r: str(r["period"]), reverse=True)
            facts.append(make_fact(conf, src["name"], items))
    return facts


def make_fact(conf, source, items):
    cur = ai.to_jsonable(items[0])
    prev = ai.to_jsonable(items[1]) if len(items) > 1 else None
    title = conf.get("titles", {}).get(cur["metric_id"], cur["metric_id"])
    unit = cur.get("unit") or ""
    fact = {"source": source, "metric_id": cur["metric_id"], "title": title,
            "period": str(cur["period"]), "value": cur["value"], "unit": unit,
            "status": cur.get("status") or "warning",
            "display": ai.fmt_number(cur["value"], unit)}
    if prev and prev.get("value") is not None and cur.get("value") is not None:
        change = round(float(cur["value"]) - float(prev["value"]), 2)
        fact.update(previous_period=str(prev["period"]), previous_value=prev["value"],
                    previous_display=ai.fmt_number(prev["value"], unit),
                    change=change, change_display=("+" if change > 0 else "") + ai.fmt_number(change, unit))
        if float(prev["value"]) != 0:
            pct = round(100 * change / abs(float(prev["value"])), 1)
            fact.update(change_pct=pct, change_pct_display=("+" if pct > 0 else "") + ai.fmt_number(pct, "%"))
    return fact


def number_pool(facts, today):
    values = [today.year, today.day]
    for f in facts:
        for k in ("value", "previous_value", "change", "change_pct"):
            values.append(f.get(k))
        for k in ("title", "source"):
            values.append(f.get(k))
        values += ai.years_of(f.get("period"), f.get("previous_period"))
    return ai.allowed_numbers(values)


def template_digest(conf, facts, today, note=None):
    lines = [f"{conf['company']} · сводка на {today.strftime('%d.%m.%Y')}"]
    for f in sorted(facts, key=lambda f: SEVERITY.get(f["status"], 1)):
        mark = {"danger": "🔴", "warning": "🟡", "ok": "🟢"}.get(f["status"], "•")
        line = f"{mark} {f['title']} ({f['source']}): {f['display']} за {f['period']}"
        if "change_display" in f:
            line += f", изменение {f['change_display']} к {f['previous_period']}"
        lines.append(line)
    if note:
        lines.append(note)
    return "\n".join(lines)


def write_with_model(client, conf, facts, today):
    numbered = [{"id": f"F{i}", **f} for i, f in enumerate(facts, 1)]
    system = SYSTEM.format(company=conf["company"], language=conf.get("language", "русский"),
                           max_lines=conf.get("max_lines", 12))
    user = ("Сегодня " + today.isoformat() + ".\nFACTS:\n" +
            json.dumps(numbered, ensure_ascii=False, indent=1))
    messages = [{"role": "user", "content": user}]
    allowed = number_pool(facts, today)
    for attempt in range(2):
        resp = ai.ask_model(client, model=conf.get("model", ai.DEFAULT_MODEL), system=system,
                            messages=messages, effort=conf.get("effort", "medium"), max_tokens=4000)
        if resp.stop_reason == "refusal":
            return None, "модель отказала"
        text = ai.text_of(resp)
        if not text:
            return None, "пустой ответ"
        bad = ai.check_numbers(text, allowed)
        if not bad:
            return text, None
        messages += [{"role": "assistant", "content": resp.content},
                     {"role": "user", "content": "В тексте есть числа, которых нет в FACTS: " + ", ".join(bad) +
                      ". Перепиши сводку, используя только числа из FACTS, со ссылками [F#]."}]
    return None, "числа не сошлись с фактами: " + ", ".join(bad)


def main():
    p = argparse.ArgumentParser(description="Сводка руководителю")
    p.add_argument("--config", required=True)
    p.add_argument("--facts", help="JSON-файл с фактами вместо базы (для проверки)")
    p.add_argument("--dry-run", action="store_true", help="без модели: шаблонная сводка")
    p.add_argument("--send", action="store_true", help="отправить в Telegram")
    a = p.parse_args()
    conf = ai.load_config(a.config)
    today = dt.date.today()

    if a.facts:
        with open(a.facts, encoding="utf-8") as f:
            facts = json.load(f)
    else:
        dsn = os.environ.get("AI_READER_DATABASE_URL")
        if not dsn:
            print("Задайте AI_READER_DATABASE_URL (пользователь только на чтение)", file=sys.stderr)
            return 2
        with ai.connect_readonly(dsn) as conn:
            facts = collect(conf, conn)
    if not facts:
        print("Нет фактов: проверьте запросы в конфигурации", file=sys.stderr)
        return 1

    if a.dry_run:
        text, how = template_digest(conf, facts, today), "шаблон (без модели)"
    else:
        text, problem = write_with_model(ai.make_client(), conf, facts, today)
        if text is None:
            text = template_digest(conf, facts, today, note="Сводка без ИИ: " + problem)
            how = "шаблон (" + problem + ")"
        else:
            how = "модель, числа сверены"
    print(text)
    print(f"\n— способ: {how}", file=sys.stderr)
    if a.send:
        ai.send_telegram(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
