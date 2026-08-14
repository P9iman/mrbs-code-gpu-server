#!/usr/bin/env bash
set -euo pipefail

# PAM account check for SSH password login backed by MRBS bookings.
#
# Expected environment from pam_exec:
# - PAM_USER: Linux account username attempting to log in
# Optional:
# - PAM_RHOST: remote host (for logging)
#
# Required local files:
# - /etc/security/mrbs-pam.cnf   (mysql client credentials)
# - /etc/security/mrbs-pam.env   (policy settings)

CONFIG_ENV="/etc/security/mrbs-pam.env"
MYSQL_CNF="/etc/security/mrbs-pam.cnf"

if [[ ! -r "$CONFIG_ENV" ]]; then
  logger -t mrbs-pam "deny: missing $CONFIG_ENV"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_ENV"

required_vars=(MRBS_DB_NAME MRBS_VM_HOSTNAME MRBS_POLICY)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    logger -t mrbs-pam "deny: missing required var $v in $CONFIG_ENV"
    exit 1
  fi
done

if [[ ! -r "$MYSQL_CNF" ]]; then
  logger -t mrbs-pam "deny: missing $MYSQL_CNF"
  exit 1
fi

if [[ -z "${PAM_USER:-}" ]]; then
  logger -t mrbs-pam "deny: PAM_USER empty"
  exit 1
fi

sql_escape() {
  # Escape single quotes for safe SQL string literals.
  printf "%s" "$1" | sed "s/'/''/g"
}

# Optional whitelist for service accounts that must bypass booking checks.
if [[ -n "${MRBS_BYPASS_USERS:-}" ]]; then
  IFS=',' read -r -a bypass_users <<< "$MRBS_BYPASS_USERS"
  for u in "${bypass_users[@]}"; do
    if [[ "$PAM_USER" == "$u" ]]; then
      logger -t mrbs-pam "allow: bypass user=$PAM_USER"
      exit 0
    fi
  done
fi

escaped_user="$(sql_escape "$PAM_USER")"
escaped_host="$(sql_escape "$MRBS_VM_HOSTNAME")"

# Hostname mapping is explicit to avoid accidental cross-VM access.
# Table expected:
#   mrbs_vm_access_map(vm_hostname, room_id)
# See ops/pam/mrbs_vm_access_map.my.sql
if [[ "$MRBS_POLICY" == "owner_or_participant" ]]; then
  SQL="SELECT 1
FROM mrbs_vm_access_map m
JOIN mrbs_entry e
  ON e.room_id = m.room_id
LEFT JOIN mrbs_participants p
  ON p.entry_id = e.id
 AND p.username = '${escaped_user}'
WHERE m.vm_hostname = '${escaped_host}'
  AND e.start_time <= UNIX_TIMESTAMP()
  AND e.end_time > UNIX_TIMESTAMP()
  AND (e.create_by = '${escaped_user}' OR p.username = '${escaped_user}')
LIMIT 1;"
elif [[ "$MRBS_POLICY" == "owner_only" ]]; then
  SQL="SELECT 1
FROM mrbs_vm_access_map m
JOIN mrbs_entry e
  ON e.room_id = m.room_id
WHERE m.vm_hostname = '${escaped_host}'
  AND e.start_time <= UNIX_TIMESTAMP()
  AND e.end_time > UNIX_TIMESTAMP()
  AND e.create_by = '${escaped_user}'
LIMIT 1;"
else
  logger -t mrbs-pam "deny: invalid MRBS_POLICY=$MRBS_POLICY"
  exit 1
fi

result=$(mysql --defaults-extra-file="$MYSQL_CNF" --database="$MRBS_DB_NAME" --batch --skip-column-names --execute "$SQL" 2>/dev/null || true)

if [[ "$result" == "1" ]]; then
  logger -t mrbs-pam "allow: user=$PAM_USER host=$MRBS_VM_HOSTNAME"
  exit 0
fi

logger -t mrbs-pam "deny: no active booking user=$PAM_USER host=$MRBS_VM_HOSTNAME"
exit 1
