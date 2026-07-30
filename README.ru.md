<div align="center">

# Postfix Relay Rescue

**Независимое от провайдера SMTP-релея восстановление Postfix и безопасный sender-RHSBL bypass**

[![CI](https://github.com/Anton-Babaskin/postfix-relay-rescue/actions/workflows/ci.yml/badge.svg)](https://github.com/Anton-Babaskin/postfix-relay-rescue/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Anton-Babaskin/postfix-relay-rescue?display_name=tag&sort=semver)](https://github.com/Anton-Babaskin/postfix-relay-rescue/releases)
[![License](https://img.shields.io/github/license/Anton-Babaskin/postfix-relay-rescue)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-Bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Postfix](https://img.shields.io/badge/MTA-Postfix-336791)](https://www.postfix.org/)

[Быстрый запуск](#быстрый-запуск) · [Выбор действия](#выберите-нужное-действие) ·
[Incident runbook](docs/spamhaus-dbl-postfix-recovery.md) ·
[English](README.md)

</div>

---

## Для чего нужен проект

У похожей проблемы с отправкой могут быть две разные причины:

1. Репутация исходящего IP испорчена, и хороший SMTP-релей может временно
   восстановить маршрут.
2. Домен отправителя попал в Spamhaus DBL, после чего локальное правило
   `reject_rhsbl_sender` начало отклонять собственных авторизованных
   пользователей ещё до очереди.

Проект закрывает оба сценария без угадывания провайдера, паролей в shell
history и замены глобальной TLS-политики сервера.

> [!IMPORTANT]
> Релей меняет исходящий IP. Он **не** исправляет листинг домена, не скрывает
> домен в `From`, DKIM и `Message-ID` и не заменяет процедуру удаления из
> Spamhaus.

## Выберите нужное действие

| Что наблюдается | Первое действие | Команда |
| --- | --- | --- |
| Релей ещё не проверен | Проверить DNS, TCP, STARTTLS и сертификат | `postfix-relay-rescue preflight` |
| Проблема в репутации исходящего IP | Подключить авторизованный релей | `postfix-relay-rescue relay-on` |
| Собственный домен в DBL, локальные пользователи получают `554` | Исправить порядок sender restrictions | `postfix-relay-rescue fix-submission` |
| Присутствуют обе проблемы | Транзакционно применить релей и bypass | `postfix-relay-rescue setup` |
| Причина неясна | Сначала провести аудит | `postfix-relay-rescue status` |
| Изменение неудачно | Восстановить полный снимок | `postfix-relay-rescue restore` |

Полная доказательная процедура находится в
[runbook по инциденту Spamhaus DBL](docs/spamhaus-dbl-postfix-recovery.md).

## Модель безопасности

- Пароль поступает через скрытый prompt или root-only файл `0400`/`0600`.
- Перед каждой записью создаётся полный root-only снимок.
- Ошибка `postfix check`, reload или health-check запускает rollback.
- TLS обязателен только для выбранного next hop через `smtp_tls_policy_maps`.
- Глобальный `smtp_tls_security_level` не заменяется.
- Ротация меняет только точную запись `[host]:port`.
- `reject_authenticated_sender_login_mismatch` остаётся перед permit-правилами.
- Широкий `mynetworks` требует явного подтверждения администратора.
- Генерируемые и неоднозначные конфигурации отклоняются.
- CI блокирует публичные IP, реальные email, приватные ключи, распространённые
  токены и SMTP URL с учётными данными.

## Быстрый запуск

### 1. Установка

```bash
git clone https://github.com/Anton-Babaskin/postfix-relay-rescue.git
cd postfix-relay-rescue
chmod +x postfix-relay-rescue.sh
sudo install -m 0755 postfix-relay-rescue.sh \
  /usr/local/sbin/postfix-relay-rescue
```

Основные зависимости для Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y \
  postfix libsasl2-modules dnsutils util-linux openssl
```

### 2. Проверка до изменений

```bash
sudo postfix-relay-rescue status
```

### 3. Preflight релея без учётных данных

```bash
postfix-relay-rescue preflight \
  --host smtp.provider.example \
  --port 587
```

Команда проверяет DNS, выполняет реальный SMTP STARTTLS handshake и валидирует
цепочку сертификата и hostname. Пароль не отправляется, Postfix не изменяется.

### 4. Сначала опубликуйте SPF-авторизацию релея

Получите точный include у провайдера и не угадывайте его:

```text
v=spf1 mx include:spf.provider.example -all
```

Затем проверьте вложенный SPF-бюджет:

```bash
sudo postfix-relay-rescue spf example.com \
  --spf-include spf.provider.example
```

> [!WARNING]
> Если включить релей до его авторизации в SPF, появятся новые SPF failures и
> ситуация может ухудшиться. Лимит RFC из 10 DNS-запросов учитывает `a`, `mx`,
> `ptr`, `exists`, `include` и `redirect`; вложенные include провайдера
> расходуют тот же бюджет.

### 5. Настройка релея и безопасного DBL bypass

```bash
sudo postfix-relay-rescue setup \
  --host smtp.provider.example \
  --port 587 \
  --user relay-account \
  --domain example.com \
  --spf-include spf.provider.example
```

Пароль запрашивается без отображения. Hostname рассматривается как обычный
SMTP endpoint: скрипт не определяет, не рекламирует и не настраивает
специфичный коммерческий сервис.

### 6. Проверка цепочки доставки

```bash
sudo postfix-relay-rescue test test-recipient@example.net \
  --from postmaster@example.com \
  --timeout 90
```

`status=sent` означает только приём следующим SMTP-узлом. Проверяйте заголовки
полученного письма и, при наличии, панель релея.

## Команды

| Команда | Назначение |
| --- | --- |
| `preflight` | DNS, TCP, STARTTLS, доверие сертификату и hostname релея |
| `setup` | Релей и безопасный sender-RHSBL bypass |
| `relay-on` | Настройка или ротация авторизованного STARTTLS-релея |
| `relay-off` | Возврат к direct delivery и опциональное удаление credentials |
| `fix-submission` | Permit авторизованных/local клиентов до sender RHSBL |
| `status` | Аудит DBL, ZEN, SPF, Postfix, карт, очереди и дублей |
| `spf` | Проверка include и вложенного DNS lookup budget |
| `watch` | Изменения DBL для cron/мониторинга |
| `test` | Контрольное письмо и трассировка Queue ID |
| `backups` | Список полных снимков |
| `restore` | Восстановление снимка и пересборка hash-карт |

```bash
postfix-relay-rescue help
```

### Безопасный неинтерактивный пароль

```bash
sudo install -m 0600 /dev/null /root/relay-password
sudoedit /root/relay-password

sudo postfix-relay-rescue relay-on \
  --host smtp.provider.example \
  --port 587 \
  --user relay-account \
  --password-file /root/relay-password \
  --domain example.com \
  --spf-include spf.provider.example
```

Не помещайте SMTP-пароль в аргументы, environment, shell history, документацию,
скриншоты, issues или CI logs.

## Безопасный порядок sender-RHSBL

Скрипт сохраняет anti-spoofing и меняет только необходимый порядок:

```text
reject_authenticated_sender_login_mismatch
permit_sasl_authenticated
permit_mynetworks
reject_rhsbl_sender ...
```

Внешние неавторизованные отправители по-прежнему проверяются. Письма,
отклонённые как `NOQUEUE`, не попадали в очередь и должны быть отправлены снова.

## Мониторинг DBL

```bash
sudo postfix-relay-rescue watch example.com
```

```cron
*/30 * * * * /usr/local/sbin/postfix-relay-rescue watch example.com --flush-on-delist
```

| Код | Изменение |
| ---: | --- |
| `10` | Домен появился в DBL |
| `11` | Домен удалён из DBL |
| `12` | Ошибка DNS/запроса Spamhaus |
| `13` | DNS восстановился, домен чист |

Watcher использует локальный resolver хоста. Не проверяйте Spamhaus через
публичные recursive resolvers: policy error легко принять за код листинга.

## Набор инструментов для почтовых инцидентов

| Проект | Назначение |
| --- | --- |
| [postfix-relay-rescue](https://github.com/Anton-Babaskin/postfix-relay-rescue) | Безопасное восстановление Postfix, релей, rollback и DBL monitoring |
| [mail-sec-audit](https://github.com/Anton-Babaskin/mail-sec-audit) | Read-only аудит хоста, MTA, DNS, TLS, firewall и authentication |
| [smtp-egress-audit](https://github.com/Anton-Babaskin/smtp-egress-audit) | Привязка неожиданных исходящих SMTP-соединений к процессам и сервисам |
| [mail_analyzer.sh](https://github.com/Anton-Babaskin/mail_analyzer.sh) | Лёгкая Queue-ID статистика входящих и исходящих доменов |

Инструменты дополняют друг друга. Статистика помогает ориентироваться, но
выводы требуют логов, Queue ID, DSN, mailbox evidence, DMARC reports и ответов
репутационного провайдера.

<details>
<summary><strong>Совместимость</strong></summary>

| Платформа | Статус v1 |
| --- | --- |
| Mail-in-a-Box на Ubuntu | Основная протестированная платформа |
| Обычный Postfix на Debian/Ubuntu | Поддерживается |
| Обычный Postfix на RHEL/Rocky/AlmaLinux | Экспериментально |
| mailcow/Postfix с генерируемым Docker-конфигом | Отказ; используйте templates |
| Zimbra | Отказ; используйте Zimbra tooling |
| Exim, Exchange и другие MTA | Не поддерживаются |

Реализация использует стандартные параметры Postfix и не привязана к
провайдеру релея. Per-service overrides в `master.cf` отклоняются, если
глобальное изменение неоднозначно.

</details>

<details>
<summary><strong>Снимки, восстановление и изменяемые файлы</strong></summary>

```bash
sudo postfix-relay-rescue backups
sudo postfix-relay-rescue restore
sudo postfix-relay-rescue relay-off --purge-credentials
```

Управляются активный `main.cf`, исходные и `.db`-карты SASL, TLS policy,
несекретный state, root-only snapshots, watcher state и лог скрипта. Каталог
Postfix определяется через `postconf`.

Mail-in-a-Box и другие системы управления могут пересоздать `main.cf`. После
обновлений выполните `sudo postfix-relay-rescue status`.

</details>

<details>
<summary><strong>Разработка и privacy checks</strong></summary>

```bash
bash -n \
  postfix-relay-rescue.sh \
  tests/run-smoke.sh \
  tests/mock-bin/prr-mock \
  tests/privacy-scan.sh

shellcheck -x \
  postfix-relay-rescue.sh \
  tests/run-smoke.sh \
  tests/mock-bin/prr-mock \
  tests/privacy-scan.sh

bash tests/run-smoke.sh
bash tests/privacy-scan.sh
```

Smoke suite использует временные моки и не касается рабочей конфигурации
Postfix.

</details>

## Границы проекта

Проект не удаляет домены/IP из листов, не изменяет authoritative DNS, не
гарантирует inbox placement, не поддерживает implicit TLS порт 465 и не
переписывает генерируемую конфигурацию. Для проверки и удаления используйте
официальный [Spamhaus Reputation Checker](https://check.spamhaus.org/).

## Участие

См. [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) и
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Автор и лицензия

[Anton Babaskin](https://babaskin.dev/) · [MIT](LICENSE)
