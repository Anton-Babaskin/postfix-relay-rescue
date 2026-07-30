# postfix-relay-rescue

[![CI](https://github.com/Anton-Babaskin/postfix-relay-rescue/actions/workflows/ci.yml/badge.svg)](https://github.com/Anton-Babaskin/postfix-relay-rescue/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Anton-Babaskin/postfix-relay-rescue)](https://github.com/Anton-Babaskin/postfix-relay-rescue/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

Safe SMTP relay failover and Spamhaus sender-RHSBL recovery for Postfix.
Mail-in-a-Box is the primary tested platform.

[Русская документация](README.ru.md)

## The problem

Some Postfix configurations, including Mail-in-a-Box, place
`reject_rhsbl_sender dbl.spamhaus.org` inside
`smtpd_sender_restrictions`. That restriction is also evaluated for
authenticated message submission.

If your own domain appears in Spamhaus DBL, Postfix may reject your own users
before a configured relay ever receives their messages:

```text
554 5.7.1 Sender address blocked using dbl.spamhaus.org
```

An SMTP relay may restore delivery when the origin IP is the problem, but it
does not remove a domain from DBL. The domain is still visible in the envelope,
`From`, DKIM signature, `Message-ID`, and message URLs.

`postfix-relay-rescue` handles both sides safely:

1. It can configure an authenticated STARTTLS relay without replacing the
   host's global SMTP TLS policy.
2. It can let authenticated local users pass the sender-RHSBL check while
   keeping external inbound filtering and sender-login anti-spoofing active.

> [!TIP]
> Read the complete
> [Spamhaus DBL and Postfix incident runbook](docs/spamhaus-dbl-postfix-recovery.md)
> for the forensic audit workflow, safe recovery sequence, delisting process,
> and end-to-end validation checklist.

## Features

- Interactive menu and automation-friendly CLI.
- Auto-detection of an existing Postfix `relayhost`.
- Provider-neutral hostname-based SMTP relay support.
- Hidden password prompt or strict root-owned password file.
- Exact-key credential replacement for safe password rotation.
- Mandatory TLS for the relay through `smtp_tls_policy_maps`.
- Preserves the existing global `smtp_tls_security_level`.
- Detects the active Postfix configuration directory.
- Detects `/var/log/mail.log` and `/var/log/maillog` for delivery tracing.
- Uses systemd when the `postfix` unit is active and falls back to the Postfix
  control command on non-systemd hosts.
- Refuses to report a global sender-RHSBL bypass as safe when `master.cf`
  contains a per-service `smtpd_sender_restrictions` override.
- Safe ordering of:

  ```text
  reject_authenticated_sender_login_mismatch
  permit_sasl_authenticated
  permit_mynetworks
  reject_rhsbl_sender ...
  ```

- Refuses an unattended `permit_mynetworks` bypass when `mynetworks` is wider
  than loopback unless the administrator explicitly approves it.
- Complete root-only snapshots of every managed Postfix file.
- Automatic rollback if `postfix check`, reload, or service health fails.
- Rebuilds restored Postfix hash databases from their source maps.
- DBL, ZEN, relay, TLS-map, SASL-map, queue, and duplicate-key audit.
- Provider-supplied SPF include validation and recursive 10-DNS-lookup budget
  check without guessing provider settings.
- Real test message with Queue ID and next-hop status tracing.
- DBL state-change watcher suitable for cron or another monitoring system.
- Mocked smoke tests that never touch the host's real Postfix configuration.

## What the script does not do

- It does not delist domains or IP addresses.
- It does not edit public DNS records.
- It does not guarantee inbox placement.
- It does not treat `status=sent` as proof of inbox delivery. That status only
  confirms that the next SMTP hop accepted the message.
- It does not support implicit-TLS port 465 in v1. Use a provider's STARTTLS
  port, normally 587 or 2525.

Use the official [Spamhaus Reputation Checker](https://check.spamhaus.org/) for
listing details and removal.

## Compatibility

| Platform | v1 status |
| --- | --- |
| Mail-in-a-Box on Ubuntu | Primary tested platform |
| Standalone Postfix on Debian/Ubuntu | Supported |
| Standalone Postfix on RHEL/Rocky/AlmaLinux | Experimental |
| mailcow/Docker-generated Postfix | Refused; generated configuration |
| Zimbra | Refused; use Zimbra tooling |
| Exim, Exchange, other MTAs | Not supported |

The script manages standard Postfix parameters. It deliberately stops when a
platform generates the configuration or when a per-service restriction
override makes a global `main.cf` change ambiguous.

## Requirements

- A supported Postfix host.
- Bash 4.3 or newer.
- Root access.
- `postfix`, `postmap`, `postqueue`, `sendmail`, `flock`, `realpath`, `ip`,
  and `dig`.
- `libsasl2-modules` for authenticated SMTP relay support.
- An SMTP relay account if relay mode is required.

Install common dependencies:

```bash
sudo apt-get update
sudo apt-get install -y postfix libsasl2-modules dnsutils util-linux
```

## Installation

```bash
git clone https://github.com/Anton-Babaskin/postfix-relay-rescue.git
cd postfix-relay-rescue
chmod +x postfix-relay-rescue.sh
sudo install -m 0755 postfix-relay-rescue.sh /usr/local/sbin/postfix-relay-rescue
```

Inspect the current state before changing anything:

```bash
sudo postfix-relay-rescue status
```

## Quick start

Run the interactive menu:

```bash
sudo postfix-relay-rescue
```

The menu can configure a relay, apply only the safe DBL bypass, run both
operations together, inspect the server, test delivery, restore a snapshot, or
disable the relay.

### Configure any STARTTLS relay

```bash
sudo postfix-relay-rescue setup \
  --host smtp.provider.example \
  --port 2525 \
  --user relay-account \
  --domain example.com \
  --spf-include spf.provider.example
```

The password is requested without echoing it to the terminal. The script does
not identify the provider from its hostname and never guesses an SPF include.
Obtain the exact include from the provider and pass it with `--spf-include`.

If Postfix already has a valid `relayhost`, `setup` and `relay-on` can reuse its
hostname and port when `--host` is omitted:

```bash
sudo postfix-relay-rescue relay-on \
  --user relay-account \
  --domain example.com \
  --spf-include spf.provider.example
```

The credential is still requested securely. Relay auto-detection means reading
the active Postfix next hop; it does not mean identifying or endorsing a
commercial provider.

### Non-interactive password input

Do not put SMTP passwords in arguments, environment variables, shell history,
or CI logs.

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

The password file must:

- be a regular non-symlink file;
- be owned by root;
- have exactly mode `0400` or `0600`;
- contain exactly one non-empty line.

Re-running `relay-on` replaces the credential for the exact active
`[host]:port` key without deleting unrelated entries.

## Commands

```text
postfix-relay-rescue                         interactive menu
postfix-relay-rescue setup [options]         relay + safe DBL bypass
postfix-relay-rescue relay-on [options]      configure relay only
postfix-relay-rescue relay-off               return to direct delivery
postfix-relay-rescue fix-submission          apply safe sender-RHSBL bypass
postfix-relay-rescue status [domain]         full configuration and reputation audit
postfix-relay-rescue spf [domain]            SPF and DNS lookup-budget audit
postfix-relay-rescue watch [domain]          report DBL state changes
postfix-relay-rescue test [recipient]        send and trace a real test message
postfix-relay-rescue backups                 list snapshots
postfix-relay-rescue restore [snapshot]      restore a snapshot
```

See every option:

```bash
postfix-relay-rescue help
```

## Safe DBL bypass only

If the relay is already configured and Postfix rejects authenticated users
because their own sender domain is listed:

```bash
sudo postfix-relay-rescue fix-submission
```

The script keeps `reject_authenticated_sender_login_mismatch` before the permit
rules. An authenticated user therefore cannot send as another local user.

On a standard Mail-in-a-Box host, `mynetworks` contains loopback networks only.
If the server trusts additional networks, the script warns and requires
explicit confirmation because every trusted address would bypass sender RHSBL
checks.

If `master.cf` overrides `smtpd_sender_restrictions` for an individual service,
v1 refuses to change the global restriction and asks for a manual review.

## SPF audit

```bash
sudo postfix-relay-rescue spf example.com \
  --spf-include spf.provider.example
```

The audit detects:

- no SPF record;
- multiple SPF records and resulting `PermError`;
- a missing relay-provider include;
- nested SPF trees that can exceed the RFC limit of ten DNS lookups.

The script only prints a recommendation. Apply DNS changes through your
authoritative DNS provider. Mail-in-a-Box users can do this in Custom DNS.

## Delivery-chain test

```bash
sudo postfix-relay-rescue test test@example.net \
  --from postmaster@example.com \
  --timeout 90
```

The test creates a unique `Message-ID`, finds the Postfix Queue ID in
`/var/log/mail.log` or `/var/log/maillog`, and waits for `sent`, `deferred`, or
`bounced`. Set `PRR_MAILLOG` if the active file has a different path.
Journald-only tracing is not supported in v1.

`sent` means accepted by the next hop. For final delivery, inspect the relay
dashboard and the recipient mailbox headers.

## DBL watch mode

Establish the first baseline:

```bash
sudo postfix-relay-rescue watch example.com
```

Example cron entry:

```cron
*/30 * * * * /usr/local/sbin/postfix-relay-rescue watch example.com --flush-on-delist
```

Unchanged state is silent. State changes are written to stdout and return:

| Exit code | Meaning |
| ---: | --- |
| `10` | Domain became listed |
| `11` | Domain was delisted |
| `12` | DNS/Spamhaus query error |
| `13` | Query recovered and domain is clean |

`--flush-on-delist` requests `postqueue -f`. Messages rejected with `NOQUEUE`
were never queued and must be sent again manually.

## Disable or restore

Return to direct delivery:

```bash
sudo postfix-relay-rescue relay-off
```

Remove only the active relay credential as well:

```bash
sudo postfix-relay-rescue relay-off --purge-credentials
```

List and restore complete snapshots:

```bash
sudo postfix-relay-rescue backups
sudo postfix-relay-rescue restore
sudo postfix-relay-rescue restore SNAPSHOT_NAME --yes
```

Every write operation first creates a `0700` snapshot directory under:

```text
/var/backups/postfix-relay-rescue/
```

Snapshots include `main.cf`, SASL source/database maps, TLS policy
source/database maps, and non-secret managed-state metadata.

## Files managed on the server

```text
/etc/postfix/main.cf
/etc/postfix/sasl_passwd
/etc/postfix/sasl_passwd.db
/etc/postfix/relay_tls_policy
/etc/postfix/relay_tls_policy.db
<Postfix config directory>/postfix-relay-rescue.state
/var/backups/postfix-relay-rescue/
/var/lib/postfix-relay-rescue/
/var/log/postfix-relay-rescue.log
```

The metadata state file does not contain the relay password. The Postfix
configuration directory is discovered with `postconf`; the paths above show
the common Debian/Ubuntu layout.

## Configuration regeneration

Mail-in-a-Box upgrades and other configuration-management systems can
regenerate `main.cf`. After such a change, run:

```bash
sudo postfix-relay-rescue status
```

Reapply the sender-RHSBL bypass if the status command reports that authenticated
users can again be rejected.

## Development

Run local checks:

```bash
bash -n postfix-relay-rescue.sh tests/run-smoke.sh tests/mock-bin/prr-mock
shellcheck -x postfix-relay-rescue.sh tests/run-smoke.sh tests/mock-bin/prr-mock
bash tests/run-smoke.sh
```

The smoke suite replaces Postfix, DNS, systemd, queue, and sendmail commands
with temporary mocks. It verifies credential rotation, idempotence, automatic
rollback, restored-map rebuilding, generic relay support, SPF lookup limits,
DBL transitions, queue flushing, and relay removal.

## Roadmap

- Evidence-oriented incident audit for Postfix/Dovecot logs.
- Optional notification hooks for DBL state changes.
- Relay connectivity and STARTTLS capability preflight checks.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before opening a pull request.

Never attach real SMTP passwords, unredacted SASL maps, or private mail content
to a public issue.

## Author

[Anton Babaskin](https://babaskin.dev/)

## License

[MIT](LICENSE)
