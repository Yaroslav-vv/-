#!/usr/bin/env python3
"""
send_email.py — Отправка письма через Gmail SMTP с вложением.

Использование:
    echo "Тело письма" | python3 send_email.py --subject "Тема"
    echo "Тело письма" | python3 send_email.py --subject "Тема" --attach /path/to/file

Обязательные переменные окружения:
    EMAIL_FROM      Gmail-адрес отправителя (например user@gmail.com)
    EMAIL_PASSWORD  App Password Google (НЕ обычный пароль — см. README)
    EMAIL_TO        Адрес получателя

Коды выхода:
    0  — письмо успешно отправлено
    1  — ошибка (логируется в stderr)
"""

import argparse
import os
import smtplib
import sys
import time
from email import encoders
from email.mime.base import MIMEBase
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path

SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 587


def build_message(
    email_from: str,
    email_to: str,
    subject: str,
    body: str,
    attach_path: str | None,
) -> MIMEMultipart:
    msg = MIMEMultipart()
    msg["From"]    = email_from
    msg["To"]      = email_to
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain", "utf-8"))

    if attach_path:
        p = Path(attach_path)
        if not p.exists():
            print(f"⚠️  Файл вложения не найден: {attach_path}", file=sys.stderr)
        else:
            with p.open("rb") as f:
                part = MIMEBase("application", "octet-stream")
                part.set_payload(f.read())
            encoders.encode_base64(part)
            part.add_header(
                "Content-Disposition",
                f'attachment; filename="{p.name}"',
            )
            msg.attach(part)
            print(f"📎 Вложение добавлено: {p.name}", file=sys.stderr)

    return msg


def send(
    subject: str,
    body: str,
    attach_path: str | None = None,
    max_retries: int = 3,
) -> bool:
    email_from     = os.environ.get("EMAIL_FROM", "").strip()
    email_password = os.environ.get("EMAIL_PASSWORD", "").strip()
    email_to       = os.environ.get("EMAIL_TO", "").strip()

    # Проверяем наличие всех нужных переменных
    missing = [k for k, v in {
        "EMAIL_FROM": email_from,
        "EMAIL_PASSWORD": email_password,
        "EMAIL_TO": email_to,
    }.items() if not v]
    if missing:
        print(f"❌ Не заданы переменные окружения: {', '.join(missing)}", file=sys.stderr)
        return False

    msg = build_message(email_from, email_to, subject, body, attach_path)

    for attempt in range(1, max_retries + 1):
        try:
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as server:
                server.ehlo()
                server.starttls()
                server.ehlo()
                server.login(email_from, email_password)
                server.sendmail(email_from, [email_to], msg.as_bytes())

            print(f"✅ Email отправлен [{attempt}/{max_retries}]: {subject}")
            return True

        except smtplib.SMTPAuthenticationError as e:
            # Неверный пароль — повтор бессмысленен
            print(f"❌ Ошибка аутентификации Gmail: {e}", file=sys.stderr)
            print(
                "   Используй App Password, не обычный пароль!\n"
                "   Инструкция: https://myaccount.google.com/apppasswords",
                file=sys.stderr,
            )
            return False

        except smtplib.SMTPRecipientsRefused as e:
            print(f"❌ Адрес получателя отклонён: {e}", file=sys.stderr)
            return False

        except Exception as e:
            print(f"⚠️  Попытка {attempt}/{max_retries} не удалась: {type(e).__name__}: {e}", file=sys.stderr)
            if attempt < max_retries:
                wait = attempt * 10
                print(f"   Повтор через {wait} сек...", file=sys.stderr)
                time.sleep(wait)

    print(f"❌ Email не отправлен после {max_retries} попыток!", file=sys.stderr)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Отправка email через Gmail SMTP. Тело письма читается из stdin."
    )
    parser.add_argument("--subject",  required=True, help="Тема письма")
    parser.add_argument("--attach",   default=None,  metavar="FILE",
                        help="Путь к файлу-вложению (опционально)")
    parser.add_argument("--retries",  type=int, default=3,
                        help="Количество попыток (по умолчанию 3)")
    args = parser.parse_args()

    body = sys.stdin.read()
    if not body.strip():
        print("❌ Тело письма пустое — передай текст через stdin", file=sys.stderr)
        return 1

    ok = send(args.subject, body, args.attach, args.retries)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
