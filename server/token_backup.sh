#!/bin/bash
# Nightly snapshot of the registration database, run by root's cron.
#
# Install a root-owned copy; do not symlink into a checkout (anyone who can
# edit the checkout would then be running code as root):
#   sudo install -o root -g root -m 755 token_backup.sh /usr/local/bin/
# and re-run that after every edit to this file.
#
# Cron discards output, so every failure is also sent to the journal:
#   journalctl -t token_backup
set -eu
umask 027

DB=/var/lib/langtechdepot/register.db
BACKUP_DIR="/data/LT/Backups/ClientsHowto"
DATE=$(date +%Y-%m-%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/register_${DATE}.db"

fail() {
    echo "token_backup: $*" >&2
    logger -t token_backup -p user.err "FAILED: $*" 2>/dev/null || true
    exit 1
}

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is not installed (apt install sqlite3)"
[ -r "$DB" ] || fail "cannot read $DB"
[ -d "$BACKUP_DIR" ] || fail "backup directory $BACKUP_DIR does not exist"

# Safely extract a pristine snapshot using SQLite's backup engine, then make
# sure what landed is a whole database rather than trusting the exit code.
sqlite3 "$DB" ".backup '${BACKUP_FILE}'" || fail "sqlite3 .backup to $BACKUP_FILE failed"
[ -s "$BACKUP_FILE" ] || fail "$BACKUP_FILE is missing or empty"
CHECK=$(sqlite3 "$BACKUP_FILE" "PRAGMA integrity_check;" 2>&1) || fail "cannot open $BACKUP_FILE: $CHECK"
[ "$CHECK" = "ok" ] || fail "$BACKUP_FILE failed integrity_check: $CHECK"

# Keep the backup directory tidy: delete snapshots older than 30 days.
find "$BACKUP_DIR" -name 'register_*.db' -type f -mtime +30 -delete \
    || fail "could not prune old snapshots in $BACKUP_DIR"

logger -t token_backup "wrote $BACKUP_FILE" 2>/dev/null || true
