"""Проверки ИИ-слоя AIRL без вызова модели: подставной клиент вместо API.

  python3 -m pytest tests/test_airl_ai.py          # если есть pytest
  python3 tests/test_airl_ai.py                    # без pytest

Проверка kb.py с базой: задайте TEST_DATABASE_URL (тестовая база, создаёт схему ai).
"""
import json
import os
import sys
import tempfile
from types import SimpleNamespace as NS

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "skills", "airl-ai", "scripts"))

import airl_ai_common as ai  # noqa: E402
import ask  # noqa: E402
import digest  # noqa: E402
import kb  # noqa: E402


class FakeClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []
        self.beta = NS(messages=NS(create=self._create))

    def _create(self, **params):
        self.calls.append(params)
        return self.responses.pop(0)


def text_resp(text, stop="end_turn"):
    return NS(stop_reason=stop, content=[NS(type="thinking", thinking=""), NS(type="text", text=text)])


def tool_resp(name, args, tid="t1"):
    return NS(stop_reason="tool_use", content=[NS(type="tool_use", name=name, input=args, id=tid)])


CONF = {"company": "STEP COFFEE", "language": "русский"}
FACTS = [
    digest.make_fact(CONF, "Обжарка", [
        {"metric_id": "qc_reject_rate", "period": "2026-10", "value": 7.5, "unit": "%", "status": "danger"},
        {"metric_id": "qc_reject_rate", "period": "2026-09", "value": 3.2, "unit": "%", "status": "warning"}]),
    digest.make_fact(CONF, "Финансы", [
        {"metric_id": "receivables_overdue", "period": "2026-11-10", "value": 48250000, "unit": "KZT", "status": "warning"}]),
]


def test_number_check():
    allowed = ai.allowed_numbers([48250000, 7.5, "2026-10"])
    assert ai.check_numbers("Просрочка 48 250 000 KZT [F2], брак 7,5% [F1] за 2026-10", allowed) == []
    assert ai.check_numbers("Просрочка выросла до 51 000 000 [F2]", allowed) == ["51 000 000"]
    assert ai.check_numbers("1. Брак 7.5% [F1]\n2. Всё [F2]", allowed) == []
    assert ai.check_numbers("Брак 8% [F1]", allowed) == ["8"]


def test_fact_changes():
    f = FACTS[0]
    assert f["change"] == 4.3 and f["change_pct"] == 134.4 and f["display"] == "7,5%"
    assert FACTS[1]["display"] == "48 250 000 KZT"


def test_digest_good_first_try():
    c = FakeClient([text_resp("🔴 Брак 7,5% [F1], рост +4,3% [F1]. Просрочка 48 250 000 KZT [F2].")])
    text, problem = digest.write_with_model(c, CONF, FACTS, digest.dt.date(2026, 11, 11))
    assert problem is None and "7,5%" in text
    p = c.calls[0]
    assert p["model"] == "claude-opus-5-5" and p["fallbacks"] == "default"
    assert p["betas"] == ["server-side-fallback-2026-07-01"] and p["output_config"] == {"effort": "medium"}
    assert "thinking" not in p and "temperature" not in p


def test_digest_invented_number_retry_then_ok():
    c = FakeClient([text_resp("Брак 9% [F1]"), text_resp("Брак 7,5% [F1]")])
    text, problem = digest.write_with_model(c, CONF, FACTS, digest.dt.date(2026, 11, 11))
    assert problem is None and text == "Брак 7,5% [F1]"
    feedback = c.calls[1]["messages"][-1]["content"]
    assert "9" in feedback and c.calls[1]["messages"][1]["role"] == "assistant"


def test_digest_invented_twice_falls_back():
    c = FakeClient([text_resp("Брак 9% [F1]"), text_resp("Брак 10% [F1]")])
    text, problem = digest.write_with_model(c, CONF, FACTS, digest.dt.date(2026, 11, 11))
    assert text is None and "не сошлись" in problem
    tpl = digest.template_digest({"company": "STEP COFFEE"}, FACTS, digest.dt.date(2026, 11, 11), note=problem)
    assert tpl.splitlines()[1].startswith("🔴") and "7,5%" in tpl and "Сводка без ИИ" in tpl


def test_digest_refusal_falls_back():
    c = FakeClient([text_resp("", stop="refusal")])
    text, problem = digest.write_with_model(c, CONF, FACTS, digest.dt.date(2026, 11, 11))
    assert text is None and problem == "модель отказала"


QCONF = {"company": "STEP COFFEE", "queries": [
    {"name": "metric_history", "description": "История показателя",
     "sql": "SELECT ...", "roles": ["ceo"],
     "params": {"metric_id": {"type": "string", "enum": ["qc_reject_rate"]},
                "months": {"type": "integer", "minimum": 1, "maximum": 24}}}]}


def test_ask_flow_and_number_check():
    rows = [{"metric_id": "qc_reject_rate", "period": "2026-10", "value": 7.5}]
    c = FakeClient([tool_resp("metric_history", {"metric_id": "qc_reject_rate", "months": 2}),
                    text_resp("В октябре доля брака 7,5% [R1].")])
    text, sources, problem = ask.answer(c, QCONF, "ceo", "Какой брак за 2 месяца?", lambda s, a: rows)
    assert problem is None and sources[0]["id"] == "R1"
    tool = c.calls[0]["tools"][0]
    assert tool["strict"] is True and tool["input_schema"]["additionalProperties"] is False
    tr = c.calls[1]["messages"][-1]["content"][0]
    assert tr["type"] == "tool_result" and json.loads(tr["content"])["id"] == "R1"


def test_ask_rejects_invented_number():
    rows = [{"value": 7.5}]
    c = FakeClient([tool_resp("metric_history", {"metric_id": "qc_reject_rate", "months": 1}),
                    text_resp("Брак 12% [R1]")])
    text, _, problem = ask.answer(c, QCONF, "ceo", "Брак?", lambda s, a: rows)
    assert text is None and "12" in problem


def test_ask_role_and_bad_params():
    text, _, problem = ask.answer(FakeClient([]), QCONF, "staff_sales", "Брак?", lambda s, a: [])
    assert text is None and "нет разрешённых" in problem
    called = []
    c = FakeClient([tool_resp("metric_history", {"metric_id": "revenue", "months": 1}),
                    text_resp("На этот вопрос по доступным данным ответить не могу")])
    text, sources, problem = ask.answer(c, QCONF, "ceo", "Выручка?", lambda s, a: called.append(a) or [])
    assert called == [] and sources == [] and problem is None
    assert c.calls[1]["messages"][-1]["content"][0]["is_error"] is True


FOUND = [{"doc_id": "vozvrat", "title": "Регламент возврата", "version": "3", "url": None,
          "heading": "Сроки", "body": "Возврат оформляется в течение 14 дней по заявлению клиента."}]


def test_kb_answer_requires_citation_and_known_numbers():
    ok = kb.answer(FakeClient([text_resp("Возврат — в течение 14 дней по заявлению [D1].")]), CONF, "Как вернуть?", FOUND)
    assert ok[2] is None and ok[1][0]["title"] == "Регламент возврата"
    nocite = kb.answer(FakeClient([text_resp("Возврат в течение 14 дней.")]), CONF, "Как вернуть?", FOUND)
    assert nocite[0] is None and "ссылок" in nocite[2]
    wrongnum = kb.answer(FakeClient([text_resp("Возврат в течение 30 дней [D1].")]), CONF, "Как вернуть?", FOUND)
    assert wrongnum[0] is None and "30" in wrongnum[2]
    assert kb.answer(None, CONF, "Что угодно", [])[0] == kb.NOT_FOUND


def test_kb_chunks():
    text = "# Раздел А\n" + ("абзац текста. " * 40 + "\n\n") * 5 + "## Раздел Б\nкоротко"
    parts = kb.chunks(text, max_chars=1200)
    assert all(len(b) <= 1200 for _, b in parts) and parts[-1] == ("Раздел Б", "коротко")


def test_kb_index_and_search_in_postgres():
    dsn = os.environ.get("TEST_DATABASE_URL")
    if not dsn:
        print("  (пропущено: нет TEST_DATABASE_URL)")
        return
    import psycopg
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "vozvrat.md"), "w", encoding="utf-8") as f:
            f.write("---\ntitle: Регламент возврата\nversion: 3\nroles: [all]\n---\n# Сроки\n"
                    "Возврат товара оформляется в течение 14 дней по заявлению клиента.\n")
        with open(os.path.join(d, "zarplata.md"), "w", encoding="utf-8") as f:
            f.write("---\ntitle: Положение об оплате труда\nversion: 1\nroles: [ceo]\n---\n# Премии\n"
                    "Премия за возврат долга начисляется ежемесячно.\n")
        with psycopg.connect(dsn, autocommit=True) as conn:
            conn.execute("DROP SCHEMA IF EXISTS ai CASCADE")
            assert kb.index(conn, d) == (2, 2)
            assert kb.index(conn, d) == (2, 2)  # повторно — без дублей
            found = ai.fetch(conn, kb.SEARCH_SQL, {"q": "как оформить возврат товара", "role": "staff_sales",
                                                   "lang": "russian", "k": 5})
            assert [r["doc_id"] for r in found] == ["vozvrat"]  # зарплатный документ роли не виден
            ceo = ai.fetch(conn, kb.SEARCH_SQL, {"q": "возврат", "role": "ceo", "lang": "russian", "k": 5})
            assert {r["doc_id"] for r in ceo} == {"vozvrat", "zarplata"}
            none = ai.fetch(conn, kb.SEARCH_SQL, {"q": "отпуск по уходу", "role": "ceo", "lang": "russian", "k": 5})
            assert none == []
            conn.execute("DROP SCHEMA ai CASCADE")


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"✔ {name}")
            except Exception as e:  # noqa: BLE001
                failed += 1
                print(f"✖ {name}: {type(e).__name__}: {e}")
    sys.exit(1 if failed else 0)
