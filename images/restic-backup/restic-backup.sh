#!/bin/bash
set -e

# --- Configuration from environment variables ---
DATA_DIR="${DATA_DIR:-/data}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY}"
RESTIC_PASSWORD="${RESTIC_PASSWORD}"
POSTGRES_HOST="${POSTGRES_HOST}"
POSTGRES_DB="${POSTGRES_DB}"
POSTGRES_USER="${POSTGRES_USER}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
POSTGRES_DUMP_FILE="${POSTGRES_DUMP_FILE:-db_dump.sql}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_GROUP_ID="${TELEGRAM_GROUP_ID}"
TELEGRAM_NOTIFY_ALWAYS="${TELEGRAM_NOTIFY_ALWAYS:-false}"

# --- Helper: Telegram notification ---
notify_telegram() {
    local message="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_GROUP_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_GROUP_ID}" \
            -d text="$message" >/dev/null
    fi
}

# --- Helper: Check/Init restic repo ---
check_or_init_repo() {
    if ! restic snapshots --no-lock >/dev/null 2>&1; then
        echo "Initializing restic repository..."
        restic init || { notify_telegram "Restic repo initialization failed"; exit 1; }
    fi
}

# --- Helper: Postgres dump ---
dump_postgres() {
    if [[ -n "$POSTGRES_HOST" && -n "$POSTGRES_DB" && -n "$POSTGRES_USER" && -n "$POSTGRES_PASSWORD" ]]; then
        echo "Dumping Postgres database..."
        PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB" > "$DATA_DIR/$POSTGRES_DUMP_FILE" || {
            notify_telegram "Postgres dump failed"; exit 1;
        }
    fi
}

# --- Helper: Check if directory is empty ---
data_dir_is_empty() {
    if [[ ! -d "$DATA_DIR" ]]; then
        return 0
    fi
    shopt -s dotglob nullglob
    local contents=("$DATA_DIR"/*)
    if (( ${#contents[@]} == 0 )); then
        return 0
    fi
    return 1
}

# --- Helper: Check if database is empty ---
db_is_empty() {
    if [[ -z "$POSTGRES_HOST" || -z "$POSTGRES_DB" || -z "$POSTGRES_USER" || -z "$POSTGRES_PASSWORD" ]]; then
        return 0
    fi
    local q="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';"
    local count
    set +e
    count="$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "$q" 2>/dev/null)"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        return 0
    fi
    if [[ "${count:-0}" =~ ^[0-9]+$ ]] && [[ "$count" -eq 0 ]]; then
        return 0
    fi
    return 1
}

# --- Helper: Select snapshot ---
select_snapshot() {
    local BEFORE="$1"
    local snaps
    snaps="$(restic snapshots --no-lock --json)"
    if [[ -z "$snaps" ]] || [[ "$(echo "$snaps" | jq 'length')" -eq 0 ]]; then
        echo ""
        return 0
    fi
    if [[ -z "$BEFORE" ]]; then
        echo "$snaps" | jq -r 'sort_by(.time) | last | .short_id'
    else
        local sid
        sid="$(echo "$snaps" | jq -r --arg t "$BEFORE" '[.[] | select(.time <= $t)] | sort_by(.time) | last | .short_id // empty')"
        echo "$sid"
    fi
}

# --- Backup ---
run_backup() {
    check_or_init_repo
    dump_postgres
    echo "Running restic backup..."
    if ! restic backup "$DATA_DIR"; then
        notify_telegram "Restic backup failed"
        exit 1
    fi
    if [[ "$TELEGRAM_NOTIFY_ALWAYS" == "true" ]]; then
        notify_telegram "Restic backup completed successfully"
    fi
}

# --- Restore ---
run_restore() {
    check_or_init_repo
    local BEFORE="$1"
    local restored=false
    local snap
    snap="$(select_snapshot "$BEFORE")"
    if [[ -z "$snap" ]]; then
        echo "No matching snapshots found; nothing to restore."
        return 0
    fi
    if data_dir_is_empty; then
        echo "Restoring snapshot $snap to $DATA_DIR..."
        if restic restore --no-lock "$snap" --target "/"; then
            restored=true
        else
            notify_telegram "Restic restore (filesystem) failed"
            exit 1
        fi
    else
        echo "DATA_DIR is not empty, skipping filesystem restore."
    fi
    if db_is_empty; then
        if [[ -n "$POSTGRES_HOST" && -n "$POSTGRES_DB" && -n "$POSTGRES_USER" && -n "$POSTGRES_PASSWORD" ]]; then
            local dump_file="$DATA_DIR/$POSTGRES_DUMP_FILE"
            if [[ -f "$dump_file" ]]; then
                echo "Restoring Postgres DB from $dump_file..."
                if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$dump_file"; then
                    restored=true
                else
                    notify_telegram "Restic restore (database) failed"
                    exit 1
                fi
            else
                echo "No Postgres dump file found at $dump_file, skipping DB restore."
            fi
        fi
    else
        echo "Database is not empty, skipping DB restore."
    fi
    if [[ "$TELEGRAM_NOTIFY_ALWAYS" == "true" && "$restored" == true ]]; then
        notify_telegram "Restic restore completed successfully"
    fi
}

# --- Cron setup ---
setup_cron() {
    local cron_expr="$1"
    echo "$cron_expr /usr/local/bin/restic-backup.sh backup" > /etc/supercronic
    echo "Cron job set: $cron_expr backup"
    supercronic /etc/supercronic
}

# --- Help ---
show_help() {
    cat <<EOF
Usage:
  $0 backup [--schedule "<cron expression>"]
  $0 restore [--before "YYYY-MM-DD" | "YYYY-MM-DDTHH:MM:SSZ"]

Configuration (via environment variables):
  DATA_DIR                Directory to backup/restore (default: /data)
  RESTIC_REPOSITORY       Restic repository URL
  RESTIC_PASSWORD         Restic repository password
  POSTGRES_HOST           Postgres host (optional, for DB backup/restore)
  POSTGRES_DB             Postgres database name
  POSTGRES_USER           Postgres user
  POSTGRES_PASSWORD       Postgres password
  POSTGRES_DUMP_FILE      Filename for DB dump in DATA_DIR (default: db_dump.sql)
  TELEGRAM_BOT_TOKEN      Telegram bot token (optional, for notifications)
  TELEGRAM_GROUP_ID       Telegram group/chat ID (optional)
  TELEGRAM_NOTIFY_ALWAYS  Send Telegram notification always (true/false, default: false)
EOF
}

# --- Main ---
CMD="$1"
shift || true
case "$CMD" in
    backup)
        if [[ "$1" == "--schedule" ]]; then
            shift
            cron_expr="$1"
            if [[ -z "$cron_expr" ]]; then
                echo "ERROR: --schedule requires a cron expression" >&2
                exit 2
            fi
            setup_cron "$cron_expr"
        else
            run_backup
        fi
        ;;
    restore)
        BEFORE=""
        if [[ "$1" == "--before" ]]; then
            shift
            BEFORE="$1"
            if [[ -z "$BEFORE" ]]; then
                echo "ERROR: --before requires a date value" >&2
                exit 2
            fi
            shift
        fi
        run_restore "$BEFORE"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
