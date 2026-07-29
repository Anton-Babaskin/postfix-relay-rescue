# Contributing

Thank you for helping improve `postfix-relay-rescue`.

[Русская версия](CONTRIBUTING.ru.md)

## Before opening an issue

- Run the latest release.
- Read the README and existing issues.
- Remove passwords, private message content, public IP addresses if sensitive,
  and customer-identifying data.
- Include the operating-system, mail-stack or Mail-in-a-Box version, Postfix
  version, exact command, expected result, and sanitized output.

Security vulnerabilities must follow [SECURITY.md](SECURITY.md), not a public
issue.

## Pull requests

1. Fork the repository and create a focused branch.
2. Keep changes small enough to review safely.
3. Add or update mocked tests for every behavior change.
4. Update English and Russian documentation when user-facing behavior changes.
5. Run:

   ```bash
   bash -n postfix-relay-rescue.sh tests/run-smoke.sh tests/mock-bin/prr-mock
   shellcheck -x postfix-relay-rescue.sh tests/run-smoke.sh tests/mock-bin/prr-mock
   bash tests/run-smoke.sh
   ```

6. Explain the Postfix safety impact and rollback behavior in the pull request.

## Shell style

- Bash only; keep `set -Eeuo pipefail`.
- Quote expansions unless intentional splitting is documented.
- Use `printf`, not `echo`, for generated configuration.
- Never pass passwords through command-line arguments or environment variables.
- Treat every Postfix mutation as transactional.
- Preserve unrelated map entries and existing administrator configuration.
- Validate with `postfix check` before reload.
- Never call `restart` when a safe `reload` is sufficient.

## Testing rules

Tests must not touch the machine's real:

- `/etc/postfix`;
- Postfix service;
- DNS configuration;
- mail queue;
- user mailboxes.

Use the command mocks under `tests/mock-bin/` and temporary paths exposed
through the `PRR_*` environment variables.

## Commit and release notes

Use clear imperative commit subjects. Add user-visible changes to
`CHANGELOG.md` and `CHANGELOG.ru.md`.

By contributing, you agree that your contribution is licensed under the MIT
License.
