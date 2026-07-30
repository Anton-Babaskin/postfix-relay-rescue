#!/usr/bin/env bash
set -Eeuo pipefail

readonly IPV4_RE='([0-9]{1,3}\.){3}[0-9]{1,3}'
readonly TEXT_GLOBS=(
    '*.cf'
    '*.cff'
    '*.html'
    '*.md'
    '*.sh'
    '*.txt'
    '*.yaml'
    '*.yml'
)

failures=0

is_valid_ipv4() {
    local ip="$1"
    local a b c d

    IFS=. read -r a b c d <<<"$ip"

    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    ((a <= 255 && b <= 255 && c <= 255 && d <= 255))
}

is_allowed_ipv4() {
    local ip="$1"
    local a b _c _d

    IFS=. read -r a b _c _d <<<"$ip"

    # Loopback, private, link-local, and RFC 5737 documentation networks.
    ((a == 10 || a == 127)) && return 0
    ((a == 172 && b >= 16 && b <= 31)) && return 0
    ((a == 169 && b == 254)) && return 0
    ((a == 192 && b == 168)) && return 0
    ((a == 192 && b == 0 && _c == 2)) && return 0
    ((a == 198 && b == 51 && _c == 100)) && return 0
    ((a == 203 && b == 0 && _c == 113)) && return 0

    # Intentional public DNS examples used by the diagnostic workflow.
    case "$ip" in
        1.0.0.3 | 1.1.1.1 | 8.8.8.8)
            return 0
            ;;
    esac

    return 1
}

while IFS=: read -r file line text; do
    [[ -n "$file" ]] || continue

    while IFS= read -r ip; do
        is_valid_ipv4 "$ip" || continue
        is_allowed_ipv4 "$ip" && continue

        printf '[PRIVACY] public IPv4 must be anonymized: %s:%s: %s\n' \
            "$file" "$line" "$ip" >&2
        failures=$((failures + 1))
    done < <(grep -oE "$IPV4_RE" <<<"$text" || true)
done < <(git grep -I -n -E -e "$IPV4_RE" -- "${TEXT_GLOBS[@]}" || true)

readonly SECRET_RE='-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16}'

while IFS= read -r match; do
    [[ -n "$match" ]] || continue
    printf '[PRIVACY] possible credential or private key: %s\n' "$match" >&2
    failures=$((failures + 1))
done < <(git grep -I -n -E -e "$SECRET_RE" -- "${TEXT_GLOBS[@]}" || true)

if ((failures > 0)); then
    printf '[FAIL] privacy scan found %d issue(s)\n' "$failures" >&2
    exit 1
fi

printf '[OK] privacy scan passed\n'
