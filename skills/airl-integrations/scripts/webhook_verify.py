#!/usr/bin/env python3
"""Проверка подписи входящих вебхуков (только стандартная библиотека Python 3.9+).

Как пользоваться в обработчике вебхука:

    from webhook_verify import verify_hmac_sha256, verify_telegram_secret

    body = request.get_data()            # СЫРЫЕ байты тела, до разбора JSON
    ok = verify_hmac_sha256(SECRET, body, request.headers.get("X-Signature"))
    # ok == False → ответить 401 и ничего не делать (кроме счётчика отказов)
    # ok == True  → int_inbox_receive(...), ответить 200, разбирать асинхронно

Правила:
- подпись считается по сырым байтам тела; после json.loads/dumps байты другие
  и подпись не сойдётся;
- сравнение только постоянным по времени hmac.compare_digest, никогда `==`;
- где система присылает время подписи — проверяйте окно (защита от повтора
  перехваченного запроса) и всё равно дедуплицируйте по event_id в int_inbox;
- схема подписи у каждой системы своя (что подписывается, hex или base64,
  префикс, имя заголовка) — берите её из документации системы, а функции ниже
  подставляйте как строительные блоки;
- секреты читаются из переменных окружения на сервере и не печатаются.

Самопроверка:  python3 webhook_verify.py --self-test
Подписать тело для контрактного теста:
  WEBHOOK_SECRET=... python3 webhook_verify.py sign < body.json
"""
import base64
import hashlib
import hmac
import os
import sys
import time
from typing import Mapping, Optional, Union

BytesLike = Union[bytes, bytearray, memoryview]


def _b(value: Union[str, BytesLike]) -> bytes:
    return value.encode("utf-8") if isinstance(value, str) else bytes(value)


def sign_hmac_sha256(secret: Union[str, bytes], body: BytesLike, encoding: str = "hex") -> str:
    """Подпись HMAC-SHA256 тела: hex (по умолчанию) или base64."""
    digest = hmac.new(_b(secret), _b(body), hashlib.sha256).digest()
    if encoding == "hex":
        return digest.hex()
    if encoding == "base64":
        return base64.b64encode(digest).decode("ascii")
    raise ValueError("encoding: hex или base64")


def verify_hmac_sha256(secret: Union[str, bytes], body: BytesLike, signature: Optional[str],
                       encoding: str = "hex", prefix: str = "") -> bool:
    """True, если signature — верная HMAC-SHA256 подпись тела.

    prefix — то, что система ставит перед подписью в заголовке, например "sha256=".
    Пустой секрет или пустая подпись — всегда False (не «пропускаем без проверки»).
    """
    if not secret or not signature:
        return False
    sig = signature.strip()
    if prefix:
        if not sig.startswith(prefix):
            return False
        sig = sig[len(prefix):]
    expected = sign_hmac_sha256(secret, body, encoding)
    if encoding == "hex":
        sig = sig.lower()
    return hmac.compare_digest(expected.encode("ascii"), sig.encode("ascii", "replace"))


def verify_timestamped_hmac(secret: Union[str, bytes], body: BytesLike, signature: Optional[str],
                            timestamp: Optional[str], tolerance_s: int = 300,
                            encoding: str = "hex", prefix: str = "", now: Optional[float] = None) -> bool:
    """Частая схема: подписывается "<timestamp>.<body>", время — секунды Unix.

    Отклоняет запросы старше tolerance_s и «из будущего» дальше того же окна.
    Точный формат строки для подписи — проверить в документации системы.
    """
    if not timestamp or not timestamp.strip().isdigit():
        return False
    ts = int(timestamp.strip())
    current = time.time() if now is None else now
    if abs(current - ts) > tolerance_s:
        return False
    return verify_hmac_sha256(secret, _b(str(ts)) + b"." + _b(body), signature, encoding, prefix)


def verify_telegram_secret(headers: Mapping[str, str], expected: Optional[str]) -> bool:
    """Telegram: секрет, заданный в setWebhook(secret_token=...), приходит в заголовке
    X-Telegram-Bot-Api-Secret-Token. Нет заголовка или не совпал — False (ответ 401).

    headers — словарь заголовков; имя ищется без учёта регистра.
    """
    if not expected:
        return False
    got = None
    for k, v in headers.items():
        if k.lower() == "x-telegram-bot-api-secret-token":
            got = v
            break
    if got is None:
        return False
    return hmac.compare_digest(_b(expected), _b(got))


def verify_basic_auth(authorization: Optional[str], user: str, password: str) -> bool:
    """Проверка заголовка Authorization: Basic ... (так авторизуют вызовы некоторые
    платёжные системы — схему проверить в документации системы). Постоянное время."""
    if not authorization or not authorization.startswith("Basic ") or not password:
        return False
    try:
        decoded = base64.b64decode(authorization[6:].strip(), validate=True)
    except ValueError:  # binascii.Error — подкласс ValueError
        return False
    return hmac.compare_digest(decoded, _b(f"{user}:{password}"))


def _self_test() -> int:
    secret, body = "test-secret", b'{"event_id":"e1","amount":"100.00"}'
    sig = sign_hmac_sha256(secret, body)
    checks = [
        ("hex подпись верна", verify_hmac_sha256(secret, body, sig)),
        ("hex с префиксом", verify_hmac_sha256(secret, body, "sha256=" + sig, prefix="sha256=")),
        ("hex в верхнем регистре", verify_hmac_sha256(secret, body, sig.upper())),
        ("base64", verify_hmac_sha256(secret, body, sign_hmac_sha256(secret, body, "base64"), "base64")),
        ("изменённое тело отклонено", not verify_hmac_sha256(secret, body + b" ", sig)),
        ("чужой секрет отклонён", not verify_hmac_sha256("other", body, sig)),
        ("пустая подпись отклонена", not verify_hmac_sha256(secret, body, "")),
        ("пустой секрет отклонён", not verify_hmac_sha256("", body, sig)),
        ("нет префикса отклонено", not verify_hmac_sha256(secret, body, sig, prefix="sha256=")),
        ("время в окне", verify_timestamped_hmac(secret, body, sign_hmac_sha256(secret, b"1000." + body),
                                                 "1000", now=1100)),
        ("старый запрос отклонён", not verify_timestamped_hmac(secret, body,
                                                               sign_hmac_sha256(secret, b"1000." + body),
                                                               "1000", now=2000)),
        ("telegram верный", verify_telegram_secret({"X-Telegram-Bot-Api-Secret-Token": "abc"}, "abc")),
        ("telegram регистр имени", verify_telegram_secret({"x-telegram-bot-api-secret-token": "abc"}, "abc")),
        ("telegram без заголовка", not verify_telegram_secret({}, "abc")),
        ("telegram неверный", not verify_telegram_secret({"X-Telegram-Bot-Api-Secret-Token": "abd"}, "abc")),
        ("telegram без секрета на сервере", not verify_telegram_secret({"X-Telegram-Bot-Api-Secret-Token": ""}, "")),
        ("basic верный", verify_basic_auth("Basic " + base64.b64encode(b"u:p").decode(), "u", "p")),
        ("basic неверный", not verify_basic_auth("Basic " + base64.b64encode(b"u:x").decode(), "u", "p")),
        ("basic мусор", not verify_basic_auth("Basic !!!", "u", "p")),
    ]
    failed = [name for name, ok in checks if not ok]
    for name, ok in checks:
        print(("✔ " if ok else "✖ ") + name)
    return 1 if failed else 0


def main(argv) -> int:
    if len(argv) > 1 and argv[1] == "--self-test":
        return _self_test()
    if len(argv) > 1 and argv[1] == "sign":
        secret = os.environ.get("WEBHOOK_SECRET")
        if not secret:
            print("Задайте WEBHOOK_SECRET", file=sys.stderr)
            return 2
        enc = argv[2] if len(argv) > 2 else "hex"
        print(sign_hmac_sha256(secret, sys.stdin.buffer.read(), enc))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
