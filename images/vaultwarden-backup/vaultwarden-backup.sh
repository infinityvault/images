#!/usr/bin/env bash
set -euo pipefail

# vaultwarden-backup
# Commands:
#   backup                     Create a pg_dump (.dump) in $DATA_DIR and snapshot $DATA_DIR with restic
#   restore [--before DATE]    If $DATA_DIR and the Postgres DB are empty, restore the latest (or latest before DATE)
#
# Required env:
#   DATA_DIR                        e.g. /data/vaultwarden
#   RESTIC_REPOSITORY               e.g. s3:https://s3.eu-central-1.amazonaws.com/my-bucket/restic
#   RESTIC_PASSWORD or RESTIC_PASSWORD_FILE
#   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE   (standard libpq envs)
#
# S3 env (one typical option):
#   AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
#
# Optional env:
#   RESTIC_TAGS                     e.g. "vaultwarden,prod"
#   RESTIC_HOST                     override restic host metadata
#   RESTIC_EXTRA_BACKUP_ARGS        extra flags for "restic backup"
#   PGDUMP_EXTRA_ARGS               extra flags for "pg_dump" (default uses -Fc)
#   LOG_LEVEL                       info|debug (default info)

LOG_LEVEL="${LOG_LEVEL:-info}"

log() {
  local level="$1"; shift
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  # Show debug only if requested
  if [[ "$level" == "debug" && "$LOG_LEVEL" != "debug" ]]; then
    return
  fi
  echo "[$ts] [$level] $*" >&2
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: environment variable $name is required" >&2
    exit 2
  fi
}

usage() {
  cat >&2 <<EOF
Usage:
  vaultwarden-backup backup
  vaultwarden-backup restore [--before "YYYY-MM-DD" | "YYYY-MM-DDTHH:MM:SSZ"]

Environment:
  DATA_DIR, RESTIC_REPOSITORY, RESTIC_PASSWORD or RESTIC_PASSWORD_FILE,
  PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE
  (and for S3: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION)
EOF
  exit 1
}

# --- Checks ---

check_prereqs() {
  command -v restic >/dev/null || { echo "restic not found"; exit 127; }
  command -v pg_dump >/dev/null || { echo "pg_dump not found"; exit 127; }
  command -v pg_restore >/dev/null || { echo "pg_restore not found"; exit 127; }
  command -v psql >/dev/null || { echo "psql not found"; exit 127; }
  command -v jq >/dev/null || { echo "jq not found"; exit 127; }
}

check_required_envs() {
  require_env DATA_DIR
  require_env RESTIC_REPOSITORY
  if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    echo "ERROR: Set RESTIC_PASSWORD or RESTIC_PASSWORD_FILE" >&2
    exit 2
  fi
  require_env PGHOST
  require_env PGPORT
  require_env PGUSER
  require_env PGPASSWORD
  require_env PGDATABASE
}

# Return 0 if dir is "empty enough"
data_dir_is_empty() {
  # Consider empty if there are no files/dirs at depth >=1
  # (ignores non-existent dir as empty too)
  if [[ ! -d "$DATA_DIR" ]]; then
    log info "DATA_DIR does not exist; treating as empty: $DATA_DIR"
    return 0
  fi
  # Count entries (including dotfiles)
  shopt -s dotglob nullglob
  local contents=("$DATA_DIR"/*)
  if (( ${#contents[@]} == 0 )); then
    return 0
  fi
  return 1
}

# Return 0 if database has zero user tables in public schema
db_is_empty() {
  local q="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';"
  local count
  set +e
  count="$(psql -tA -c "$q" 2>/dev/null)"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log info "psql query failed (database may not exist yet); treating DB as empty"
    return 0
  fi
  if [[ "${count:-0}" =~ ^[0-9]+$ ]] && [[ "$count" -eq 0 ]]; then
    return 0
  fi
  return 1
}

# --- Snapshot Selection ---

# Outputs snapshot ID to stdout.
# If BEFORE is empty -> latest overall.
# If BEFORE provided -> latest snapshot with .time <= BEFORE (string compare works for RFC3339Z)
select_snapshot() {
  local BEFORE="${1:-}"
  if [[ -n "$BEFORE" && ! "$BEFORE" =~ Z$ && "$BEFORE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    BEFORE="${BEFORE}T23:59:59Z"
  fi

  local snaps
  snaps="$(restic snapshots --json)"
  if [[ -z "$snaps" ]] || [[ "$(echo "$snaps" | jq 'length')" -eq 0 ]]; then
    echo ""
    return 0
  fi

  if [[ -z "$BEFORE" ]]; then
    # Latest snapshot overall
    echo "$snaps" | jq -r 'sort_by(.time) | last | .short_id'
  else
    # Latest snapshot with time <= BEFORE
    local sid
    sid="$(echo "$snaps" | jq -r --arg t "$BEFORE" '[.[] | select(.time <= $t)] | sort_by(.time) | last | .short_id // empty')"
    echo "$sid"
  fi
}

# --- Actions ---

do_backup() {
  check_required_envs
  mkdir -p "$DATA_DIR"

  local ts dumpfile
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dumpfile="$DATA_DIR/pgdump-${PGDATABASE}-${ts}.dump"

  log info "Creating Postgres dump -> $dumpfile"
  pg_dump -Fc ${PGDUMP_EXTRA_ARGS:-} -f "$dumpfile"

  log info "Running restic backup of $DATA_DIR"
  local tags=()
  if [[ -n "${RESTIC_TAGS:-}" ]]; then
    IFS=',' read -r -a tags <<< "$RESTIC_TAGS"
    local tagargs=()
    for t in "${tags[@]}"; do
      tagargs+=("--tag" "$t")
    done
    restic backup "${tagargs[@]}" ${RESTIC_HOST:+--host "$RESTIC_HOST"} ${RESTIC_EXTRA_BACKUP_ARGS:-} "$DATA_DIR"
  else
    restic backup ${RESTIC_HOST:+--host "$RESTIC_HOST"} ${RESTIC_EXTRA_BACKUP_ARGS:-} "$DATA_DIR"
  fi

  log info "Backup completed."
}

do_restore() {
  check_required_envs

  local BEFORE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --before)
        shift
        BEFORE="${1:-}"
        if [[ -z "$BEFORE" ]]; then
          echo "ERROR: --before requires a date value" >&2
          exit 2
        fi
        shift
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        ;;
    esac
  done

  if ! data_dir_is_empty; then
    log info "DATA_DIR is not empty; skipping restore."
    return 0
  fi
  if ! db_is_empty; then
    log info "Database is not empty; skipping restore."
    return 0
  fi

  log info "Selecting snapshot ${BEFORE:+before $BEFORE}..."
  local snap
  snap="$(select_snapshot "$BEFORE")"
  if [[ -z "$snap" ]]; then
    log info "No matching snapshots found; nothing to restore."
    return 0
  fi
  log info "Restoring snapshot $snap"

  # Restore to original absolute path(s). This will place the files back at the recorded paths.
  # Ensure that the container has $DATA_DIR mounted at the same absolute path as when backed up.
  restic restore "$snap" --target /

  # Find the newest pgdump file in the restored DATA_DIR and restore it.
  # If none found, we just restored files (still useful).
  local newest_dump
  if [[ -d "$DATA_DIR" ]]; then
    newest_dump="$(find "$DATA_DIR" -maxdepth 1 -type f -name 'pgdump-*.dump' -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}' | tail -n1 || true)"
  fi

  if [[ -n "${newest_dump:-}" && -f "$newest_dump" ]]; then
    log info "Restoring Postgres from dump: $newest_dump"
    pg_restore -d "$PGDATABASE" --clean --if-exists "$newest_dump"
  else
    log info "No pgdump-*.dump found in DATA_DIR after file restore; skipping DB restore."
  fi

  log info "Restore completed."
}

# --- Main ---

check_prereqs

case "${1:-}" in
  backup)
    shift
    if [[ "${1:-}" == "--schedule" ]]; then
      shift
      schedule="$1"
      if [[ -z "$schedule" ]]; then
        echo "ERROR: --schedule requires a cron expression" >&2
        exit 2
      fi
      log info "Starting scheduled backups with cron: $schedule"
      echo "$schedule /usr/local/bin/vaultwarden-backup backup" > /etc/crontabs/root
      crond -f -d 0
    else
      do_backup "$@"
    fi
    ;;
  restore)
    shift
    do_restore "$@"
    ;;
  *)
    usage
    ;;
esac
