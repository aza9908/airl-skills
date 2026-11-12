#!/usr/bin/env python3
"""Копирует шаблоны документов навыков в methodology/templates/<навык>/.

Источник правды — skills/<навык>/templates/. Руководства методики ссылаются на
methodology/templates/, поэтому после каждой правки шаблона:

  python3 scripts/sync_templates.py           # скопировать
  python3 scripts/sync_templates.py --check   # только проверить, код 1 — есть расхождения

Папки навыков в methodology/templates/ зеркалятся целиком: лишние файлы удаляются.
Другие файлы methodology/templates/ (например, README.md) не трогаются.
Только стандартная библиотека Python 3.8+.
"""
import argparse
import filecmp
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = {"__pycache__", ".DS_Store"}


def plan(root: Path = ROOT):
    """Список (источник, цель) и лишние файлы в цели."""
    pairs, extra = [], []
    dst_root = root / "methodology" / "templates"
    for tdir in sorted(root.glob("skills/*/templates")):
        skill = tdir.parent.name
        dst = dst_root / skill
        src_files = {p.relative_to(tdir) for p in tdir.rglob("*")
                     if p.is_file() and not (set(p.parts) & SKIP)}
        for rel in sorted(src_files):
            pairs.append((tdir / rel, dst / rel))
        if dst.is_dir():
            for p in sorted(dst.rglob("*")):
                if p.is_file() and p.relative_to(dst) not in src_files:
                    extra.append(p)
    return pairs, extra


def differences(root: Path = ROOT):
    pairs, extra = plan(root)
    diff = [d for s, d in pairs if not d.exists() or not filecmp.cmp(s, d, shallow=False)]
    return diff, extra


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="только проверить")
    a = ap.parse_args(argv)
    diff, extra = differences()
    if a.check:
        for p in diff:
            print(f"устарел или нет: {p.relative_to(ROOT)}")
        for p in extra:
            print(f"лишний: {p.relative_to(ROOT)}")
        return 1 if diff or extra else 0
    pairs, extra = plan()
    n = 0
    for s, d in pairs:
        if not d.exists() or not filecmp.cmp(s, d, shallow=False):
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(s, d)
            n += 1
    for p in extra:
        p.unlink()
    for d in sorted((ROOT / "methodology" / "templates").glob("*/**/"), reverse=True):
        if d.is_dir() and not any(d.iterdir()):
            d.rmdir()
    print(f"Шаблонов: {len(pairs)}, обновлено: {n}, удалено лишних: {len(extra)} → methodology/templates/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
