#!/bin/bash

set -e

TARGET_TIME="$1"
PGDATA="/var/lib/postgresql/14/main"
BACKUP_OLD="/var/lib/postgresql/14/main-old-$(date +%Y%m%d_%H%M%S)"

if [ -z "$TARGET_TIME" ]; then
  echo "Usage: $0 \"YYYY-MM-DD HH:MM:SS\""
  exit 1
fi

echo "=== pgBackRest PITR Recovery ==="
echo "Target time: $TARGET_TIME"
echo ""

# Step 1: Stop PostgreSQL
echo "[1/6] Stopping PostgreSQL..."
sudo systemctl stop postgresql

# Step 2: Handle existing data directory
if [ -d "$PGDATA" ] && [ "$(ls -A "$PGDATA")" ]; then
  echo "[2/6] Moving existing data directory to $BACKUP_OLD"
  sudo mv "$PGDATA" "$BACKUP_OLD"
  sudo mkdir -p "$PGDATA"
  sudo chown postgres:postgres "$PGDATA"
  sudo chmod 700 "$PGDATA"
else
  echo "[2/6] Data directory is empty, skipping move."
fi

# Step 3: Run restore with target-action=promote
echo "[3/6] Restoring to target time: $TARGET_TIME ..."
sudo -u postgres pgbackrest \
  --stanza=main \
  restore \
  --type=time \
  "--target=$TARGET_TIME" \
  --target-action=promote

# Step 4: Start PostgreSQL
echo "[4/6] Starting PostgreSQL..."
sudo systemctl start postgresql

# Step 5: Wait for PostgreSQL to be ready before promoting
echo "[5/6] Waiting for PostgreSQL to be ready..."
until sudo -u postgres pg_isready -q; do
  echo "  Still waiting..."
  sleep 2
done

# Step 6: Confirm promotion (belt-and-suspenders; target-action=promote handles this automatically)
echo "[6/6] Confirming database is in read-write mode..."
RW_CHECK=$(sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();")
if [ "$RW_CHECK" = "t" ]; then
  echo "  Database still in recovery - promoting manually..."
  sudo -u postgres psql -c "SELECT pg_promote();"
  sleep 3
fi

echo ""
echo "=== Recovery completed successfully ==="
echo "Verify your data before removing the old directory: $BACKUP_OLD"
