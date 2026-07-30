# История изменений

Здесь фиксируются все значимые изменения проекта.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
а версии соответствуют [Semantic Versioning](https://semver.org/lang/ru/).

## [В разработке]

## [1.0.0] — 2026-07-29

### Добавлено

- Интерактивное и неинтерактивное подключение SMTP-релея с STARTTLS и
  аутентификацией.
- Независимая от провайдера поддержка SMTP-релеев, задаваемых hostname.
- Автоопределение и переиспользование уже настроенного Postfix `relayhost`.
- Preflight релея без учётных данных: DNS, TCP, SMTP STARTTLS, доверие
  сертификату и проверка hostname.
- Обязательный TLS только для релея через `smtp_tls_policy_maps` без замены
  глобального `smtp_tls_security_level` сервера.
- Определение каталога Postfix и стандартного пути к почтовому логу.
- Fallback между systemd и командой управления Postfix.
- Защита от неоднозначных per-service override sender restrictions.
- Безопасный обход sender-RHSBL для авторизованных пользователей и доверенных
  loopback-сетей с сохранением защиты от подмены отправителя.
- Защищённое хранение учётных данных и безопасный ввод пароля из root-only
  файла.
- Полные снимки конфигурации, автоматический откат, ручное восстановление и
  пересборка hash-карт Postfix.
- Проверка SPF, явно указанного provider include и вложенного лимита
  DNS-запросов без провайдер-специфичных предположений.
- Проверка домена в Spamhaus DBL и исходящего IP в ZEN.
- Реальный тест цепочки доставки с отслеживанием Queue ID.
- Cron-режим наблюдения за изменением статуса DBL.
- Моковый smoke-тест и CI через GitHub Actions.
- Privacy guard для публичных IP, реальных email, распространённых форматов
  credentials, приватных ключей и SMTP URL с учётными данными.

[В разработке]: https://github.com/Anton-Babaskin/postfix-relay-rescue/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Anton-Babaskin/postfix-relay-rescue/releases/tag/v1.0.0
