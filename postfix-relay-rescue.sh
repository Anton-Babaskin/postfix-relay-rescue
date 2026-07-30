#!/usr/bin/env bash
#
# postfix-relay-rescue.sh
#
# Safely keep outbound mail moving when a Postfix server has an IP-reputation
# problem or its own domain appears in Spamhaus DBL.
#
# The sender-RHSBL trap (commonly seen on Mail-in-a-Box):
#   reject_rhsbl_sender in smtpd_sender_restrictions is also evaluated for
#   authenticated submission. If the local domain is listed in DBL, Postfix can
#   reject its own users before a configured relay ever sees the message.
#
# This script can:
#   - preflight any hostname-based SMTP relay through DNS, TCP, STARTTLS, and
#     certificate hostname validation without requesting relay credentials;
#   - configure any hostname-based authenticated STARTTLS SMTP relay without
#     replacing the host's global smtp_tls_security_level;
#   - require TLS only for the relay through smtp_tls_policy_maps;
#   - insert a safe authenticated/localhost bypass before sender RHSBL checks
#     while keeping reject_authenticated_sender_login_mismatch ahead of it;
#   - audit DBL, ZEN, SPF, relay, TLS-map, SASL-map, queue, and duplicate keys;
#   - watch Spamhaus DBL and report only state changes for cron/monitoring;
#   - send and trace a real test message to the next hop;
#   - create complete snapshots and roll back every file it changes.
#
# It does not delist a domain. A relay changes the connecting IP, not the
# domains visible in MAIL FROM, From, DKIM, URLs, or Message-ID.
#
# Author: Anton Babaskin
# License: MIT

set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="1.0.0"

DEFAULT_POSTFIX_DIR="/etc/postfix"
if [[ -z "${PRR_POSTFIX_DIR:-}" ]] && command -v postconf >/dev/null 2>&1; then
    DETECTED_POSTFIX_DIR="$(postconf -h config_directory 2>/dev/null || true)"
    [[ -z "$DETECTED_POSTFIX_DIR" ]] || DEFAULT_POSTFIX_DIR="$DETECTED_POSTFIX_DIR"
fi
readonly POSTFIX_DIR="${PRR_POSTFIX_DIR:-$DEFAULT_POSTFIX_DIR}"
readonly MAIN_CF="${PRR_MAIN_CF:-$POSTFIX_DIR/main.cf}"
readonly MASTER_CF="${PRR_MASTER_CF:-$POSTFIX_DIR/master.cf}"
readonly SASL_FILE="${PRR_SASL_FILE:-$POSTFIX_DIR/sasl_passwd}"
readonly TLS_POLICY_FILE="${PRR_TLS_POLICY_FILE:-$POSTFIX_DIR/relay_tls_policy}"
readonly STATE_FILE="${PRR_STATE_FILE:-$POSTFIX_DIR/postfix-relay-rescue.state}"
readonly BACKUP_ROOT="${PRR_BACKUP_ROOT:-/var/backups/postfix-relay-rescue}"
readonly WATCH_STATE_DIR="${PRR_WATCH_STATE_DIR:-/var/lib/postfix-relay-rescue}"
readonly LOG_FILE="${PRR_LOG_FILE:-/var/log/postfix-relay-rescue.log}"
DEFAULT_MAILLOG="/var/log/mail.log"
if [[ -z "${PRR_MAILLOG:-}" && ! -f "$DEFAULT_MAILLOG" && -f /var/log/maillog ]]; then
    DEFAULT_MAILLOG="/var/log/maillog"
fi
readonly MAILLOG="${PRR_MAILLOG:-$DEFAULT_MAILLOG}"
readonly LOCK_FILE="${PRR_LOCK_FILE:-/run/lock/postfix-relay-rescue.lock}"
unset DEFAULT_POSTFIX_DIR DETECTED_POSTFIX_DIR DEFAULT_MAILLOG

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\e[31m'
    C_GRN=$'\e[32m'
    C_YLW=$'\e[33m'
    C_CYN=$'\e[36m'
    C_OFF=$'\e[0m'
else
    C_RED=""
    C_GRN=""
    C_YLW=""
    C_CYN=""
    C_OFF=""
fi
readonly C_RED C_GRN C_YLW C_CYN C_OFF

TX_ACTIVE=0
TX_SNAPSHOT=""
LAST_SNAPSHOT=""
TMP_FILE=""
LOCK_FD=""
RELAY_PASSWORD=""
MAP_ENTRY_REMOVED=0
STATE_RELAY_NEXTHOP=""
STATE_RELAY_DOMAIN=""
STATE_SPF_INCLUDE=""

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_OFF" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_CYN" "$*" "$C_OFF"; }

logline() {
    if [[ $EUID -eq 0 ]]; then
        touch "$LOG_FILE" 2>/dev/null || true
        chmod 600 "$LOG_FILE" 2>/dev/null || true
    fi
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

need_root() {
    [[ $EUID -eq 0 ]] || die "run as root: sudo $0 ..."
}

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

cleanup() {
    RELAY_PASSWORD=""
    unset RELAY_PASSWORD
    if [[ -n "$TMP_FILE" && -e "$TMP_FILE" ]]; then
        rm -f -- "$TMP_FILE"
    fi
}

# Forward declarations are resolved by Bash when a trap actually runs.
rollback_active_transaction() {
    local reason="${1:-unexpected failure}"
    [[ $TX_ACTIVE -eq 1 && -n "$TX_SNAPSHOT" ]] || return 0

    TX_ACTIVE=0
    fail "$reason — restoring $TX_SNAPSHOT"
    logline "automatic rollback: $reason -> $TX_SNAPSHOT"

    if restore_snapshot_files "$TX_SNAPSHOT"; then
        postfix check >>"$LOG_FILE" 2>&1 || true
        reload_postfix >>"$LOG_FILE" 2>&1 || true
        ok "configuration rolled back"
    else
        fail "automatic rollback was incomplete; restore manually from $TX_SNAPSHOT"
    fi
}

die() {
    fail "$*"
    rollback_active_transaction "$*" || true
    exit 1
}

on_error() {
    local rc=$?
    local line="${BASH_LINENO[0]:-unknown}"
    rollback_active_transaction "command failed near line $line (exit $rc)" || true
    exit "$rc"
}

on_signal() {
    rollback_active_transaction "interrupted by signal" || true
    exit 130
}

trap cleanup EXIT
trap on_error ERR
trap on_signal INT TERM HUP

validate_installation() {
    [[ -f "$MAIN_CF" ]] || die "$MAIN_CF not found — is Postfix installed?"
    need_bin postconf "install postfix"
}

platform_name() {
    if [[ -d /root/mailinabox || -d /usr/local/lib/mailinabox ]]; then
        printf 'Mail-in-a-Box'
    elif [[ -d /opt/mailcow-dockerized ]]; then
        printf 'mailcow'
    elif [[ -d /opt/zimbra ]]; then
        printf 'Zimbra'
    else
        printf 'standalone Postfix'
    fi
}

guard_supported_platform() {
    case "$(platform_name)" in
        mailcow)
            die "mailcow generates Postfix configuration; edit its supported templates instead"
            ;;
        Zimbra)
            die "Zimbra manages Postfix configuration; use Zimbra tooling instead"
            ;;
    esac
}

sender_restrictions_override_present() {
    [[ -f "$MASTER_CF" ]] || return 1
    grep -Eq \
        '^[[:space:]]*-o[[:space:]]+smtpd_sender_restrictions[[:space:]]*=' \
        "$MASTER_CF"
}

guard_sender_restrictions_override() {
    if sender_restrictions_override_present; then
        die "$MASTER_CF contains a per-service smtpd_sender_restrictions override; v1 refuses to claim a safe global bypass"
    fi
}

reload_postfix() {
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet postfix >/dev/null 2>&1; then
        systemctl reload postfix
    else
        postfix reload
    fi
}

postfix_is_healthy() {
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet postfix >/dev/null 2>&1; then
        return 0
    fi
    postfix status >/dev/null 2>&1
}

acquire_lock() {
    need_bin flock "install util-linux"
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec {LOCK_FD}>"$LOCK_FILE"
    flock -n "$LOCK_FD" || die "another postfix-relay-rescue process is running"
}

# ---------------------------------------------------------------------------
# Complete snapshots and transactional rollback
# ---------------------------------------------------------------------------

snapshot_file() {
    local snapshot="$1"
    local key="$2"
    local source="$3"
    local state="absent"

    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$snapshot/$key"
        state="present"
    fi
    printf '%s\t%s\n' "$key" "$state" >>"$snapshot/manifest.tsv"
}

create_snapshot() {
    local label="${1:-manual}"
    local safe_label stamp snapshot

    safe_label="${label//[^A-Za-z0-9._-]/-}"
    stamp="$(date -u '+%Y%m%dT%H%M%S.%N')"
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    snapshot="$(mktemp -d "$BACKUP_ROOT/${stamp}-${safe_label}-XXXXXX")"
    chmod 700 "$snapshot"
    : >"$snapshot/manifest.tsv"

    snapshot_file "$snapshot" "main.cf" "$MAIN_CF"
    snapshot_file "$snapshot" "sasl_passwd" "$SASL_FILE"
    snapshot_file "$snapshot" "sasl_passwd.db" "${SASL_FILE}.db"
    snapshot_file "$snapshot" "relay_tls_policy" "$TLS_POLICY_FILE"
    snapshot_file "$snapshot" "relay_tls_policy.db" "${TLS_POLICY_FILE}.db"
    snapshot_file "$snapshot" "managed_state" "$STATE_FILE"

    postconf -n >"$snapshot/postconf-n.txt" 2>"$snapshot/postconf-n.stderr" || true
    chmod -R go-rwx "$snapshot"

    LAST_SNAPSHOT="$snapshot"
    logline "snapshot created: $snapshot"
    ok "snapshot: $snapshot"
}

snapshot_state() {
    local snapshot="$1"
    local key="$2"
    awk -F '\t' -v wanted="$key" '$1 == wanted { print $2; exit }' \
        "$snapshot/manifest.tsv"
}

restore_one_snapshot_file() {
    local snapshot="$1"
    local key="$2"
    local destination="$3"
    local state

    state="$(snapshot_state "$snapshot" "$key")"
    case "$state" in
        present)
            [[ -e "$snapshot/$key" || -L "$snapshot/$key" ]] || return 1
            cp -a -- "$snapshot/$key" "$destination"
            ;;
        absent)
            rm -f -- "$destination"
            ;;
        *)
            return 1
            ;;
    esac
}

rebuild_restored_hash_map() {
    local source="$1"
    local mode="$2"

    if [[ -f "$source" ]]; then
        postmap "hash:$source" || return 1
        chown 0:0 "$source" "${source}.db" || return 1
        chmod "$mode" "$source" "${source}.db" || return 1
    elif [[ ! -e "$source" && ! -L "$source" ]]; then
        rm -f -- "${source}.db"
    fi
}

restore_snapshot_files() {
    local snapshot="$1"
    [[ -d "$snapshot" && -f "$snapshot/manifest.tsv" ]] || return 1

    restore_one_snapshot_file "$snapshot" "sasl_passwd" "$SASL_FILE" || return 1
    restore_one_snapshot_file "$snapshot" "sasl_passwd.db" "${SASL_FILE}.db" || return 1
    restore_one_snapshot_file "$snapshot" "relay_tls_policy" "$TLS_POLICY_FILE" || return 1
    restore_one_snapshot_file "$snapshot" "relay_tls_policy.db" "${TLS_POLICY_FILE}.db" || return 1
    if grep -q $'^managed_state\t' "$snapshot/manifest.tsv"; then
        restore_one_snapshot_file "$snapshot" "managed_state" "$STATE_FILE" || return 1
    else
        # Older or manually prepared snapshots may predate the non-secret
        # provider state file.
        rm -f -- "$STATE_FILE"
    fi
    restore_one_snapshot_file "$snapshot" "main.cf" "$MAIN_CF" || return 1

    # Rebuild hash databases from the restored source maps. This prevents a
    # stale .db from surviving even if an old/manual snapshot contained a
    # mismatched text/database pair.
    rebuild_restored_hash_map "$SASL_FILE" 0600 || return 1
    rebuild_restored_hash_map "$TLS_POLICY_FILE" 0644 || return 1
}

begin_transaction() {
    local label="$1"
    need_root
    validate_installation
    guard_supported_platform
    acquire_lock
    create_snapshot "$label"
    TX_SNAPSHOT="$LAST_SNAPSHOT"
    TX_ACTIVE=1
}

commit_transaction() {
    need_bin postfix "install postfix"

    if ! postfix check >>"$LOG_FILE" 2>&1; then
        rollback_active_transaction "postfix check failed"
        die "change rejected; details: $LOG_FILE"
    fi

    if ! reload_postfix >>"$LOG_FILE" 2>&1; then
        rollback_active_transaction "postfix reload failed"
        die "change rejected because Postfix could not reload"
    fi

    if ! postfix_is_healthy; then
        rollback_active_transaction "Postfix is not active after reload"
        die "change rejected because Postfix is not active"
    fi

    TX_ACTIVE=0
    logline "transaction committed; rollback point: $TX_SNAPSHOT"
    ok "postfix check passed; configuration reloaded"
}

latest_snapshot() {
    [[ -d "$BACKUP_ROOT" ]] || return 0
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
        | LC_ALL=C sort -r | head -n1
}

resolve_snapshot() {
    local requested="$1"
    local name path resolved root_resolved

    name="${requested:-$(latest_snapshot)}"
    [[ -n "$name" ]] || die "no snapshots found in $BACKUP_ROOT"
    [[ "$name" != */* && "$name" != "." && "$name" != ".." ]] \
        || die "snapshot must be a basename shown by '$0 backups'"

    path="$BACKUP_ROOT/$name"
    [[ -d "$path" ]] || die "snapshot not found: $name"
    resolved="$(realpath "$path")"
    root_resolved="$(realpath "$BACKUP_ROOT")"
    [[ "$resolved" == "$root_resolved/"* ]] || die "snapshot resolves outside $BACKUP_ROOT"
    printf '%s' "$resolved"
}

cmd_backups() {
    need_root
    hdr "Snapshots"
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        say "  none"
        return
    fi

    local found=0 dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        found=1
        printf '  %s\n' "$dir"
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | LC_ALL=C sort -r)
    [[ $found -eq 1 ]] || say "  none"
}

cmd_restore() {
    need_root
    validate_installation
    need_bin realpath "install coreutils"

    local requested="" assume_yes=0 target safety
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)
                assume_yes=1
                shift
                ;;
            --list)
                cmd_backups
                return
                ;;
            -*)
                die "restore: unknown option '$1'"
                ;;
            *)
                [[ -z "$requested" ]] || die "restore: only one snapshot may be specified"
                requested="$1"
                shift
                ;;
        esac
    done

    target="$(resolve_snapshot "$requested")"
    say "restore target: $target"

    if [[ $assume_yes -ne 1 ]]; then
        [[ -t 0 ]] || die "non-interactive restore requires --yes"
        local answer
        read -rp "Type RESTORE to continue: " answer
        [[ "$answer" == "RESTORE" ]] || die "restore cancelled"
    fi

    acquire_lock
    create_snapshot "pre-restore"
    safety="$LAST_SNAPSHOT"
    TX_SNAPSHOT="$safety"
    TX_ACTIVE=1

    restore_snapshot_files "$target" || die "could not read the selected snapshot"
    commit_transaction
    logline "restored snapshot: $target; safety snapshot: $safety"
    ok "restored: $target"
    say "safety snapshot of the replaced state: $safety"
}

# ---------------------------------------------------------------------------
# Common Postfix/map helpers
# ---------------------------------------------------------------------------

primary_domain() {
    local domain
    domain="$(postconf -h mydomain 2>/dev/null || true)"
    if [[ -n "$domain" ]]; then
        printf '%s' "$domain"
        return
    fi
    hostname -d 2>/dev/null || hostname -f 2>/dev/null || true
}

outbound_ip() {
    ip -4 route get 1.0.0.3 2>/dev/null \
        | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}'
}

is_public_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    [[ ! "$ip" =~ ^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|22[4-9]\.|23[0-9]\.|24[0-9]\.|25[0-5]\.) ]]
}

validate_domain() {
    local domain="${1%.}"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_relay_host() {
    local host="$1"
    [[ ${#host} -le 253 ]] || return 1
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535))
}

postconf_set() {
    local parameter="$1"
    local value="$2"
    postconf -e "$parameter = $value"
}

state_value() {
    local key="$1"
    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
    awk -F '\t' -v wanted="$key" '
        $1 == wanted {
            tab=index($0, "\t")
            print substr($0, tab+1)
            exit
        }
    ' "$STATE_FILE"
}

load_managed_state() {
    STATE_RELAY_NEXTHOP=""
    STATE_RELAY_DOMAIN=""
    STATE_SPF_INCLUDE=""
    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1

    STATE_RELAY_NEXTHOP="$(state_value relay_nexthop || true)"
    STATE_RELAY_DOMAIN="$(state_value sending_domain || true)"
    STATE_SPF_INCLUDE="$(state_value spf_include || true)"
    [[ -n "$STATE_RELAY_NEXTHOP" ]]
}

write_managed_state() {
    local nexthop="$1"
    local domain="$2"
    local spf_include="$3"

    umask 077
    TMP_FILE="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
    {
        printf 'format\t1\n'
        printf 'relay_nexthop\t%s\n' "$nexthop"
        printf 'sending_domain\t%s\n' "$domain"
        printf 'spf_include\t%s\n' "$spf_include"
    } >"$TMP_FILE"
    chown 0:0 "$TMP_FILE"
    chmod 600 "$TMP_FILE"
    mv -f -- "$TMP_FILE" "$STATE_FILE"
    TMP_FILE=""
}

clear_managed_state() {
    rm -f -- "$STATE_FILE"
    STATE_RELAY_NEXTHOP=""
    STATE_RELAY_DOMAIN=""
    STATE_SPF_INCLUDE=""
}

map_has_entries() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        return 0
    done <"$file"
    return 1
}

map_key_from_line() {
    local line="$1"
    if [[ "$line" =~ ^[[:space:]]*([^#[:space:]]+)[[:space:]]+ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

upsert_plain_map_entry() {
    local file="$1"
    local mode="$2"
    local key="$3"
    local value="$4"
    local line existing_key found=0

    TMP_FILE="$(mktemp "${file}.tmp.XXXXXX")"
    chmod "$mode" "$TMP_FILE"

    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            existing_key="$(map_key_from_line "$line" || true)"
            if [[ -n "$existing_key" && "$existing_key" == "$key" ]]; then
                if [[ $found -eq 0 ]]; then
                    printf '%s\t%s\n' "$key" "$value" >>"$TMP_FILE"
                    found=1
                fi
                continue
            fi
            printf '%s\n' "$line" >>"$TMP_FILE"
        done <"$file"
    fi

    if [[ $found -eq 0 ]]; then
        printf '%s\t%s\n' "$key" "$value" >>"$TMP_FILE"
    fi

    chown 0:0 "$TMP_FILE"
    chmod "$mode" "$TMP_FILE"
    mv -f -- "$TMP_FILE" "$file"
    TMP_FILE=""
}

upsert_sasl_entry() {
    local nexthop="$1"
    local username="$2"
    local password="$3"
    local line existing_key found=0

    umask 077
    TMP_FILE="$(mktemp "${SASL_FILE}.tmp.XXXXXX")"
    chmod 600 "$TMP_FILE"

    if [[ -f "$SASL_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            existing_key="$(map_key_from_line "$line" || true)"
            if [[ -n "$existing_key" && "$existing_key" == "$nexthop" ]]; then
                if [[ $found -eq 0 ]]; then
                    printf '%s %s:%s\n' "$nexthop" "$username" "$password" >>"$TMP_FILE"
                    found=1
                fi
                continue
            fi
            printf '%s\n' "$line" >>"$TMP_FILE"
        done <"$SASL_FILE"
    fi

    if [[ $found -eq 0 ]]; then
        printf '%s %s:%s\n' "$nexthop" "$username" "$password" >>"$TMP_FILE"
    fi

    chown 0:0 "$TMP_FILE"
    chmod 600 "$TMP_FILE"
    mv -f -- "$TMP_FILE" "$SASL_FILE"
    TMP_FILE=""

    postmap "hash:$SASL_FILE"
    chown 0:0 "$SASL_FILE" "${SASL_FILE}.db"
    chmod 600 "$SASL_FILE" "${SASL_FILE}.db"
}

remove_map_entry() {
    local file="$1"
    local mode="$2"
    local key="$3"
    local line existing_key

    MAP_ENTRY_REMOVED=0

    [[ -f "$file" ]] || return 0
    TMP_FILE="$(mktemp "${file}.tmp.XXXXXX")"
    chmod "$mode" "$TMP_FILE"

    while IFS= read -r line || [[ -n "$line" ]]; do
        existing_key="$(map_key_from_line "$line" || true)"
        if [[ -n "$existing_key" && "$existing_key" == "$key" ]]; then
            MAP_ENTRY_REMOVED=1
            continue
        fi
        printf '%s\n' "$line" >>"$TMP_FILE"
    done <"$file"

    chown 0:0 "$TMP_FILE"
    chmod "$mode" "$TMP_FILE"
    mv -f -- "$TMP_FILE" "$file"
    TMP_FILE=""
}

postconf_map_contains() {
    local parameter="$1"
    local wanted="$2"
    local current token
    current="$(postconf -h "$parameter")"
    current="${current//,/ }"
    local -a tokens=()
    local old_ifs="$IFS"
    IFS=$' \t' read -r -a tokens <<<"$current"
    IFS="$old_ifs"
    for token in "${tokens[@]}"; do
        [[ "$(trim "$token")" == "$wanted" ]] && return 0
    done
    return 1
}

ensure_postconf_map_reference() {
    local parameter="$1"
    local reference="$2"
    local current
    if postconf_map_contains "$parameter" "$reference"; then
        return
    fi

    current="$(trim "$(postconf -h "$parameter")")"
    if [[ -z "$current" ]]; then
        postconf_set "$parameter" "$reference"
    else
        postconf_set "$parameter" "$current, $reference"
    fi
}

remove_postconf_map_reference() {
    local parameter="$1"
    local reference="$2"
    local current token joined=""
    local -a tokens=()

    current="$(postconf -h "$parameter")"
    current="${current//,/ }"
    local old_ifs="$IFS"
    IFS=$' \t' read -r -a tokens <<<"$current"
    IFS="$old_ifs"

    for token in "${tokens[@]}"; do
        token="$(trim "$token")"
        [[ -z "$token" || "$token" == "$reference" ]] && continue
        if [[ -z "$joined" ]]; then
            joined="$token"
        else
            joined="$joined, $token"
        fi
    done
    postconf_set "$parameter" "$joined"
}

ensure_tls_policy() {
    local nexthop="$1"
    local policy="${2:-encrypt}"

    upsert_plain_map_entry "$TLS_POLICY_FILE" 0644 "$nexthop" "$policy"
    postmap "hash:$TLS_POLICY_FILE"
    chown 0:0 "$TLS_POLICY_FILE" "${TLS_POLICY_FILE}.db"
    chmod 644 "$TLS_POLICY_FILE" "${TLS_POLICY_FILE}.db"
    ensure_postconf_map_reference smtp_tls_policy_maps "hash:$TLS_POLICY_FILE"
}

drop_tls_policy() {
    local nexthop="$1"
    remove_map_entry "$TLS_POLICY_FILE" 0644 "$nexthop"
    if [[ $MAP_ENTRY_REMOVED -eq 1 ]]; then
        if map_has_entries "$TLS_POLICY_FILE"; then
            postmap "hash:$TLS_POLICY_FILE"
            chown 0:0 "$TLS_POLICY_FILE" "${TLS_POLICY_FILE}.db"
            chmod 644 "$TLS_POLICY_FILE" "${TLS_POLICY_FILE}.db"
        else
            remove_postconf_map_reference smtp_tls_policy_maps "hash:$TLS_POLICY_FILE"
            rm -f -- "$TLS_POLICY_FILE" "${TLS_POLICY_FILE}.db"
        fi
    fi
}

drop_sasl_entry() {
    local nexthop="$1"
    remove_map_entry "$SASL_FILE" 0600 "$nexthop"
    if [[ $MAP_ENTRY_REMOVED -eq 1 ]]; then
        if map_has_entries "$SASL_FILE"; then
            postmap "hash:$SASL_FILE"
            chown 0:0 "$SASL_FILE" "${SASL_FILE}.db"
            chmod 600 "$SASL_FILE" "${SASL_FILE}.db"
        else
            remove_postconf_map_reference smtp_sasl_password_maps "hash:$SASL_FILE"
            rm -f -- "$SASL_FILE" "${SASL_FILE}.db"
        fi
    fi
}

check_sasl_client_support() {
    local clients
    clients="$(postconf -A 2>/dev/null || true)"
    [[ -n "$clients" ]] || die "Postfix has no SMTP client SASL implementation"

    if command -v dpkg-query >/dev/null 2>&1; then
        if ! dpkg-query -W -f='${Status}' libsasl2-modules 2>/dev/null \
            | grep -q '^install ok installed$'; then
            die "libsasl2-modules is missing; install it first: apt-get install libsasl2-modules"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Safe sender-RHSBL bypass
# ---------------------------------------------------------------------------

split_restrictions() {
    local value="$1"
    local -n output_ref="$2"
    local -a raw=()
    local item

    output_ref=()
    local old_ifs="$IFS"
    IFS=',' read -r -a raw <<<"$value"
    IFS="$old_ifs"
    for item in "${raw[@]}"; do
        item="$(trim "$item")"
        [[ -n "$item" ]] && output_ref+=("$item")
    done
}

restriction_index() {
    local -n items_ref="$1"
    local needle="$2"
    local prefix_match="${3:-no}"
    local i

    for ((i=0; i<${#items_ref[@]}; i++)); do
        if [[ "$prefix_match" == "yes" ]]; then
            [[ "${items_ref[$i]}" == "$needle"* ]] && { printf '%s' "$i"; return 0; }
        else
            [[ "${items_ref[$i]}" == "$needle" ]] && { printf '%s' "$i"; return 0; }
        fi
    done
    return 1
}

bypass_is_safe() {
    local current="$1"
    local -a items=()
    local rhs sasl networks mismatch

    split_restrictions "$current" items
    rhs="$(restriction_index items reject_rhsbl_sender yes || true)"
    sasl="$(restriction_index items permit_sasl_authenticated no || true)"
    networks="$(restriction_index items permit_mynetworks no || true)"
    mismatch="$(restriction_index items reject_authenticated_sender_login_mismatch no || true)"

    [[ -n "$rhs" && -n "$sasl" && -n "$networks" ]] || return 1
    ((sasl < rhs && networks < rhs)) || return 1
    if [[ -n "$mismatch" ]]; then
        ((mismatch < sasl && mismatch < networks)) || return 1
    fi
}

build_safe_bypass_value() {
    local current="$1"
    local -a items=() cleaned=() result=()
    local item rhs_index had_mismatch=0 i joined=""

    split_restrictions "$current" items
    for item in "${items[@]}"; do
        case "$item" in
            permit_sasl_authenticated|permit_mynetworks)
                continue
                ;;
            reject_authenticated_sender_login_mismatch)
                had_mismatch=1
                continue
                ;;
            *)
                cleaned+=("$item")
                ;;
        esac
    done

    rhs_index="$(restriction_index cleaned reject_rhsbl_sender yes || true)"
    [[ -n "$rhs_index" ]] || return 1

    for ((i=0; i<${#cleaned[@]}; i++)); do
        if ((i == rhs_index)); then
            [[ $had_mismatch -eq 1 ]] \
                && result+=("reject_authenticated_sender_login_mismatch")
            result+=("permit_sasl_authenticated" "permit_mynetworks")
        fi
        result+=("${cleaned[$i]}")
    done

    for item in "${result[@]}"; do
        if [[ -z "$joined" ]]; then
            joined="$item"
        else
            joined="$joined,$item"
        fi
    done
    printf '%s' "$joined"
}

mynetworks_loopback_only() {
    local current token
    local -a networks=()
    current="$(postconf -h mynetworks)"
    current="${current//,/ }"
    local old_ifs="$IFS"
    IFS=$' \t' read -r -a networks <<<"$current"
    IFS="$old_ifs"

    for token in "${networks[@]}"; do
        token="$(trim "$token")"
        [[ -z "$token" ]] && continue
        case "$token" in
            127.0.0.0/8|127.0.0.1|127.0.0.1/32|'[::ffff:127.0.0.0]/104'|'[::1]/128'|::1|::1/128)
                ;;
            *)
                return 1
                ;;
        esac
    done
}

confirm_nonloopback_mynetworks() {
    local allow="$1"
    mynetworks_loopback_only && return 0

    warn "mynetworks is not loopback-only: $(postconf -h mynetworks)"
    warn "permit_mynetworks will bypass sender RHSBL for every trusted network above."
    [[ "$allow" == "yes" ]] && return 0

    if [[ -t 0 ]]; then
        local answer
        read -rp "Continue anyway? Type YES: " answer
        [[ "$answer" == "YES" ]] || die "bypass cancelled"
    else
        die "refusing non-interactive bypass; review mynetworks or pass --allow-nonloopback-mynetworks"
    fi
}

apply_safe_bypass() {
    local current new
    current="$(postconf -h smtpd_sender_restrictions)"

    if [[ "$current" != *reject_rhsbl_sender* ]]; then
        ok "no sender RHSBL checks configured; no bypass needed"
        return 0
    fi
    if bypass_is_safe "$current"; then
        ok "safe sender-RHSBL bypass is already active"
        return 0
    fi

    new="$(build_safe_bypass_value "$current")" \
        || die "could not rebuild smtpd_sender_restrictions safely"

    say "before: smtpd_sender_restrictions = $current"
    postconf_set smtpd_sender_restrictions "$new"
    say "after : smtpd_sender_restrictions = $new"

    if [[ "$new" != *reject_authenticated_sender_login_mismatch* ]]; then
        warn "this server had no reject_authenticated_sender_login_mismatch rule; none was invented"
    fi
    return 0
}

cmd_fix_submission() {
    need_root
    validate_installation
    guard_supported_platform

    local allow_nonloopback="no"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --allow-nonloopback-mynetworks)
                allow_nonloopback="yes"
                shift
                ;;
            *)
                die "fix-submission: unknown option '$1'"
                ;;
        esac
    done

    local current
    current="$(postconf -h smtpd_sender_restrictions)"
    if [[ "$current" != *reject_rhsbl_sender* ]]; then
        ok "no sender RHSBL checks configured; no bypass needed"
        return
    fi
    if bypass_is_safe "$current"; then
        ok "safe sender-RHSBL bypass is already active"
        return
    fi

    guard_sender_restrictions_override
    confirm_nonloopback_mynetworks "$allow_nonloopback"
    begin_transaction "safe-dbl-bypass"
    apply_safe_bypass
    commit_transaction

    ok "authenticated users and mynetworks now bypass sender RHSBL checks"
    say "external unauthenticated senders are still checked by Spamhaus DBL"
    if [[ "$(platform_name)" == "Mail-in-a-Box" ]]; then
        warn "Mail-in-a-Box upgrades can regenerate main.cf; run '$0 status' after upgrades"
    else
        warn "configuration-management tools may regenerate main.cf; run '$0 status' after changes"
    fi
    logline "safe sender-RHSBL bypass applied"
}

# ---------------------------------------------------------------------------
# Relay setup
# ---------------------------------------------------------------------------

RELAY_HOST=""
RELAY_PORT=""
RELAY_USER=""
RELAY_PASSWORD_FILE=""
RELAY_NEXTHOP=""
RELAY_DOMAIN=""
RELAY_SPF_INCLUDE=""
RELAY_SKIP_SPF="no"
RELAY_ALLOW_NONLOOPBACK="no"
PREFLIGHT_HOST=""
PREFLIGHT_PORT=""
PREFLIGHT_TIMEOUT="10"

reset_relay_options() {
    RELAY_HOST=""
    RELAY_PORT=""
    RELAY_USER=""
    RELAY_PASSWORD_FILE=""
    RELAY_NEXTHOP=""
    RELAY_DOMAIN=""
    RELAY_SPF_INCLUDE=""
    RELAY_SKIP_SPF="no"
    RELAY_ALLOW_NONLOOPBACK="no"
    RELAY_PASSWORD=""
}

require_option_value() {
    local option="$1"
    local count="$2"
    ((count >= 2)) || die "$option requires a value"
}

read_password_file() {
    local file="$1"
    local mode uid
    local -a lines=()

    [[ -f "$file" && ! -L "$file" ]] || die "password file must be a regular non-symlink file: $file"
    mode="$(stat -Lc '%a' "$file")"
    uid="$(stat -Lc '%u' "$file")"
    [[ "$uid" == "0" ]] || die "password file must be owned by root (uid 0)"
    [[ "$mode" == "400" || "$mode" == "600" ]] \
        || die "password file mode must be exactly 0400 or 0600 (is $mode)"

    mapfile -t lines <"$file"
    [[ ${#lines[@]} -eq 1 && -n "${lines[0]}" ]] \
        || die "password file must contain exactly one non-empty line"
    RELAY_PASSWORD="${lines[0]}"
}

reset_preflight_options() {
    PREFLIGHT_HOST=""
    PREFLIGHT_PORT=""
    PREFLIGHT_TIMEOUT="10"
}

parse_preflight_options() {
    local configured_relay=""
    local detected_host=""
    local detected_port=""

    reset_preflight_options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                require_option_value "$1" "$#"
                PREFLIGHT_HOST="$2"
                shift 2
                ;;
            --port)
                require_option_value "$1" "$#"
                PREFLIGHT_PORT="$2"
                shift 2
                ;;
            --timeout)
                require_option_value "$1" "$#"
                PREFLIGHT_TIMEOUT="$2"
                shift 2
                ;;
            *)
                die "preflight: unknown option '$1'"
                ;;
        esac
    done

    configured_relay="$(postconf -h relayhost 2>/dev/null || true)"
    detected_host="$(relay_hostname_from_nexthop "$configured_relay")"
    if [[ -n "$detected_host" ]]; then
        detected_port="$(relay_port_from_nexthop "$configured_relay")"
    fi

    if [[ -t 0 ]]; then
        if [[ -z "$PREFLIGHT_HOST" ]]; then
            local entered_host=""
            if [[ -n "$detected_host" ]]; then
                read -rp "Relay host [$detected_host]: " entered_host
                PREFLIGHT_HOST="${entered_host:-$detected_host}"
                if [[ "$PREFLIGHT_HOST" == "$detected_host" ]]; then
                    PREFLIGHT_PORT="${PREFLIGHT_PORT:-$detected_port}"
                fi
            else
                read -rp "Relay host: " PREFLIGHT_HOST
            fi
        fi
        if [[ -z "$PREFLIGHT_PORT" ]]; then
            read -rp "Relay STARTTLS port [587]: " PREFLIGHT_PORT
            PREFLIGHT_PORT="${PREFLIGHT_PORT:-587}"
        fi
    else
        PREFLIGHT_HOST="${PREFLIGHT_HOST:-$detected_host}"
        if [[ "$PREFLIGHT_HOST" == "$detected_host" ]]; then
            PREFLIGHT_PORT="${PREFLIGHT_PORT:-$detected_port}"
        fi
    fi

    PREFLIGHT_PORT="${PREFLIGHT_PORT:-587}"
    [[ -n "$PREFLIGHT_HOST" ]] \
        || die "no relayhost detected; pass --host"
    validate_relay_host "$PREFLIGHT_HOST" \
        || die "invalid relay hostname: $PREFLIGHT_HOST"
    validate_port "$PREFLIGHT_PORT" \
        || die "invalid relay port: $PREFLIGHT_PORT"
    [[ "$PREFLIGHT_PORT" != "465" ]] \
        || die "port 465 uses implicit TLS and is not supported; use a STARTTLS port"
    [[ "$PREFLIGHT_TIMEOUT" =~ ^[0-9]+$ ]] \
        || die "preflight timeout must be an integer"
    ((10#$PREFLIGHT_TIMEOUT >= 1 && 10#$PREFLIGHT_TIMEOUT <= 120)) \
        || die "preflight timeout must be between 1 and 120 seconds"
}

cmd_preflight() {
    validate_installation
    parse_preflight_options "$@"
    need_bin getent "install libc-bin or the platform package that provides getent"
    need_bin openssl "install openssl"
    need_bin timeout "install coreutils"

    local addresses=""
    local tls_output=""

    hdr "Relay preflight"
    say "target: [$PREFLIGHT_HOST]:$PREFLIGHT_PORT"

    addresses="$(getent ahosts "$PREFLIGHT_HOST" 2>/dev/null \
        | awk '{print $1}' \
        | LC_ALL=C sort -u || true)"
    if [[ -z "$addresses" ]]; then
        fail "DNS resolution failed for $PREFLIGHT_HOST"
        return 1
    fi
    ok "DNS resolution"
    while IFS= read -r address; do
        [[ -n "$address" ]] && say "  $address"
    done <<<"$addresses"

    if ! tls_output="$(
        timeout "${PREFLIGHT_TIMEOUT}s" \
            openssl s_client \
                -starttls smtp \
                -connect "$PREFLIGHT_HOST:$PREFLIGHT_PORT" \
                -servername "$PREFLIGHT_HOST" \
                -verify_hostname "$PREFLIGHT_HOST" \
                -verify_return_error \
                -brief \
                </dev/null 2>&1
    )"; then
        fail "TCP/STARTTLS/certificate validation failed"
        say "Check DNS, firewall rules, the selected port, and the relay certificate."
        [[ -z "$tls_output" ]] || say "OpenSSL: ${tls_output##*$'\n'}"
        return 1
    fi

    ok "TCP connection"
    ok "SMTP STARTTLS"
    ok "trusted certificate for $PREFLIGHT_HOST"
    say "No credentials were sent and no Postfix configuration was changed."
}

parse_relay_options() {
    local detected_host=""
    local detected_port=""
    local entered_host=""

    reset_relay_options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                require_option_value "$1" "$#"
                RELAY_HOST="$2"
                shift 2
                ;;
            --port)
                require_option_value "$1" "$#"
                RELAY_PORT="$2"
                shift 2
                ;;
            --user)
                require_option_value "$1" "$#"
                RELAY_USER="$2"
                shift 2
                ;;
            --password-file)
                require_option_value "$1" "$#"
                RELAY_PASSWORD_FILE="$2"
                shift 2
                ;;
            --domain|--spf-domain)
                require_option_value "$1" "$#"
                RELAY_DOMAIN="${2%.}"
                shift 2
                ;;
            --spf-include)
                require_option_value "$1" "$#"
                RELAY_SPF_INCLUDE="${2%.}"
                shift 2
                ;;
            --skip-spf-check)
                RELAY_SKIP_SPF="yes"
                shift
                ;;
            --allow-nonloopback-mynetworks)
                RELAY_ALLOW_NONLOOPBACK="yes"
                shift
                ;;
            *)
                die "unknown relay option '$1'"
                ;;
        esac
    done

    if [[ -n "$RELAY_PASSWORD_FILE" ]]; then
        read_password_file "$RELAY_PASSWORD_FILE"
    fi

    if [[ -z "$RELAY_HOST" ]]; then
        detected_host="$(relay_hostname_from_nexthop "$(postconf -h relayhost 2>/dev/null || true)")"
        if [[ -n "$detected_host" ]]; then
            detected_port="$(relay_port_from_nexthop "$(postconf -h relayhost 2>/dev/null || true)")"
        fi
    fi

    if [[ -t 0 ]]; then
        if [[ -z "$RELAY_HOST" ]]; then
            if [[ -n "$detected_host" ]]; then
                read -rp "Relay host [$detected_host]: " entered_host
                RELAY_HOST="${entered_host:-$detected_host}"
                if [[ "$RELAY_HOST" == "$detected_host" ]]; then
                    RELAY_PORT="${RELAY_PORT:-$detected_port}"
                    say "using relay detected from Postfix: [$RELAY_HOST]:$RELAY_PORT"
                fi
            else
                read -rp "Relay host: " RELAY_HOST
            fi
        fi
        if [[ -z "$RELAY_PORT" ]]; then
            read -rp "Relay STARTTLS port [587]: " RELAY_PORT
            RELAY_PORT="${RELAY_PORT:-587}"
        fi
        if [[ -z "$RELAY_USER" ]]; then
            read -rp "Relay username: " RELAY_USER
        fi
        if [[ -z "$RELAY_PASSWORD" ]]; then
            read -rsp "Relay password: " RELAY_PASSWORD
            printf '\n'
        fi
        if [[ -z "$RELAY_SPF_INCLUDE" ]]; then
            read -rp "Provider SPF include domain (optional): " RELAY_SPF_INCLUDE
            RELAY_SPF_INCLUDE="${RELAY_SPF_INCLUDE%.}"
        fi
    else
        if [[ -z "$RELAY_HOST" && -n "$detected_host" ]]; then
            RELAY_HOST="$detected_host"
            RELAY_PORT="${RELAY_PORT:-$detected_port}"
        fi
        RELAY_PORT="${RELAY_PORT:-587}"
    fi

    [[ -n "$RELAY_HOST" ]] \
        || die "no relayhost detected; pass --host"
    [[ -n "$RELAY_USER" ]] || die "relay username is required"
    [[ -n "$RELAY_PASSWORD" ]] || die "relay password is required via prompt or --password-file"
    validate_relay_host "$RELAY_HOST" || die "invalid relay hostname: $RELAY_HOST"
    validate_port "$RELAY_PORT" || die "invalid relay port: $RELAY_PORT"
    [[ "$RELAY_PORT" != "465" ]] \
        || die "port 465 uses implicit TLS and is not supported; use a STARTTLS port such as 587"
    [[ ! "$RELAY_USER" =~ [[:space:]:] ]] \
        || die "relay username must not contain whitespace or ':'"
    [[ "$RELAY_PASSWORD" != *$'\r'* && "$RELAY_PASSWORD" != *$'\n'* ]] \
        || die "relay password must be a single line"

    RELAY_NEXTHOP="[$RELAY_HOST]:$RELAY_PORT"
    RELAY_DOMAIN="${RELAY_DOMAIN:-$(primary_domain)}"
    if [[ -n "$RELAY_DOMAIN" ]] && ! validate_domain "$RELAY_DOMAIN"; then
        warn "could not infer a valid sending domain; SPF audit will be skipped"
        RELAY_DOMAIN=""
    fi

    if [[ -n "$RELAY_SPF_INCLUDE" ]] && ! validate_domain "$RELAY_SPF_INCLUDE"; then
        die "invalid SPF include domain: $RELAY_SPF_INCLUDE"
    fi
}

apply_relay_configuration() {
    local old_relay
    old_relay="$(postconf -h relayhost)"

    if [[ -n "$old_relay" && "$old_relay" != "$RELAY_NEXTHOP" ]]; then
        drop_tls_policy "$old_relay"
    fi

    upsert_sasl_entry "$RELAY_NEXTHOP" "$RELAY_USER" "$RELAY_PASSWORD"
    RELAY_PASSWORD=""
    unset RELAY_PASSWORD

    ensure_tls_policy "$RELAY_NEXTHOP" encrypt
    postconf_set relayhost "$RELAY_NEXTHOP"
    postconf_set smtp_sasl_auth_enable yes
    ensure_postconf_map_reference smtp_sasl_password_maps "hash:$SASL_FILE"
    postconf_set smtp_sasl_security_options noanonymous
    postconf_set smtp_sasl_tls_security_options noanonymous
    write_managed_state "$RELAY_NEXTHOP" "$RELAY_DOMAIN" "$RELAY_SPF_INCLUDE"
}

post_relay_advice() {
    local global_tls
    global_tls="$(postconf -h smtp_tls_security_level)"
    ok "outbound mail now uses $RELAY_NEXTHOP with per-relay mandatory TLS"
    say "global smtp_tls_security_level remains: ${global_tls:-<empty>}"

    if [[ "$global_tls" == "encrypt" ]]; then
        warn "global smtp_tls_security_level=encrypt was already present."
        warn "Global encrypt can hurt direct delivery after relay-off; preserve the host's original TLS policy."
    fi

    if [[ "$RELAY_SKIP_SPF" != "yes" && -n "$RELAY_DOMAIN" ]]; then
        spf_report "$RELAY_DOMAIN" "$RELAY_SPF_INCLUDE" || true
        if [[ -z "$RELAY_SPF_INCLUDE" ]]; then
            warn "No provider SPF include was supplied; verify the relay provider's DNS instructions."
            say "For providers that publish one, rerun with: --spf-include spf.provider.example"
        fi
    fi

    warn "A relay fixes connecting-IP reputation, not a Spamhaus DBL domain listing."
    warn "For DBL removal use: https://check.spamhaus.org"
}

cmd_relay_on() {
    need_root
    validate_installation
    parse_relay_options "$@"
    check_sasl_client_support

    begin_transaction "relay-on"
    apply_relay_configuration
    commit_transaction
    logline "relay enabled: $RELAY_NEXTHOP"
    post_relay_advice
}

cmd_setup() {
    need_root
    validate_installation
    parse_relay_options "$@"
    check_sasl_client_support

    local current need_bypass=0
    current="$(postconf -h smtpd_sender_restrictions)"
    if [[ "$current" == *reject_rhsbl_sender* ]] && ! bypass_is_safe "$current"; then
        need_bypass=1
        guard_sender_restrictions_override
        confirm_nonloopback_mynetworks "$RELAY_ALLOW_NONLOOPBACK"
    fi

    begin_transaction "relay-and-bypass"
    if [[ $need_bypass -eq 1 ]]; then
        apply_safe_bypass
    else
        ok "sender-RHSBL bypass needs no change"
    fi
    apply_relay_configuration
    commit_transaction

    logline "relay and bypass setup committed: $RELAY_NEXTHOP"
    post_relay_advice
}

cmd_relay_off() {
    need_root
    validate_installation

    local purge="no" current
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-credentials)
                purge="yes"
                shift
                ;;
            *)
                die "relay-off: unknown option '$1'"
                ;;
        esac
    done

    current="$(postconf -h relayhost)"
    if [[ -z "$current" ]]; then
        [[ "$purge" == "no" ]] || die "relayhost is empty; refusing to guess which credential to purge"
        ok "relay is already disabled"
        return
    fi

    begin_transaction "relay-off"
    postconf_set relayhost ""
    postconf_set smtp_sasl_auth_enable no
    drop_tls_policy "$current"
    if [[ "$purge" == "yes" ]]; then
        drop_sasl_entry "$current"
    fi
    if load_managed_state && [[ "$STATE_RELAY_NEXTHOP" == "$current" ]]; then
        clear_managed_state
    fi
    commit_transaction

    ok "relay disabled; Postfix returned to direct delivery"
    say "global smtp_tls_security_level: $(postconf -h smtp_tls_security_level)"
    if [[ "$purge" == "yes" ]]; then
        say "credential for $current removed; recoverable from $TX_SNAPSHOT"
    else
        say "credential retained in $SASL_FILE; use --purge-credentials to remove it"
    fi
    if [[ "$(postconf -h smtp_tls_security_level)" == "encrypt" ]]; then
        warn "global TLS level is encrypt; verify it is the intended direct-delivery policy"
    fi
    logline "relay disabled: $current; purge=$purge"
}

# ---------------------------------------------------------------------------
# SPF audit and recommendation
# ---------------------------------------------------------------------------

decode_dig_txt_line() {
    local line="$1"
    line="${line#\"}"
    line="${line%\"}"
    line="${line//\" \"/}"
    printf '%s' "$line"
}

SPF_RECORDS=()
SPF_CHILD_RECORD=""
SPF_LOOKUP_COUNT=0
SPF_LOOKUP_INCOMPLETE=0
SPF_LOOKUP_DEPTH=0
declare -A SPF_LOOKUP_ACTIVE=()

get_spf_records() {
    local domain="$1"
    local raw decoded
    SPF_RECORDS=()

    while IFS= read -r raw; do
        decoded="$(decode_dig_txt_line "$raw")"
        if [[ "${decoded,,}" == v=spf1* ]]; then
            SPF_RECORDS+=("$decoded")
        fi
    done < <(dig +time=4 +tries=1 +short TXT "$domain" 2>/dev/null || true)
}

get_single_spf_record() {
    local domain="$1"
    local raw decoded
    local -a spf_found=()
    SPF_CHILD_RECORD=""

    while IFS= read -r raw; do
        decoded="$(decode_dig_txt_line "$raw")"
        [[ "${decoded,,}" == v=spf1* ]] && spf_found+=("$decoded")
    done < <(dig +time=4 +tries=1 +short TXT "$domain" 2>/dev/null || true)

    [[ ${#spf_found[@]} -eq 1 ]] || return 1
    SPF_CHILD_RECORD="${spf_found[0]}"
}

spf_lookup_walk() {
    local domain="${1,,}"
    local record="$2"
    local token mechanism child child_record
    local -a tokens=()

    if [[ -n "${SPF_LOOKUP_ACTIVE[$domain]+x}" ]] || ((SPF_LOOKUP_DEPTH >= 20)); then
        SPF_LOOKUP_INCOMPLETE=1
        return 0
    fi
    SPF_LOOKUP_ACTIVE["$domain"]=1
    ((SPF_LOOKUP_DEPTH+=1))

    local old_ifs="$IFS"
    IFS=$' \t' read -r -a tokens <<<"$record"
    IFS="$old_ifs"

    for token in "${tokens[@]}"; do
        mechanism="${token#[+?~-]}"
        mechanism="${mechanism,,}"
        case "$mechanism" in
            include:*)
                ((SPF_LOOKUP_COUNT+=1))
                child="${mechanism#include:}"
                child="${child%.}"
                if [[ "$child" == *'%'* ]] || ! validate_domain "$child"; then
                    SPF_LOOKUP_INCOMPLETE=1
                    continue
                fi
                if get_single_spf_record "$child"; then
                    child_record="$SPF_CHILD_RECORD"
                    spf_lookup_walk "$child" "$child_record"
                else
                    SPF_LOOKUP_INCOMPLETE=1
                fi
                ;;
            redirect=*)
                ((SPF_LOOKUP_COUNT+=1))
                child="${mechanism#redirect=}"
                child="${child%.}"
                if [[ "$child" == *'%'* ]] || ! validate_domain "$child"; then
                    SPF_LOOKUP_INCOMPLETE=1
                    continue
                fi
                if get_single_spf_record "$child"; then
                    child_record="$SPF_CHILD_RECORD"
                    spf_lookup_walk "$child" "$child_record"
                else
                    SPF_LOOKUP_INCOMPLETE=1
                fi
                ;;
            a|a:*|a/*|mx|mx:*|mx/*|ptr|ptr:*|exists:*)
                ((SPF_LOOKUP_COUNT+=1))
                ;;
        esac
    done

    unset 'SPF_LOOKUP_ACTIVE[$domain]'
    SPF_LOOKUP_DEPTH=$((SPF_LOOKUP_DEPTH-1))
}

spf_lookup_budget_report() {
    local domain="$1"
    local record="$2"

    SPF_LOOKUP_COUNT=0
    SPF_LOOKUP_INCOMPLETE=0
    SPF_LOOKUP_DEPTH=0
    SPF_LOOKUP_ACTIVE=()
    spf_lookup_walk "$domain" "$record"

    if ((SPF_LOOKUP_COUNT > 10)); then
        fail "SPF DNS lookup budget can reach $SPF_LOOKUP_COUNT/10 — receivers may return PermError"
        return 1
    fi
    if ((SPF_LOOKUP_INCOMPLETE == 1)); then
        warn "SPF DNS lookup budget is at least $SPF_LOOKUP_COUNT/10; one or more nested records could not be resolved"
    else
        ok "SPF DNS lookup budget: $SPF_LOOKUP_COUNT/10"
    fi
}

spf_contains_include() {
    local spf="${1,,}"
    local include="${2,,}"
    [[ " $spf " == *" include:$include "* ]]
}

suggest_spf_record() {
    local current="$1"
    local include="$2"
    local prefix all

    if [[ "$current" =~ ^(.*)[[:space:]]([+?~-]?all)[[:space:]]*$ ]]; then
        prefix="$(trim "${BASH_REMATCH[1]}")"
        all="${BASH_REMATCH[2]}"
        printf '%s include:%s %s' "$prefix" "$include" "$all"
    else
        printf '%s include:%s' "$(trim "$current")" "$include"
    fi
}

default_spf_suggestion() {
    local include="$1"
    local ip
    ip="$(outbound_ip || true)"
    if is_public_ipv4 "$ip"; then
        printf 'v=spf1 a mx ip4:%s include:%s -all' "$ip" "$include"
    else
        printf 'v=spf1 a mx include:%s -all' "$include"
    fi
}

spf_report() {
    local domain="${1%.}"
    local required_include="${2:-}"
    local -a records=()
    local spf suggested lookup_failed=0

    need_bin dig "install dnsutils"
    validate_domain "$domain" || die "invalid domain for SPF audit: $domain"

    hdr "SPF: $domain"
    get_spf_records "$domain"
    records=("${SPF_RECORDS[@]}")

    case "${#records[@]}" in
        0)
            fail "no SPF record found"
            if [[ -n "$required_include" ]]; then
                say "  suggested: $(default_spf_suggestion "$required_include")"
            fi
            return 1
            ;;
        1)
            spf="${records[0]}"
            say "  $spf"
            ;;
        *)
            fail "multiple SPF records found — this produces SPF PermError"
            for spf in "${records[@]}"; do
                say "  $spf"
            done
            return 1
            ;;
    esac

    spf_lookup_budget_report "$domain" "$spf" || lookup_failed=1

    if [[ -n "$required_include" ]]; then
        if spf_contains_include "$spf" "$required_include"; then
            ok "relay SPF include is present: $required_include"
        else
            fail "missing include:$required_include"
            suggested="$(suggest_spf_record "$spf" "$required_include")"
            say "  replace the existing SPF record with:"
            say "  $suggested"
            return 1
        fi
    fi

    ((lookup_failed == 0))
}

AUDIT_DOMAIN=""
AUDIT_SPF_INCLUDE=""

resolve_audit_context() {
    local relay positional_domain=""
    local requested_include=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                require_option_value "$1" "$#"
                AUDIT_DOMAIN="${2%.}"
                shift 2
                ;;
            --include|--spf-include)
                require_option_value "$1" "$#"
                requested_include="${2%.}"
                shift 2
                ;;
            -*)
                die "unknown audit option '$1'"
                ;;
            *)
                [[ -z "$positional_domain" ]] || die "only one domain may be audited"
                positional_domain="${1%.}"
                shift
                ;;
        esac
    done

    [[ -z "$positional_domain" || -z "$AUDIT_DOMAIN" ]] \
        || die "pass the domain either positionally or with --domain, not both"
    AUDIT_DOMAIN="${AUDIT_DOMAIN:-$positional_domain}"
    AUDIT_SPF_INCLUDE="$requested_include"

    relay="$(postconf -h relayhost)"
    if load_managed_state && [[ "$STATE_RELAY_NEXTHOP" == "$relay" ]]; then
        AUDIT_DOMAIN="${AUDIT_DOMAIN:-$STATE_RELAY_DOMAIN}"
        AUDIT_SPF_INCLUDE="${AUDIT_SPF_INCLUDE:-$STATE_SPF_INCLUDE}"
    fi

    AUDIT_DOMAIN="${AUDIT_DOMAIN:-$(primary_domain)}"
    validate_domain "$AUDIT_DOMAIN" || die "invalid domain: $AUDIT_DOMAIN"
    if [[ -n "$AUDIT_SPF_INCLUDE" ]]; then
        validate_domain "$AUDIT_SPF_INCLUDE" \
            || die "invalid SPF include domain: $AUDIT_SPF_INCLUDE"
    fi
}

cmd_spf() {
    validate_installation
    AUDIT_DOMAIN=""
    AUDIT_SPF_INCLUDE=""
    resolve_audit_context "$@"
    spf_report "$AUDIT_DOMAIN" "$AUDIT_SPF_INCLUDE"
}

# ---------------------------------------------------------------------------
# Spamhaus and configuration status
# ---------------------------------------------------------------------------

dbl_verdict() {
    case "$1" in
        127.0.1.2)     say "low-reputation/spam domain" ;;
        127.0.1.4)     say "phishing-related domain" ;;
        127.0.1.5)     say "malware-related domain" ;;
        127.0.1.6)     say "botnet C&C domain" ;;
        127.0.1.102)   say "abused legitimate domain" ;;
        127.0.1.103)   say "abused redirector" ;;
        127.0.1.104)   say "abused domain used in phishing" ;;
        127.0.1.105)   say "abused domain used by malware" ;;
        127.0.1.106)   say "abused domain hosting C&C" ;;
        127.0.1.255)   say "ERROR: an IP was queried against DBL" ;;
        127.255.255.250) say "ERROR: Spamhaus DQS key disabled" ;;
        127.255.255.251) say "ERROR: Spamhaus DQS key used illegally" ;;
        127.255.255.252) say "ERROR: DNSBL hostname typo" ;;
        127.255.255.*) say "ERROR: query refused/blocked; check the DNS resolver" ;;
        127.0.1.*)     say "listed by DBL (code $1)" ;;
        *)             say "unexpected DNS reply: $1" ;;
    esac
}

zen_verdict() {
    case "$1" in
        127.0.0.2)     say "SBL" ;;
        127.0.0.3)     say "CSS automated reputation listing" ;;
        127.0.0.4)     say "XBL compromised host" ;;
        127.0.0.[5-7]) say "XBL family (currently unused code)" ;;
        127.0.0.9)     say "DROP rogue network" ;;
        127.0.0.10)    say "PBL, ISP-maintained" ;;
        127.0.0.11)    say "PBL, Spamhaus-maintained" ;;
        127.0.0.30)    say "BCL botnet controller" ;;
        127.255.255.250) say "ERROR: Spamhaus DQS key disabled" ;;
        127.255.255.251) say "ERROR: Spamhaus DQS key used illegally" ;;
        127.255.255.252) say "ERROR: DNSBL hostname typo" ;;
        127.255.255.*) say "ERROR: query refused/blocked; check the DNS resolver" ;;
        *)             say "unexpected DNS reply: $1" ;;
    esac
}

query_dnsbl() {
    local query="$1"
    local verdict_function="$2"
    local -a answers=()
    local answer

    mapfile -t answers < <(dig +time=4 +tries=1 +short A "$query" 2>/dev/null \
        | LC_ALL=C sort -u || true)
    if [[ ${#answers[@]} -eq 0 ]]; then
        say "  not listed (no A response)"
        return
    fi

    for answer in "${answers[@]}"; do
        printf '  %s — ' "$answer"
        "$verdict_function" "$answer"
    done
}

DBL_WATCH_STATE=""
DBL_WATCH_DETAIL=""

lookup_dbl_watch_state() {
    local domain="$1"
    local raw dns_status answer
    local -a answers=()

    DBL_WATCH_STATE=""
    DBL_WATCH_DETAIL=""
    if ! raw="$(dig +time=4 +tries=1 +noall +comments +answer \
        A "${domain}.dbl.spamhaus.org" 2>&1)"; then
        DBL_WATCH_STATE="error"
        DBL_WATCH_DETAIL="dig failed"
        return 0
    fi

    dns_status="$(sed -nE 's/.*status: ([A-Z]+),.*/\1/p' <<<"$raw" | head -n1)"
    case "$dns_status" in
        NOERROR|NXDOMAIN)
            ;;
        "")
            DBL_WATCH_STATE="error"
            DBL_WATCH_DETAIL="DNS status missing"
            return 0
            ;;
        *)
            DBL_WATCH_STATE="error"
            DBL_WATCH_DETAIL="DNS status $dns_status"
            return 0
            ;;
    esac

    mapfile -t answers < <(awk '$4 == "A" { print $5 }' <<<"$raw" \
        | LC_ALL=C sort -u)
    if [[ ${#answers[@]} -eq 0 ]]; then
        DBL_WATCH_STATE="clean"
        DBL_WATCH_DETAIL="not listed"
        return 0
    fi

    for answer in "${answers[@]}"; do
        case "$answer" in
            127.0.1.255|127.255.255.*)
                DBL_WATCH_STATE="error"
                DBL_WATCH_DETAIL="$(dbl_verdict "$answer")"
                return 0
                ;;
            127.0.1.[0-9]*)
                ;;
            *)
                DBL_WATCH_STATE="error"
                DBL_WATCH_DETAIL="unexpected DNS reply $answer"
                return 0
                ;;
        esac
    done

    DBL_WATCH_STATE="listed"
    local old_ifs="$IFS"
    IFS=,
    DBL_WATCH_DETAIL="${answers[*]}"
    IFS="$old_ifs"
}

write_watch_state() {
    local path="$1"
    local state="$2"
    local detail="$3"

    [[ ! -L "$path" ]] || die "refusing symlink watch state: $path"
    TMP_FILE="$(mktemp "${path}.tmp.XXXXXX")"
    printf '%s\t%s\n' "$state" "$detail" >"$TMP_FILE"
    chown 0:0 "$TMP_FILE"
    chmod 600 "$TMP_FILE"
    mv -f -- "$TMP_FILE" "$path"
    TMP_FILE=""
}

cmd_watch() {
    need_root
    need_bin dig "install dnsutils"

    local domain="" flush="no" verbose="no"
    local state_file previous_state="" previous_detail="" rc=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --flush-on-delist)
                flush="yes"
                shift
                ;;
            --verbose)
                verbose="yes"
                shift
                ;;
            --domain)
                require_option_value "$1" "$#"
                domain="${2%.}"
                shift 2
                ;;
            -*)
                die "watch: unknown option '$1'"
                ;;
            *)
                [[ -z "$domain" ]] || die "watch accepts one domain"
                domain="${1%.}"
                shift
                ;;
        esac
    done

    domain="${domain:-$(primary_domain)}"
    validate_domain "$domain" || die "invalid domain: $domain"
    mkdir -p "$WATCH_STATE_DIR"
    chown 0:0 "$WATCH_STATE_DIR"
    chmod 700 "$WATCH_STATE_DIR"
    state_file="$WATCH_STATE_DIR/${domain,,}.dbl.state"
    [[ ! -L "$state_file" ]] || die "refusing symlink watch state: $state_file"

    if [[ -f "$state_file" ]]; then
        IFS=$'\t' read -r previous_state previous_detail <"$state_file" || true
    fi

    lookup_dbl_watch_state "$domain"
    if [[ "$previous_state" == "$DBL_WATCH_STATE" \
        && "$previous_detail" == "$DBL_WATCH_DETAIL" ]]; then
        [[ "$verbose" == "yes" ]] \
            && say "DBL unchanged: $domain — $DBL_WATCH_STATE ($DBL_WATCH_DETAIL)"
        return 0
    fi

    write_watch_state "$state_file" "$DBL_WATCH_STATE" "$DBL_WATCH_DETAIL"
    if [[ -z "$previous_state" ]]; then
        say "DBL baseline: $domain — $DBL_WATCH_STATE ($DBL_WATCH_DETAIL)"
        logline "DBL watch baseline: domain=$domain state=$DBL_WATCH_STATE detail=$DBL_WATCH_DETAIL"
        return 0
    fi

    case "$DBL_WATCH_STATE" in
        listed)
            say "DBL CHANGE: $domain is LISTED ($DBL_WATCH_DETAIL)"
            rc=10
            ;;
        clean)
            if [[ "$previous_state" == "listed" ]]; then
                say "DBL CHANGE: $domain was DELISTED"
                rc=11
                if [[ "$flush" == "yes" ]]; then
                    need_bin postqueue "install postfix"
                    if postqueue -f; then
                        say "Postfix deferred queue flush requested."
                    else
                        warn "postqueue -f failed"
                    fi
                else
                    say "Optional deferred-queue retry: postqueue -f"
                fi
                say "Messages previously rejected as NOQUEUE still require manual resend."
            else
                say "DBL query recovered: $domain is not listed"
                rc=13
            fi
            ;;
        error)
            say "DBL WATCH ERROR: $domain — $DBL_WATCH_DETAIL"
            rc=12
            ;;
    esac

    logline "DBL watch change: domain=$domain old=$previous_state/$previous_detail new=$DBL_WATCH_STATE/$DBL_WATCH_DETAIL"
    return "$rc"
}

count_active_parameter() {
    local parameter="$1"
    awk -v p="$parameter" '
        /^[[:space:]]*#/ { next }
        $0 ~ "^[[:space:]]*" p "[[:space:]]*=" { count++ }
        END { print count+0 }
    ' "$MAIN_CF"
}

check_duplicate_parameters() {
    local parameter count found=0
    local -a parameters=(
        relayhost
        smtp_sasl_auth_enable
        smtp_sasl_password_maps
        smtp_sasl_security_options
        smtp_sasl_tls_security_options
        smtp_tls_policy_maps
        smtp_tls_security_level
        smtpd_sender_restrictions
    )

    for parameter in "${parameters[@]}"; do
        count="$(count_active_parameter "$parameter")"
        if ((count > 1)); then
            found=1
            warn "$parameter appears $count times in main.cf"
        fi
    done
    if [[ $found -eq 0 ]]; then
        ok "no duplicate managed parameters in main.cf"
    fi
    return 0
}

status_sasl_map() {
    local relay="$1"
    local mode value
    if [[ ! -f "$SASL_FILE" ]]; then
        warn "SASL password file is missing: $SASL_FILE"
        return
    fi
    mode="$(stat -Lc '%a' "$SASL_FILE")"
    if [[ "$mode" == "600" ]]; then
        ok "SASL password file mode: 0600"
    else
        warn "SASL password file mode is $mode; expected 600"
    fi

    value="$(postmap -q "$relay" "hash:$SASL_FILE" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
        ok "credential map contains the active relay key"
    else
        fail "credential map has no entry for $relay"
    fi
    value=""
    unset value
}

status_tls_policy() {
    local relay="$1"
    local policy=""
    if ! postconf_map_contains smtp_tls_policy_maps "hash:$TLS_POLICY_FILE"; then
        fail "TLS policy map is not connected through smtp_tls_policy_maps"
        return
    fi
    if [[ -f "$TLS_POLICY_FILE" ]]; then
        policy="$(postmap -q "$relay" "hash:$TLS_POLICY_FILE" 2>/dev/null || true)"
    fi
    if [[ "$policy" == "encrypt" || "$policy" == "secure" ]]; then
        ok "relay TLS policy: $policy"
    else
        fail "no mandatory TLS policy found for $relay"
    fi
}

cmd_status() {
    validate_installation
    need_bin dig "install dnsutils"
    need_bin postqueue "install postfix"
    need_bin postmap "install postfix"

    AUDIT_DOMAIN=""
    AUDIT_SPF_INCLUDE=""
    resolve_audit_context "$@"

    local domain="$AUDIT_DOMAIN"
    local include="$AUDIT_SPF_INCLUDE"
    local relay current myip reverse queue_tail

    hdr "Platform"
    say "  detected: $(platform_name)"
    say "  config directory: $POSTFIX_DIR"
    say "  main.cf: $MAIN_CF"
    say "  delivery-test log: $MAILLOG"

    hdr "Spamhaus DBL: $domain"
    query_dnsbl "${domain}.dbl.spamhaus.org" dbl_verdict

    hdr "Spamhaus ZEN: origin IP"
    myip="$(outbound_ip || true)"
    if ! is_public_ipv4 "$myip"; then
        warn "could not determine a public origin IPv4 (detected: ${myip:-none})"
    else
        reverse="$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$myip")"
        say "  origin IP: $myip"
        query_dnsbl "${reverse}.zen.spamhaus.org" zen_verdict
    fi

    hdr "Postfix relay"
    relay="$(postconf -h relayhost)"
    if [[ -n "$relay" ]]; then
        say "  relayhost: $relay"
        if [[ "$(postconf -h smtp_sasl_auth_enable)" == "yes" ]]; then
            ok "SMTP client SASL authentication enabled"
        else
            fail "relay is set but smtp_sasl_auth_enable is not yes"
        fi
        status_sasl_map "$relay"
        status_tls_policy "$relay"
        if load_managed_state && [[ "$STATE_RELAY_NEXTHOP" == "$relay" ]]; then
            say "  sending domain: ${STATE_RELAY_DOMAIN:-<not recorded>}"
            say "  provider SPF include: ${STATE_SPF_INCLUDE:-<not recorded>}"
        else
            warn "relay detected from Postfix, but SPF metadata is not recorded"
            say "  use --spf-include with the value documented by your relay provider"
        fi
    else
        say "  relayhost: <empty> — direct delivery"
    fi
    say "  global smtp_tls_security_level: $(postconf -h smtp_tls_security_level)"
    if [[ "$(postconf -h smtp_tls_security_level)" == "encrypt" ]]; then
        warn "global encrypt can break some direct delivery after relay-off; verify the host policy"
    fi

    hdr "Sender RHSBL safety"
    current="$(postconf -h smtpd_sender_restrictions)"
    if [[ "$current" != *reject_rhsbl_sender* ]]; then
        say "  no sender RHSBL checks configured"
    elif bypass_is_safe "$current"; then
        ok "authenticated users and mynetworks bypass sender RHSBL"
        if [[ "$current" == *reject_authenticated_sender_login_mismatch* ]]; then
            say "  anti-spoof before bypass: yes"
        else
            say "  anti-spoof before bypass: no"
        fi
    else
        fail "own authenticated users can be rejected while their domain is listed"
        say "  run: sudo $0 fix-submission"
    fi
    if sender_restrictions_override_present; then
        warn "$MASTER_CF contains a per-service smtpd_sender_restrictions override"
        warn "the global main.cf safety result may not apply to every listener"
    else
        ok "no per-service smtpd_sender_restrictions override detected"
    fi
    say "  mynetworks: $(postconf -h mynetworks)"

    hdr "Configuration hygiene"
    check_duplicate_parameters
    if postfix check >/dev/null 2>&1; then
        ok "postfix check passed"
    else
        fail "postfix check failed"
    fi

    hdr "Queue"
    queue_tail="$(postqueue -p 2>/dev/null | tail -n1 || true)"
    say "  ${queue_tail:-unable to read queue}"

    spf_report "$domain" "$include" || true

    say ""
    say "DBL delisting: https://check.spamhaus.org"
}

# ---------------------------------------------------------------------------
# Real delivery-chain test
# ---------------------------------------------------------------------------

validate_email_address() {
    local address="$1"
    [[ "$address" =~ ^[^[:space:]@\<\>]+@[^[:space:]@\<\>]+$ ]]
}

relay_hostname_from_nexthop() {
    local relay="$1"
    relay="${relay#smtp:}"

    if [[ "$relay" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$relay" =~ ^([^:]+):([0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$relay" != *:* ]]; then
        printf '%s' "$relay"
    fi
}

relay_port_from_nexthop() {
    local relay="$1"
    relay="${relay#smtp:}"

    if [[ "$relay" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        printf '%s' "${BASH_REMATCH[3]:-25}"
    elif [[ "$relay" =~ ^([^:]+):([0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    elif [[ "$relay" != *:* && -n "$relay" ]]; then
        printf '25'
    fi
}

cmd_test() {
    need_root
    validate_installation
    need_bin sendmail "provided by postfix"
    [[ -f "$MAILLOG" ]] \
        || die "$MAILLOG not found; set PRR_MAILLOG to the active file-based Postfix log"

    local recipient="" sender="" timeout_seconds=90
    local domain token qid="" line="" status="" relay expected_host sendmail_bin
    local i

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                require_option_value "$1" "$#"
                sender="$2"
                shift 2
                ;;
            --timeout)
                require_option_value "$1" "$#"
                timeout_seconds="$2"
                shift 2
                ;;
            -*)
                die "test: unknown option '$1'"
                ;;
            *)
                [[ -z "$recipient" ]] || die "test accepts one recipient"
                recipient="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$recipient" ]]; then
        [[ -t 0 ]] || die "test recipient is required"
        read -rp "External test recipient: " recipient
    fi
    validate_email_address "$recipient" || die "invalid recipient address"
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || die "timeout must be numeric"
    ((timeout_seconds >= 10 && timeout_seconds <= 600)) \
        || die "timeout must be between 10 and 600 seconds"

    domain="$(primary_domain)"
    if ! validate_domain "$domain"; then
        if [[ -n "$sender" ]]; then
            domain="${sender##*@}"
        else
            die "could not determine a valid sender domain; pass --from"
        fi
    fi
    validate_domain "$domain" || die "could not determine a valid Message-ID domain"
    sender="${sender:-postmaster@$domain}"
    validate_email_address "$sender" || die "invalid sender address"
    sendmail_bin="$(command -v sendmail)"

    token="postfix-relay-rescue-$(date +%s)-${RANDOM}${RANDOM}"
    relay="$(postconf -h relayhost)"
    if [[ -n "$relay" ]]; then
        expected_host="$(relay_hostname_from_nexthop "$relay")"
        say "expected next hop: $relay"
    else
        expected_host=""
        warn "relayhost is empty; this will test direct delivery"
    fi

    "$sendmail_bin" -i -f "$sender" "$recipient" <<EOF
From: Postfix relay test <$sender>
To: <$recipient>
Date: $(date -R)
Subject: postfix-relay-rescue test $token
Message-ID: <$token@$domain>
Auto-Submitted: auto-generated

Plain-text delivery-chain test from postfix-relay-rescue v$VERSION.
Host: $(hostname -f)
Token: $token
EOF

    ok "message accepted by local sendmail; locating queue ID"
    for ((i=0; i<20; i++)); do
        qid="$(grep -F "$token" "$MAILLOG" 2>/dev/null \
            | sed -nE 's|.*postfix/cleanup\[[0-9]+\]: ([0-9A-Za-z]+): message-id=.*|\1|p' \
            | tail -n1 || true)"
        [[ -n "$qid" ]] && break
        sleep 1
    done
    [[ -n "$qid" ]] || die "could not find the test queue ID in $MAILLOG"
    say "queue ID: $qid"

    for ((i=0; i<timeout_seconds; i++)); do
        line="$(grep -E "\]: ${qid}: to=" "$MAILLOG" 2>/dev/null | tail -n1 || true)"
        case "$line" in
            *status=sent*)
                if [[ -n "$expected_host" && "$line" != *"relay=${expected_host}["* && "$line" != *"relay=${expected_host}:"* ]]; then
                    fail "message was accepted by an unexpected next hop:"
                    say "$line"
                    return 3
                fi
                ok "ACCEPTED BY NEXT HOP: ${line#*"$qid": }"
                say "This confirms transport to the relay/remote MX, not final inbox placement."
                logline "test accepted by next hop: qid=$qid recipient=$recipient"
                return 0
                ;;
            *status=bounced*)
                fail "BOUNCED: ${line#*"$qid": }"
                logline "test bounced: qid=$qid recipient=$recipient"
                return 1
                ;;
            *status=deferred*)
                status="$line"
                ;;
        esac
        sleep 1
    done

    if [[ -n "$status" ]]; then
        warn "still deferred after ${timeout_seconds}s: ${status#*"$qid": }"
    else
        warn "no terminal delivery status after ${timeout_seconds}s"
    fi
    say "inspect: grep '$qid' '$MAILLOG'; postqueue -p"
    return 2
}

# ---------------------------------------------------------------------------
# CLI and interactive UI
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
postfix-relay-rescue.sh v$VERSION

Usage:
  $0                         interactive menu
  $0 preflight [options]     verify relay DNS, TCP, STARTTLS, and certificate
  $0 setup [relay options]   configure relay + safe sender-RHSBL bypass
  $0 relay-on [options]      configure authenticated SMTP relay
  $0 relay-off [--purge-credentials]
  $0 fix-submission [--allow-nonloopback-mynetworks]
  $0 status [domain] [--spf-include DOMAIN]
                             DBL, ZEN, SPF, Postfix, maps, queue
  $0 spf [domain] [--spf-include DOMAIN]
                             SPF audit for any relay provider
  $0 watch [domain] [--flush-on-delist] [--verbose]
                             cron-friendly DBL state-change watcher
  $0 test [recipient] [--from address] [--timeout 90]
  $0 backups                 list complete snapshots
  $0 restore [snapshot] [--yes]
  $0 help

Relay options:
  --host HOST                authenticated STARTTLS relay hostname;
                             existing Postfix relayhost is auto-detected
  --port PORT                STARTTLS port; detected from relayhost or 587
  --user USER
  --password-file FILE       root-owned regular file, exactly mode 0400/0600,
                             containing one password line
  --domain DOMAIN            sending domain used for SPF audit
  --spf-include DOMAIN       provider-supplied SPF include; never guessed
  --skip-spf-check
  --allow-nonloopback-mynetworks

Preflight options:
  --host HOST                relay hostname; active relayhost if omitted
  --port PORT                STARTTLS port; detected from relayhost or 587
  --timeout SECONDS          connection timeout, 1-120 (default: 10)

Compatibility aliases:
  --setup, --relay, --disable, --bypass, --check, --test, --rollback

Important:
  - Passwords are never accepted as command-line arguments.
  - If --host is omitted, the active Postfix relayhost is reused when valid.
  - Re-running relay-on replaces the credential for that exact host:port key.
  - Snapshots include main.cf, credentials/maps, TLS policy/maps, and metadata.
  - watch exit codes: 10 listed, 11 delisted, 12 DNS error, 13 recovered.
  - 'status=sent' means accepted by the next hop, not guaranteed inbox delivery.
EOF
}

run_menu_child() {
    if bash "$0" "$@"; then
        :
    else
        local rc=$?
        warn "command exited with status $rc"
    fi
}

main_menu() {
    say "${C_CYN}postfix-relay-rescue v$VERSION${C_OFF}"
    say "Safe Postfix relay failover and sender-RHSBL recovery."
    PS3=$'\nchoice> '

    local opt
    select opt in \
        "Preflight SMTP relay" \
        "Configure SMTP relay" \
        "Apply safe Spamhaus DBL bypass" \
        "Configure relay + DBL bypass" \
        "Check current configuration" \
        "Test delivery chain" \
        "Restore latest snapshot" \
        "Disable relay" \
        "Quit"
    do
        if [[ -z "$opt" ]]; then
            warn "choose 1-9"
            continue
        fi
        case "$REPLY" in
            1) run_menu_child preflight ;;
            2) run_menu_child relay-on ;;
            3) run_menu_child fix-submission ;;
            4) run_menu_child setup ;;
            5) run_menu_child status ;;
            6) run_menu_child test ;;
            7) run_menu_child restore ;;
            8) run_menu_child relay-off ;;
            9) break ;;
            *) warn "choose 1-9" ;;
        esac
        say ""
    done
}

case "${1:-}" in
    help|-h|--help)
        usage
        exit 0
        ;;
esac

validate_installation
command_name="${1:-}"
[[ $# -gt 0 ]] && shift

case "$command_name" in
    preflight)
        cmd_preflight "$@"
        ;;
    setup|--setup|-s)
        cmd_setup "$@"
        ;;
    relay-on|--relay)
        cmd_relay_on "$@"
        ;;
    relay-off|--disable)
        cmd_relay_off "$@"
        ;;
    fix-submission|--bypass)
        cmd_fix_submission "$@"
        ;;
    status|--check|-c)
        cmd_status "$@"
        ;;
    spf)
        cmd_spf "$@"
        ;;
    watch)
        cmd_watch "$@"
        ;;
    test|--test|-t)
        cmd_test "$@"
        ;;
    backups)
        cmd_backups
        ;;
    restore|--rollback|-r)
        cmd_restore "$@"
        ;;
    "")
        main_menu
        ;;
    *)
        usage
        exit 1
        ;;
esac
