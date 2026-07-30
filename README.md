<div align="center">

# Postfix Relay Rescue

**Provider-neutral SMTP relay failover and safe sender-RHSBL recovery for Postfix**

[![CI](https://github.com/Anton-Babaskin/postfix-relay-rescue/actions/workflows/ci.yml/badge.svg)](https://github.com/Anton-Babaskin/postfix-relay-rescue/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Anton-Babaskin/postfix-relay-rescue?display_name=tag&sort=semver)](https://github.com/Anton-Babaskin/postfix-relay-rescue/releases)
[![License](https://img.shields.io/github/license/Anton-Babaskin/postfix-relay-rescue)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-Bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Postfix](https://img.shields.io/badge/MTA-Postfix-336791)](https://www.postfix.org/)

[Quick start](#quick-start) · [Decision guide](#choose-the-right-action) ·
[Incident runbook](docs/spamhaus-dbl-postfix-recovery.md) ·
[Русская версия](README.ru.md)

</div>

---

## Why this exists

A Postfix server can suffer two different failures that look similar:

1. The outbound IP loses reputation, so a reputable SMTP relay may restore the
   route.
2. The sender domain enters Spamhaus DBL, and a local
   `reject_rhsbl_sender` rule starts rejecting the server's own authenticated
   users before their messages reach the queue.

This project handles both recovery paths without guessing the relay provider,
putting passwords in shell history, or replacing the server's global TLS
policy.

> [!IMPORTANT]
> A relay changes the outbound IP. It does **not** repair a domain listing,
> hide the domain in `From`/DKIM/`Message-ID`, or replace the Spamhaus removal
> process.

## Choose the right action

| What you observe | First action | Command |
| --- | --- | --- |
| Relay endpoint is not yet trusted | Verify DNS, TCP, STARTTLS, and certificate | `postfix-relay-rescue preflight` |
| Origin IP reputation is the problem | Configure an authenticated relay | `postfix-relay-rescue relay-on` |
| Own domain is in DBL and local users receive `554` | Fix sender-restriction order | `postfix-relay-rescue fix-submission` |
| Both failures are present | Apply relay and safe bypass transactionally | `postfix-relay-rescue setup` |
| Cause is unclear | Audit first; do not change routing blindly | `postfix-relay-rescue status` |
| Change went wrong | Restore the last complete snapshot | `postfix-relay-rescue restore` |

For a full evidence-preserving investigation, use the
[Spamhaus DBL incident runbook](docs/spamhaus-dbl-postfix-recovery.md).

## Safety model

- Passwords come from a hidden prompt or a root-owned `0400`/`0600` file.
- Every write starts with a complete root-only snapshot.
- Failed `postfix check`, reload, or health validation triggers rollback.
- Relay TLS is enforced per next hop through `smtp_tls_policy_maps`.
- The existing global `smtp_tls_security_level` is preserved.
- Credential rotation replaces only the exact `[host]:port` map entry.
- `reject_authenticated_sender_login_mismatch` stays before permit rules.
- Broad `mynetworks` values require explicit administrator approval.
- Generated or ambiguous Postfix configurations are refused.
- CI rejects public IP addresses, non-example email addresses, private keys,
  common access-token formats, and credential-bearing SMTP URLs.

## Quick start

### 1. Install

```bash
git clone https://github.com/Anton-Babaskin/postfix-relay-rescue.git
cd postfix-relay-rescue
chmod +x postfix-relay-rescue.sh
sudo install -m 0755 postfix-relay-rescue.sh \
  /usr/local/sbin/postfix-relay-rescue
```

Common Debian/Ubuntu dependencies:

```bash
sudo apt-get update
sudo apt-get install -y \
  postfix libsasl2-modules dnsutils util-linux openssl
```

### 2. Inspect before changing

```bash
sudo postfix-relay-rescue status
```

### 3. Preflight the relay without credentials

```bash
postfix-relay-rescue preflight \
  --host smtp.provider.example \
  --port 587
```

This performs DNS resolution and a real SMTP STARTTLS handshake, validates the
certificate chain and hostname, sends no password, and changes no Postfix
setting.

### 4. Publish relay SPF authorization first

Obtain the exact include from the provider. Do not guess it:

```text
v=spf1 mx include:spf.provider.example -all
```

Then verify the recursive SPF lookup budget:

```bash
sudo postfix-relay-rescue spf example.com \
  --spf-include spf.provider.example
```

> [!WARNING]
> Enabling a relay before publishing its SPF authorization can create fresh SPF
> failures and make the incident worse. The RFC limit of 10 DNS lookups counts
> `a`, `mx`, `ptr`, `exists`, `include`, and `redirect`; nested provider
> includes consume the same budget.

### 5. Configure the relay and safe DBL bypass

```bash
sudo postfix-relay-rescue setup \
  --host smtp.provider.example \
  --port 587 \
  --user relay-account \
  --domain example.com \
  --spf-include spf.provider.example
```

The password is requested without terminal echo. The hostname is treated as a
generic SMTP endpoint; the script does not identify, advertise, or configure
any provider-specific product.

### 6. Validate the delivery chain

```bash
sudo postfix-relay-rescue test test-recipient@example.net \
  --from postmaster@example.com \
  --timeout 90
```

`status=sent` means the next SMTP hop accepted the message. It does not prove
inbox placement. Verify the received headers and, when applicable, the relay
dashboard.

## Commands

| Command | Purpose |
| --- | --- |
| `preflight` | Verify relay DNS, TCP, STARTTLS, certificate trust, and hostname |
| `setup` | Configure relay and safe sender-RHSBL bypass |
| `relay-on` | Configure or rotate an authenticated STARTTLS relay |
| `relay-off` | Return to direct delivery; optionally purge the active credential |
| `fix-submission` | Permit authenticated/local submission before sender RHSBL |
| `status` | Audit DBL, ZEN, SPF, Postfix, maps, queue, and duplicate keys |
| `spf` | Validate provider include and recursive DNS-lookup budget |
| `watch` | Report DBL state transitions for cron/monitoring |
| `test` | Send a controlled message and trace its Queue ID |
| `backups` | List complete configuration snapshots |
| `restore` | Restore a selected snapshot and rebuild hash maps |

```bash
postfix-relay-rescue help
```

### Secure non-interactive password input

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

Never place an SMTP password in command arguments, environment variables,
shell history, documentation, screenshots, issues, or CI logs.

## The safe sender-RHSBL order

The script changes only the order needed to preserve anti-spoofing and local
submission:

```text
reject_authenticated_sender_login_mismatch
permit_sasl_authenticated
permit_mynetworks
reject_rhsbl_sender ...
```

External unauthenticated senders are still checked. Messages previously
rejected as `NOQUEUE` were never queued and must be sent again.

## DBL monitoring

```bash
sudo postfix-relay-rescue watch example.com
```

```cron
*/30 * * * * /usr/local/sbin/postfix-relay-rescue watch example.com --flush-on-delist
```

| Exit | State change |
| ---: | --- |
| `10` | Domain became listed |
| `11` | Domain was delisted |
| `12` | DNS/Spamhaus query error |
| `13` | Query recovered and domain is clean |

The watcher queries through the host's local resolver. Do not diagnose
Spamhaus using public recursive resolvers: policy error responses can be
mistaken for listing codes.

## Mail operations toolkit

These repositories cover separate stages of the same incident workflow:

| Project | Use it for |
| --- | --- |
| [postfix-relay-rescue](https://github.com/Anton-Babaskin/postfix-relay-rescue) | Safe Postfix recovery, relay configuration, rollback, and DBL monitoring |
| [mail-sec-audit](https://github.com/Anton-Babaskin/mail-sec-audit) | Read-only host, MTA, DNS, TLS, firewall, and authentication audit |
| [smtp-egress-audit](https://github.com/Anton-Babaskin/smtp-egress-audit) | Trace unexpected outbound SMTP connections back to processes and services |
| [mail_analyzer.sh](https://github.com/Anton-Babaskin/mail_analyzer.sh) | Lightweight Queue-ID-based inbound/outbound domain statistics |

The tools complement one another. Statistics are useful for orientation, but
logs, Queue IDs, DSNs, mailbox evidence, DMARC reports, and provider responses
remain the sources of forensic conclusions.

<details>
<summary><strong>Compatibility</strong></summary>

| Platform | v1 status |
| --- | --- |
| Mail-in-a-Box on Ubuntu | Primary tested platform |
| Standalone Postfix on Debian/Ubuntu | Supported |
| Standalone Postfix on RHEL/Rocky/AlmaLinux | Experimental |
| mailcow/Docker-generated Postfix | Refused; use generated templates |
| Zimbra | Refused; use Zimbra tooling |
| Exim, Exchange, other MTAs | Not supported |

The implementation uses standard Postfix parameters; it is not tied to a
specific relay vendor. Per-service `master.cf` overrides are refused when a
global change would be ambiguous.

</details>

<details>
<summary><strong>Snapshots, restore, and managed files</strong></summary>

```bash
sudo postfix-relay-rescue backups
sudo postfix-relay-rescue restore
sudo postfix-relay-rescue relay-off --purge-credentials
```

Managed paths include the active Postfix `main.cf`, SASL source/database maps,
relay TLS-policy source/database maps, non-secret state metadata, root-only
snapshots, watcher state, and the script log. The Postfix configuration
directory is discovered with `postconf`.

Mail-in-a-Box upgrades and other configuration-management systems may
regenerate `main.cf`. Run `sudo postfix-relay-rescue status` after upgrades.

</details>

<details>
<summary><strong>Development and privacy checks</strong></summary>

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

The smoke suite uses temporary mocks and never touches the host's live Postfix
configuration.

</details>

## Scope

The project does not delist domains or IPs, edit authoritative DNS, guarantee
inbox placement, support implicit-TLS port 465, or rewrite generated mail-stack
configuration. Use the official
[Spamhaus Reputation Checker](https://check.spamhaus.org/) for listing details
and removal.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Author and license

[Anton Babaskin](https://babaskin.dev/) · [MIT](LICENSE)
