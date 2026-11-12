#!/usr/bin/env python3
"""Загрузка выгрузок (CSV) в сырой слой хранилища: raw_1c, raw_bank, raw_amocrm, raw_sheets.

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
               "bank_accounts", "ostatki_dc", "sotrudniki"],
    "raw_bank": ["statement_lines"],
    "raw_amocrm": ["leads", "amo_users"],
    "raw_sheets": ["cohorts", "cohort_students"],
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
