# Support

[Русская версия](SUPPORT.ru.md)

This project is maintained on a best-effort basis.

Use:

- **GitHub Discussions** for usage questions and configuration guidance;
- **GitHub Issues** for reproducible bugs and focused feature requests;
- **GitHub Security Advisories** for vulnerabilities.

Before asking for help, run:

```bash
sudo ./postfix-relay-rescue.sh status example.com
sudo postfix check
sudo postqueue -p
```

Sanitize all output. Never publish SMTP passwords, complete
`sasl_passwd` files, private email content, customer names, or other secrets.

Commercial emergency response, guaranteed response times, and Spamhaus
delisting are not provided by this repository.
