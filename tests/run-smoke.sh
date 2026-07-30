#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/postfix" "$tmp/bin" "$tmp/backups" "$tmp/run" "$tmp/watch"
cp "$root/tests/fixtures/main.cf" "$tmp/postfix/main.cf"

for command in postconf postmap postfix systemctl dpkg-query dig postqueue ip hostname sendmail; do
    ln -s "$root/tests/mock-bin/prr-mock" "$tmp/bin/$command"
done

export PATH="$tmp/bin:$PATH"
export PRR_POSTFIX_DIR="$tmp/postfix"
export PRR_MAIN_CF="$tmp/postfix/main.cf"
export PRR_SASL_FILE="$tmp/postfix/sasl_passwd"
export PRR_TLS_POLICY_FILE="$tmp/postfix/relay_tls_policy"
export PRR_STATE_FILE="$tmp/postfix/postfix-relay-rescue.state"
export PRR_BACKUP_ROOT="$tmp/backups"
export PRR_WATCH_STATE_DIR="$tmp/watch"
export PRR_LOG_FILE="$tmp/rescue.log"
export PRR_MAILLOG="$tmp/mail.log"
export PRR_LOCK_FILE="$tmp/run/rescue.lock"
export PRR_MOCK_POSTQUEUE_LOG="$tmp/postqueue.log"

printf 'old-relay.example [credential]\n' >"$tmp/postfix/sasl_passwd"
chmod 600 "$tmp/postfix/sasl_passwd"
printf 'super-secret\n' >"$tmp/password"
chmod 600 "$tmp/password"

printf '%s\n' \
    'submission inet n - y - - smtpd' \
    '  -o smtpd_sender_restrictions=reject_rhsbl_sender,dbl.spamhaus.org' \
    >"$tmp/postfix/master.cf"
if bash "$root/postfix-relay-rescue.sh" fix-submission >/dev/null 2>&1; then
    printf 'per-service sender restriction override was not refused\n' >&2
    exit 1
fi
rm "$tmp/postfix/master.cf"

bash "$root/postfix-relay-rescue.sh" setup \
    --host smtp.relay.example \
    --port 587 \
    --user relay-user \
    --password-file "$tmp/password" \
    --domain example.com \
    --spf-include spf.relay.example

grep -q 'permit_sasl_authenticated,permit_mynetworks,reject_rhsbl_sender' "$tmp/postfix/main.cf"
grep -q '^old-relay.example ' "$tmp/postfix/sasl_passwd"
grep -q '^\[smtp.relay.example\]:587 relay-user:super-secret$' "$tmp/postfix/sasl_passwd"
grep -q '^\[smtp.relay.example\]:587[[:space:]]encrypt$' "$tmp/postfix/relay_tls_policy"
grep -q $'^relay_nexthop\t\\[smtp.relay.example\\]:587$' "$tmp/postfix/postfix-relay-rescue.state"
grep -q $'^sending_domain\texample.com$' "$tmp/postfix/postfix-relay-rescue.state"
grep -q $'^spf_include\tspf.relay.example$' "$tmp/postfix/postfix-relay-rescue.state"
grep -q '^smtp_tls_security_level = dane$' "$tmp/postfix/main.cf"
grep -q 'hash:.*/relay_tls_policy' "$tmp/postfix/main.cf"
bash "$root/postfix-relay-rescue.sh" status example.com >/dev/null
PRR_MOCK_SPF_RECORD='v=spf1 a mx include:spf.relay.example -all' \
    bash "$root/postfix-relay-rescue.sh" spf example.com \
        --spf-include spf.relay.example >/dev/null

printf 'rotated-secret\n' >"$tmp/password-rotated"
chmod 600 "$tmp/password-rotated"
# --host and --port are intentionally omitted: the active Postfix relayhost
# must be detected and reused without any provider-specific logic.
bash "$root/postfix-relay-rescue.sh" relay-on \
    --user relay-user \
    --password-file "$tmp/password-rotated" \
    --domain example.com \
    --spf-include spf.relay.example
grep -q '^\[smtp.relay.example\]:587 relay-user:rotated-secret$' "$tmp/postfix/sasl_passwd"
if grep -q 'super-secret' "$tmp/postfix/sasl_passwd"; then
    printf 'old relay password survived an exact-key credential rotation\n' >&2
    exit 1
fi

rollback_before="$(sha256sum \
    "$tmp/postfix/main.cf" \
    "$tmp/postfix/sasl_passwd" \
    "$tmp/postfix/sasl_passwd.db" \
    "$tmp/postfix/relay_tls_policy" \
    "$tmp/postfix/relay_tls_policy.db" \
    "$tmp/postfix/postfix-relay-rescue.state")"
if PRR_MOCK_POSTFIX_CHECK_FAIL=1 bash "$root/postfix-relay-rescue.sh" relay-on \
    --host backup-relay.example.net \
    --port 2525 \
    --user backup-user \
    --password-file "$tmp/password" \
    --domain example.com; then
    printf 'a deliberately invalid transaction unexpectedly succeeded\n' >&2
    exit 1
fi
rollback_after="$(sha256sum \
    "$tmp/postfix/main.cf" \
    "$tmp/postfix/sasl_passwd" \
    "$tmp/postfix/sasl_passwd.db" \
    "$tmp/postfix/relay_tls_policy" \
    "$tmp/postfix/relay_tls_policy.db" \
    "$tmp/postfix/postfix-relay-rescue.state")"
[[ "$rollback_before" == "$rollback_after" ]]

before="$(sha256sum "$tmp/postfix/main.cf" "$tmp/postfix/sasl_passwd" "$tmp/postfix/relay_tls_policy")"
bash "$root/postfix-relay-rescue.sh" setup \
    --user relay-user \
    --password-file "$tmp/password-rotated" \
    --domain example.com \
    --spf-include spf.relay.example
after="$(sha256sum "$tmp/postfix/main.cf" "$tmp/postfix/sasl_passwd" "$tmp/postfix/relay_tls_policy")"
[[ "$before" == "$after" ]]

restore_target="$(find "$tmp/backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | LC_ALL=C sort -r | head -n1)"
printf 'deliberately-stale-database\n' >"$tmp/backups/$restore_target/sasl_passwd.db"
bash "$root/postfix-relay-rescue.sh" restore "$restore_target" --yes >/dev/null
cmp -s "$tmp/postfix/sasl_passwd" "$tmp/postfix/sasl_passwd.db"

bash "$root/postfix-relay-rescue.sh" relay-on \
    --host smtp.generic.example \
    --port 2525 \
    --user generic-user \
    --password-file "$tmp/password" \
    --domain example.com \
    --spf-include spf.generic.example
grep -q '^relayhost = \[smtp.generic.example\]:2525$' "$tmp/postfix/main.cf"
grep -q '^\[smtp.generic.example\]:2525 generic-user:super-secret$' "$tmp/postfix/sasl_passwd"
grep -q '^\[smtp.generic.example\]:2525[[:space:]]encrypt$' "$tmp/postfix/relay_tls_policy"
grep -q $'^spf_include\tspf.generic.example$' "$tmp/postfix/postfix-relay-rescue.state"
PRR_MOCK_SPF_RECORD='v=spf1 mx include:spf.generic.example -all' \
    bash "$root/postfix-relay-rescue.sh" status >/dev/null

PRR_MOCK_SYSTEMD_ACTIVE=0 bash "$root/postfix-relay-rescue.sh" relay-on \
    --host smtp.generic.example \
    --port 2525 \
    --user generic-user \
    --password-file "$tmp/password" \
    --domain example.com \
    --spf-include spf.generic.example

lookup_heavy_spf='v=spf1 a:a1.example a:a2.example a:a3.example a:a4.example a:a5.example a:a6.example a:a7.example a:a8.example a:a9.example a:a10.example include:spf.generic.example -all'
if lookup_output="$(PRR_MOCK_SPF_RECORD="$lookup_heavy_spf" \
    bash "$root/postfix-relay-rescue.sh" spf example.com 2>&1)"; then
    printf 'SPF lookup-budget overflow unexpectedly passed\n' >&2
    exit 1
fi
grep -q '11/10' <<<"$lookup_output"

PRR_MOCK_DBL_STATUS=NXDOMAIN \
    bash "$root/postfix-relay-rescue.sh" watch example.com >/dev/null
if PRR_MOCK_DBL_STATUS=NOERROR PRR_MOCK_DBL_ANSWERS='127.0.1.2' \
    bash "$root/postfix-relay-rescue.sh" watch example.com >/dev/null; then
    printf 'watch did not return the listed-state transition code\n' >&2
    exit 1
else
    [[ $? -eq 10 ]]
fi
if PRR_MOCK_DBL_STATUS=NXDOMAIN \
    bash "$root/postfix-relay-rescue.sh" watch example.com --flush-on-delist >/dev/null; then
    printf 'watch did not return the delisted-state transition code\n' >&2
    exit 1
else
    [[ $? -eq 11 ]]
fi
grep -q -- '-f' "$tmp/postqueue.log"

bash "$root/postfix-relay-rescue.sh" relay-off --purge-credentials
grep -q '^relayhost = $' "$tmp/postfix/main.cf"
grep -q '^smtp_tls_security_level = dane$' "$tmp/postfix/main.cf"
grep -q '^old-relay.example ' "$tmp/postfix/sasl_passwd"
grep -q 'smtp.relay.example' "$tmp/postfix/sasl_passwd"
if grep -q 'smtp.generic.example' "$tmp/postfix/sasl_passwd"; then
    printf 'active generic relay credential was not purged\n' >&2
    exit 1
fi
if grep -q 'relay_tls_policy' "$tmp/postfix/main.cf"; then
    printf 'relay TLS policy map was not disconnected\n' >&2
    exit 1
fi
[[ ! -e "$tmp/postfix/postfix-relay-rescue.state" ]]

printf 'smoke tests passed\n'
