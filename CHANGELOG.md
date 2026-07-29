# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-07-29

### Added

- Interactive and non-interactive authenticated STARTTLS relay setup.
- Support for MailBaby and arbitrary hostname-based SMTP relay providers.
- Per-relay mandatory TLS through `smtp_tls_policy_maps` without replacing the
  host's global `smtp_tls_security_level`.
- Postfix config-directory and common mail-log path detection.
- systemd/Postfix-control reload fallback.
- A guard against ambiguous per-service sender-restriction overrides.
- Safe Spamhaus sender-RHSBL bypass for authenticated users and loopback-only
  trusted networks while preserving sender-login anti-spoofing.
- Root-only credential storage and protected password-file input.
- Transactional snapshots, automatic rollback, explicit restore, and hash-map
  rebuilding.
- SPF validation, provider include checks, nested DNS lookup-budget auditing,
  and MailBaby-specific authorization checks.
- Spamhaus DBL and ZEN status inspection.
- Real delivery-chain test with queue-ID tracing.
- Cron-friendly DBL state-change watcher.
- Mocked smoke-test suite and GitHub Actions CI.

[Unreleased]: https://github.com/Anton-Babaskin/postfix-relay-rescue/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Anton-Babaskin/postfix-relay-rescue/releases/tag/v1.0.0
