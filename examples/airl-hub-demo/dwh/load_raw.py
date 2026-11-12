#!/usr/bin/env python3
"""Загрузка выгрузок (CSV) в сырой слой хранилища: raw_1c (вкл. 1С:ЗУП), raw_bank, raw_amocrm,
raw_sheets (потоки, вакансии HR), raw_ads (рекламные кабинеты и таблица бюджета маркетинга).

Сырой слой хранит данные «как пришли»: все колонки текстом плюс время загрузки.
Повторный запуск безопасен: таблица источника перезаписывается целиком в одной
транзакции (в демо выгрузка всегда полная; в боевой загрузке 1С — окно 45 дней,
см. DWH.md).

Подключение — пользователем загрузки (LOADER_DATABASE_URL), не администратором.
Запуск: python3 dwh/load_raw.py --src data/out
"""
import argparse
import csv
import os
import sys

import psycopg
from psycopg import sql

SOURCES = {
    "raw_1c": ["organizations", "kontragenty", "dogovory", "nomenklatura", "realizatsiya",
               "realizatsiya_tovary", "postuplenie_rs", "pko", "spisanie_rs", "zatraty",
               "bank_accounts", "ostatki_dc", "sotrudniki", "zup_nachisleniya", "zup_otsutstviya"],
    "raw_bank": ["statement_lines"],
    "raw_amocrm": ["leads", "amo_users"],
    "raw_sheets": ["cohorts", "cohort_students", "vacancies"],
    "raw_ads": ["ad_campaigns", "ad_spend", "mkt_budget"],
}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--src", default=os.path.join(os.path.dirname(__file__), "..", "data", "out"))
    a = p.parse_args()
    url = os.environ.get("LOADER_DATABASE_URL")
    if not url:
        print("Нет LOADER_DATABASE_URL", file=sys.stderr)
        return 2
    total = 0
    with psycopg.connect(url) as conn:
        for schema, tables in SOURCES.items():
            for t in tables:
                path = os.path.join(a.src, f"{t}.csv")
                if not os.path.exists(path):
                    print(f"нет файла {path}", file=sys.stderr)
                    return 2
                with open(path, encoding="utf-8") as fh:
                    header = next(csv.reader(fh))
                ident = sql.Identifier(schema, t)
                cols = sql.SQL(", ").join(sql.SQL("{} text").format(sql.Identifier(c)) for c in header)
                with conn.cursor() as cur:
                    # Колонки выгрузки могли измениться (новое поле источника) — таблицу пересоздаём:
                    # сырой слой всё равно перезаписывается целиком.
                    cur.execute("SELECT array_agg(column_name::text ORDER BY ordinal_position) FROM information_schema.columns "
                                "WHERE table_schema = %s AND table_name = %s AND column_name <> '_loaded_at'", (schema, t))
                    have = cur.fetchone()[0]
                    if have is not None and list(have) != header:
                        cur.execute(sql.SQL("DROP TABLE {}").format(ident))
                    cur.execute(sql.SQL("CREATE TABLE IF NOT EXISTS {} ({}, _loaded_at timestamptz NOT NULL DEFAULT now())")
                                .format(ident, cols))
                    cur.execute(sql.SQL("TRUNCATE {}").format(ident))
                    copy_sql = sql.SQL("COPY {} ({}) FROM STDIN WITH (FORMAT csv, HEADER true)").format(
                        ident, sql.SQL(", ").join(sql.Identifier(c) for c in header))
                    with open(path, "rb") as fh, cur.copy(copy_sql) as cp:
                        while chunk := fh.read(65536):
                            cp.write(chunk)
                    cur.execute(sql.SQL("SELECT count(*) FROM {}").format(ident))
                    n = cur.fetchone()[0]
                    total += n
        conn.commit()
    print(f"Сырой слой загружен: {total} строк")
    return 0


if __name__ == "__main__":
    sys.exit(main())
