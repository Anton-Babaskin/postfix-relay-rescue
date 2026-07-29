# postfix-relay-rescue

[![CI](https://github.com/Anton-Babaskin/postfix-relay-rescue/actions/workflows/ci.yml/badge.svg)](https://github.com/Anton-Babaskin/postfix-relay-rescue/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Anton-Babaskin/postfix-relay-rescue)](https://github.com/Anton-Babaskin/postfix-relay-rescue/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

Безопасное подключение резервного SMTP-релея и восстановление отправки при
срабатывании Spamhaus sender-RHSBL в Postfix. Основная протестированная
платформа — Mail-in-a-Box.

[English documentation](README.md)

## Проблема

Некоторые конфигурации Postfix, включая Mail-in-a-Box, размещают проверку
`reject_rhsbl_sender dbl.spamhaus.org` внутри
`smtpd_sender_restrictions`. Это ограничение также применяется к
авторизованной отправке пользователей.

Если собственный домен попадает в Spamhaus DBL, Postfix может отклонять письма
своих пользователей ещё до того, как их получит настроенный SMTP-релей:

```text
554 5.7.1 Sender address blocked using dbl.spamhaus.org
```

SMTP-релей может восстановить доставку, когда проблема связана с репутацией
исходящего IP. Но он не удаляет домен из DBL: домен остаётся виден в envelope,
`From`, DKIM, `Message-ID` и URL внутри письма.

`postfix-relay-rescue` безопасно решает обе части проблемы:

1. Настраивает авторизованный STARTTLS-релей без замены глобальной TLS-политики
   сервера.
2. Пропускает локальных авторизованных пользователей мимо sender-RHSBL,
   сохраняя входящую фильтрацию и защиту от подмены локального отправителя.

## Возможности

- Интерактивное меню и CLI для автоматизации.
- Автоопределение MailBaby и поддержка любых SMTP-релеев по hostname.
- Скрытый ввод пароля или строгий root-only файл с паролем.
- Обновление учётных данных по точному ключу `[host]:port`.
- Обязательный TLS для релея через `smtp_tls_policy_maps`.
- Сохранение текущего глобального `smtp_tls_security_level`.
- Автоопределение каталога конфигурации Postfix.
- Автоопределение `/var/log/mail.log` или `/var/log/maillog` для трассировки.
- Использование systemd при активном юните `postfix` и fallback на команду
  управления Postfix на системах без systemd.
- Отказ объявлять глобальный sender-RHSBL bypass безопасным, если `master.cf`
  содержит отдельный override `smtpd_sender_restrictions` для сервиса.
- Безопасный порядок правил:

  ```text
  reject_authenticated_sender_login_mismatch
  permit_sasl_authenticated
  permit_mynetworks
  reject_rhsbl_sender ...
  ```

- Отказ от автоматического `permit_mynetworks`, если `mynetworks` шире
  loopback-сетей и администратор явно это не подтвердил.
- Полные root-only снимки всех изменяемых файлов Postfix.
- Автоматический откат при ошибке `postfix check`, reload или состоянии
  сервиса.
- Пересборка восстановленных hash-карт Postfix из текстовых источников.
- Аудит DBL, ZEN, SPF, relay, TLS-map, SASL-map, очереди и дублирующихся
  параметров.
- Проверка provider include в SPF и вложенного лимита из десяти DNS-запросов.
- Поддержка актуального и старого SPF include MailBaby.
- Реальное тестовое письмо с отслеживанием Queue ID и результата next hop.
- Режим наблюдения за изменением DBL для cron или системы мониторинга.
- Моковые smoke-тесты, не затрагивающие реальную конфигурацию Postfix.

## Чего скрипт не делает

- Не удаляет домены или IP из чёрных списков.
- Не изменяет публичные DNS-записи.
- Не гарантирует попадание письма во «Входящие».
- Не считает `status=sent` доказательством конечной доставки. Этот статус
  означает только, что следующий SMTP-узел принял письмо.
- В v1 не поддерживает implicit TLS на порту 465. Используйте STARTTLS-порт
  провайдера, обычно 587 или 2525.

Информацию о листинге и удаление выполняйте через официальный
[Spamhaus Reputation Checker](https://check.spamhaus.org/).

## Совместимость

| Платформа | Статус в v1 |
|---|---|
| Mail-in-a-Box на Ubuntu | Основная протестированная платформа |
| Обычный Postfix на Debian/Ubuntu | Поддерживается |
| Обычный Postfix на RHEL/Rocky/AlmaLinux | Экспериментально: отличаются пакеты и логи |
| mailcow/Postfix с генерируемым Docker-конфигом | Отказ: используйте штатные шаблоны стека |
| Zimbra | Отказ: используйте инструменты Zimbra |
| Exim, Exchange и другие MTA | Не поддерживаются |

Скрипт управляет стандартными параметрами Postfix. Он останавливается, если
платформа генерирует конфигурацию или per-service override делает изменение
глобального `main.cf` неоднозначным.

## Требования

- Поддерживаемый сервер Postfix.
- Bash 4.3 или новее.
- Root-доступ.
- `postfix`, `postmap`, `postqueue`, `sendmail`, `flock`, `realpath`, `ip` и
  `dig`.
- `libsasl2-modules` для SMTP-аутентификации на релей.
- Учётная запись SMTP-релея, если требуется relay mode.

Установка основных зависимостей:

```bash
sudo apt-get update
sudo apt-get install -y postfix libsasl2-modules dnsutils util-linux
```

## Установка

```bash
git clone https://github.com/Anton-Babaskin/postfix-relay-rescue.git
cd postfix-relay-rescue
chmod +x postfix-relay-rescue.sh
sudo install -m 0755 postfix-relay-rescue.sh /usr/local/sbin/postfix-relay-rescue
```

Перед изменениями проверьте текущее состояние:

```bash
sudo postfix-relay-rescue status
```

## Быстрый запуск

Открыть интерактивное меню:

```bash
sudo postfix-relay-rescue
```

Через меню можно подключить релей, применить только безопасный DBL bypass,
выполнить обе операции вместе, проверить сервер, отправить тест, восстановить
снимок или отключить релей.

### MailBaby

Интерактивное значение по умолчанию — `relay.mailbaby.net:587`:

```bash
sudo postfix-relay-rescue setup \
  --host relay.mailbaby.net \
  --port 587 \
  --user mb12345 \
  --domain example.com
```

Пароль запрашивается без отображения в терминале. Для MailBaby автоматически
проверяется:

```text
include:spf-c.mailbaby.net
```

Старый `include:relay.mailbaby.net` тоже распознаётся.

### Любой STARTTLS-релей

```bash
sudo postfix-relay-rescue setup \
  --host smtp.provider.example \
  --port 2525 \
  --user relay-account \
  --domain example.com \
  --spf-include spf.provider.example
```

Для стороннего провайдера скрипт не угадывает SPF include. Получите его у
провайдера и передайте через `--spf-include`.

### Неинтерактивный ввод пароля

Не передавайте SMTP-пароль в аргументах, переменных окружения, shell history
или CI-логах.

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

Файл с паролем должен:

- быть обычным файлом, а не symlink;
- принадлежать root;
- иметь строго права `0400` или `0600`;
- содержать ровно одну непустую строку.

Повторный `relay-on` заменяет данные для точного активного ключа
`[host]:port`, не удаляя посторонние записи.

## Команды

```text
postfix-relay-rescue                         интерактивное меню
postfix-relay-rescue setup [options]         релей + безопасный DBL bypass
postfix-relay-rescue relay-on [options]      только настройка релея
postfix-relay-rescue relay-off               возврат к прямой доставке
postfix-relay-rescue fix-submission          безопасный sender-RHSBL bypass
postfix-relay-rescue status [domain]         полный аудит конфигурации и репутации
postfix-relay-rescue spf [domain]            аудит SPF и лимита DNS-запросов
postfix-relay-rescue watch [domain]          отслеживание изменений DBL
postfix-relay-rescue test [recipient]        отправка и трассировка теста
postfix-relay-rescue backups                 список снимков
postfix-relay-rescue restore [snapshot]      восстановление снимка
```

Все параметры:

```bash
postfix-relay-rescue help
```

## Только безопасный DBL bypass

Если релей уже настроен, но Postfix отклоняет авторизованных пользователей
из-за листинга их собственного домена:

```bash
sudo postfix-relay-rescue fix-submission
```

Скрипт сохраняет `reject_authenticated_sender_login_mismatch` перед permit-
правилами. Поэтому авторизованный пользователь не сможет отправлять письмо от
имени другого локального пользователя.

На стандартном MIAB в `mynetworks` находятся только loopback-сети. Если сервер
доверяет дополнительным сетям, скрипт предупредит и потребует явного
подтверждения: любой доверенный адрес также обойдёт sender-RHSBL.

Если `master.cf` переопределяет `smtpd_sender_restrictions` для отдельного
сервиса, v1 откажется менять глобальное правило и потребует ручной проверки.

## Аудит SPF

MailBaby:

```bash
sudo postfix-relay-rescue spf example.com \
  --spf-include spf-c.mailbaby.net
```

Другой провайдер:

```bash
sudo postfix-relay-rescue spf example.com \
  --spf-include spf.provider.example
```

Проверяются:

- отсутствие SPF;
- несколько SPF-записей и возникающий `PermError`;
- отсутствие include SMTP-провайдера;
- актуальный и старый include MailBaby;
- отсутствие признаков авторизации origin-сервера для MailBaby;
- вложенное SPF-дерево, превышающее лимит из десяти DNS-запросов.

Скрипт только печатает рекомендацию. Изменения нужно внести у авторитетного
DNS-провайдера. Пользователи Mail-in-a-Box могут сделать это через Custom DNS.

## Тест цепочки доставки

```bash
sudo postfix-relay-rescue test test@example.net \
  --from postmaster@example.com \
  --timeout 90
```

Тест создаёт уникальный `Message-ID`, находит Postfix Queue ID в
`/var/log/mail.log` или `/var/log/maillog` и ожидает `sent`, `deferred` либо
`bounced`. Если активный файл имеет другой путь, задайте `PRR_MAILLOG`.
Journald-only трассировка в v1 не поддерживается.

`sent` означает, что MailBaby или другой next hop принял письмо. Для проверки
конечной доставки смотрите панель релея и заголовки письма у получателя.

## Наблюдение за DBL

Первый запуск создаёт базовое состояние:

```bash
sudo postfix-relay-rescue watch example.com
```

Пример для cron:

```cron
*/30 * * * * /usr/local/sbin/postfix-relay-rescue watch example.com --flush-on-delist
```

При неизменном состоянии вывод отсутствует. При изменениях используются коды:

| Код | Значение |
|---:|---|
| `10` | Домен попал в DBL |
| `11` | Домен удалён из DBL |
| `12` | Ошибка DNS/запроса Spamhaus |
| `13` | Запрос восстановился, домен чист |

`--flush-on-delist` выполняет `postqueue -f`. Сообщения с `NOQUEUE` никогда не
попадали в очередь и должны быть отправлены заново вручную.

## Отключение и восстановление

Вернуться к прямой доставке:

```bash
sudo postfix-relay-rescue relay-off
```

Дополнительно удалить данные только активного релея:

```bash
sudo postfix-relay-rescue relay-off --purge-credentials
```

Просмотр и восстановление полных снимков:

```bash
sudo postfix-relay-rescue backups
sudo postfix-relay-rescue restore
sudo postfix-relay-rescue restore SNAPSHOT_NAME --yes
```

Перед каждой записью создаётся каталог снимка с правами `0700`:

```text
/var/backups/postfix-relay-rescue/
```

В снимок входят `main.cf`, текстовые и `.db`-карты SASL, текстовые и `.db`-
карты TLS policy, а также несекретные служебные метаданные.

## Изменяемые файлы

```text
/etc/postfix/main.cf
/etc/postfix/sasl_passwd
/etc/postfix/sasl_passwd.db
/etc/postfix/relay_tls_policy
/etc/postfix/relay_tls_policy.db
<каталог конфигурации Postfix>/postfix-relay-rescue.state
/var/backups/postfix-relay-rescue/
/var/lib/postfix-relay-rescue/
/var/log/postfix-relay-rescue.log
```

Служебный state-файл не содержит пароль от релея. Каталог конфигурации
определяется через `postconf`; выше показан обычный путь Debian/Ubuntu.

## Перегенерация конфигурации

MIAB и другие системы управления конфигурацией могут пересоздать `main.cf`.
После такого изменения выполните:

```bash
sudo postfix-relay-rescue status
```

Повторно примените sender-RHSBL bypass, если status сообщает, что собственные
авторизованные пользователи снова могут быть отклонены.

## Разработка

Локальная проверка:

```bash
bash -n postfix-relay-rescue.sh tests/run-smoke.sh tests/mock-bin/prr-mock
shellcheck -x postfix-relay-rescue.sh tests/run-smoke.sh tests/mock-bin/prr-mock
bash tests/run-smoke.sh
```

Smoke-тест заменяет Postfix, DNS, systemd, очередь и sendmail временными моками.
Он проверяет ротацию пароля, идемпотентность, автоматический rollback,
пересборку восстановленных карт, сторонний релей, лимит SPF, изменения DBL,
flush очереди и отключение релея.

## План развития

- Доказательный анализ инцидентов по логам Postfix/Dovecot.
- Опциональные уведомления при изменении DBL.
- Дополнительные проверки популярных relay-провайдеров без хранения паролей.

## Участие и безопасность

Перед Pull Request прочитайте [CONTRIBUTING.md](CONTRIBUTING.md),
[SECURITY.md](SECURITY.md) и [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Никогда не прикладывайте к публичному issue реальные SMTP-пароли, неочищенные
SASL-карты или содержимое частной переписки.

## Автор

[Anton Babaskin](https://babaskin.dev/)

## Лицензия

[MIT](LICENSE)
