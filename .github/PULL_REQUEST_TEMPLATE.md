## Summary / Краткое описание

Describe the operational problem and the proposed change.

Опишите операционную проблему и предлагаемое изменение.

## Safety impact / Влияние на безопасность

- Postfix files or parameters changed:
- Credential handling:
- Failure behavior:
- Rollback behavior:

## Validation / Проверка

- [ ] `bash -n postfix-relay-rescue.sh tests/run-smoke.sh tests/mock-bin/prr-mock`
- [ ] `shellcheck -x postfix-relay-rescue.sh tests/run-smoke.sh tests/mock-bin/prr-mock`
- [ ] `bash tests/run-smoke.sh`
- [ ] Tests cover the new behavior and its failure path.
- [ ] English and Russian documentation are updated.
- [ ] No credentials, private mail, customer data, or generated secret maps are included.

## Compatibility / Совместимость

List tested OS, mail stack, Postfix, and relay-provider versions.
