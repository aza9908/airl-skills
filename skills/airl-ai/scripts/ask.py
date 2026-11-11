#!/usr/bin/env python3
"""Вопросы к цифрам компании на обычном языке — только через разрешённые запросы.

  python3 ask.py --config ai/questions.json --role ceo "Какая доля брака была в прошлом месяце?"

Модель не пишет SQL. Она выбирает один из запросов, заранее описанных в конфигурации
(с параметрами и списком ролей), программа выполняет его пользователем только на
чтение, модель отвечает по результату со ссылками [R1]. Каждое число в ответе
сверяется с результатами запросов и числами из самого вопроса. Не сошлось — ответ
не показывается. Вопрос не про данные из каталога — честное «не могу ответить».
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import airl_ai_common as ai  # noqa: E402

SYSTEM = """Ты отвечаешь сотруднику компании «{company}» на вопросы о её цифрах. Язык ответа — язык вопроса.

Правила:
- Цифры бери только из результатов инструментов. Каждый результат помечен R1, R2…;
  после каждого числа ставь ссылку, например [R1].
- Не вычисляй новых чисел и не округляй иначе, чем в результатах.
- Если ни один инструмент не подходит к вопросу или результат пуст — ответь одной фразой:
  «На этот вопрос по доступным данным ответить не могу» и подскажи, какие вопросы можно задать.
- Отвечай коротко: 1–4 предложения. Без markdown-таблиц."""


def build_tools(conf, role):
    tools = []
    for q in conf["queries"]:
        if role not in q.get("roles", []):
            continue
        props = {k: dict(v) for k, v in q.get("params", {}).items()}
        tools.append({"name": q["name"], "description": q["description"], "strict": True,
                      "input_schema": {"type": "object", "properties": props,
                                       "required": list(props), "additionalProperties": False}})
    return tools


def valid_args(spec, args):
    params = spec.get("params", {})
    if set(args) != set(params):
        return False
    for k, rule in params.items():
        v = args[k]
        if rule.get("type") == "integer":
            if not isinstance(v, int) or isinstance(v, bool):
                return False
            if v < rule.get("minimum", v) or v > rule.get("maximum", v):
                return False
        elif rule.get("type") == "string":
            if not isinstance(v, str) or ("enum" in rule and v not in rule["enum"]):
                return False
    return True


def answer(client, conf, role, question, run_query, max_rounds=4):
    """run_query(spec, args) -> list[dict]. Возвращает (ответ, источники, проблема)."""
    tools = build_tools(conf, role)
    if not tools:
        return None, [], "для этой роли нет разрешённых запросов"
    specs = {q["name"]: q for q in conf["queries"]}
    system = SYSTEM.format(company=conf["company"])
    messages = [{"role": "user", "content": question}]
    pool_values, sources, n = [question], [], 0
    for _ in range(max_rounds):
        resp = ai.ask_model(client, model=conf.get("model", ai.DEFAULT_MODEL), system=system,
                            messages=messages, tools=tools, effort=conf.get("effort", "medium"))
        if resp.stop_reason == "refusal":
            return None, sources, "модель отказала"
        if resp.stop_reason != "tool_use":
            text = ai.text_of(resp)
            bad = ai.check_numbers(text, ai.allowed_numbers(pool_values))
            if bad:
                return None, sources, "числа не сошлись с данными: " + ", ".join(bad)
            return text, sources, None
        messages.append({"role": "assistant", "content": resp.content})
        results = []
        for block in resp.content:
            if getattr(block, "type", None) != "tool_use":
                continue
            spec, args = specs.get(block.name), block.input if isinstance(block.input, dict) else {}
            if spec is None or role not in spec.get("roles", []) or not valid_args(spec, args):
                results.append({"type": "tool_result", "tool_use_id": block.id, "is_error": True,
                                "content": "Запрос недоступен или параметры неверны."})
                continue
            rows = [ai.to_jsonable(r) for r in run_query(spec, args)][:50]
            n += 1
            rid = f"R{n}"
            sources.append({"id": rid, "query": spec["name"], "params": args, "rows": len(rows)})
            for r in rows:
                pool_values.extend(r.values())
            results.append({"type": "tool_result", "tool_use_id": block.id,
                            "content": json.dumps({"id": rid, "rows": rows}, ensure_ascii=False)})
        messages.append({"role": "user", "content": results})
    return None, sources, "слишком много шагов"


def main():
    p = argparse.ArgumentParser(description="Вопрос к цифрам компании")
    p.add_argument("--config", required=True)
    p.add_argument("--role", required=True, help="роль спрашивающего из проверенной сессии")
    p.add_argument("question")
    a = p.parse_args()
    conf = ai.load_config(a.config)
    dsn = os.environ.get("AI_READER_DATABASE_URL")
    if not dsn:
        print("Задайте AI_READER_DATABASE_URL (пользователь только на чтение)", file=sys.stderr)
        return 2
    with ai.connect_readonly(dsn) as conn:
        text, sources, problem = answer(ai.make_client(), conf, a.role, a.question,
                                        lambda spec, args: ai.fetch(conn, spec["sql"], args, limit=50))
    if text is None:
        print("Не получилось ответить надёжно: " + problem)
        return 1
    print(text)
    for s in sources:
        print(f"[{s['id']}] {s['query']} {json.dumps(s['params'], ensure_ascii=False)} — строк: {s['rows']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
