#!/bin/bash
# set -x
# Get the current date for the filename
DATE=$(date +%Y-%m-%d_%H%M%S)
BACKUP_DIR="/data/LT/Backups/ClientsHowto"
BACKUP_FILE="$BACKUP_DIR/register_${DATE}.db"

# Safely extract a pristine snapshot using SQLite's backup engine
sqlite3 /var/lib/langtechdepot/register.db ".backup '${BACKUP_FILE}'"

# Keep the backup directory tidy: Delete snapshots older than 30 days
find $BACKUP_DIR -name "register_*.db" -type f -mtime +30 -delete
# set +x
