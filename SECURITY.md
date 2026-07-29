# Security policy

[Русская версия](SECURITY.ru.md)

## Supported versions

Security fixes are provided for the latest published release.

| Version | Supported |
|---|---|
| `1.x` | Yes |
| Older or unreleased copies | No |

## Reporting a vulnerability

Do not open a public issue for a vulnerability involving:

- credential disclosure;
- unsafe Postfix relay behavior;
- command or configuration injection;
- privilege escalation;
- symlink or path traversal;
- backup disclosure;
- rollback failure that can leave Postfix in an unsafe state.

Use GitHub's **Security → Report a vulnerability** form. If private
vulnerability reporting is unavailable, contact the maintainer through the
contact details at [babaskin.dev](https://babaskin.dev/).

Include:

- affected version and operating system;
- exact reproduction steps;
- security impact;
- sanitized logs or a minimal proof of concept;
- any suggested remediation.

Never send real relay credentials or private mailbox content.

The maintainer will acknowledge a valid report, investigate it, and coordinate
disclosure and a fixed release. Response times are best effort because this is
an independently maintained open-source project.
