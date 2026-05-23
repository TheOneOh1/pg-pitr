#!/bin/bash
set -e

# ==============================
# 1. Detect PostgreSQL Version
# ==============================
PG_VERSION=$(ls /etc/postgresql/)
echo "[SANDBOX] Detected PostgreSQL Version: ${PG_VERSION}"

PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
PGCONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

# Ensure postgresql has initialized the data directory
if [ ! -d "${PGDATA}" ]; then
    echo "[SANDBOX] PostgreSQL cluster not initialized. Initializing..."
    pg_createcluster ${PG_VERSION} main
fi

# ==============================
# 2. Deploy pgBackRest Configuration
# ==============================
echo "[SANDBOX] Deploying /etc/pgbackrest.conf..."
cat > /etc/pgbackrest.conf << EOF
[global]
repo1-path=/var/lib/pgbackrest

# Retention
repo1-retention-full=7
repo1-retention-diff=7

# Performance
start-fast=y
process-max=2
archive-async=y
spool-path=/var/spool/pgbackrest

# Storage optimisation
repo1-bundle=y
repo1-block=y

# Compression
compress-type=zst
compress-level=3

# Logging
log-level-console=info
log-level-file=detail
log-level-stderr=off
log-path=/var/log/pgbackrest

[main]
pg1-path=${PGDATA}
pg1-port=5432
EOF

chown postgres:postgres /etc/pgbackrest.conf
chmod 640 /etc/pgbackrest.conf

# ==============================
# 3. Configure WAL Archiving in postgresql.conf
# ==============================
echo "[SANDBOX] Configuring WAL archiving in ${PGCONF}..."

# Remove any old archive configurations
sed -i '/# pgBackRest Archive Settings/,$d' "${PGCONF}" || true

cat >> "${PGCONF}" << EOF

# pgBackRest Archive Settings
wal_level = replica
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
archive_timeout = 60
max_wal_senders = 3
EOF

# Ensure all pgBackRest dirs have correct permissions
chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
chmod 750 /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest

# Make scripts executable
if [ -d "/scripts" ]; then
    chmod +x /scripts/*.sh || true
fi

# ==============================
# 4. Start PostgreSQL Service
# ==============================
echo "[SANDBOX] Starting PostgreSQL ${PG_VERSION}..."
pg_ctlcluster ${PG_VERSION} main start

# Wait for ready
until sudo -u postgres pg_isready -q; do
    echo "  Waiting for PostgreSQL to start..."
    sleep 1
done
echo "[SANDBOX] PostgreSQL is ready and running."

# ==============================
# 5. Initialize pgBackRest Stanza
# ==============================
echo "[SANDBOX] Initializing pgBackRest Stanza..."
sudo -u postgres pgbackrest --stanza=main stanza-create
sudo -u postgres pgbackrest --stanza=main check
echo "[SANDBOX] Stanza 'main' verified successfully."

# ==============================
# 6. Create Test Database & Table
# ==============================
echo "[SANDBOX] Setting up test database 'testpitr'..."
sudo -u postgres createdb testpitr || true
sudo -u postgres psql -d testpitr -c "
CREATE TABLE IF NOT EXISTS employees (
  id        SERIAL PRIMARY KEY,
  name      VARCHAR(50),
  salary    INT,
  created_at TIMESTAMP DEFAULT now()
);"

sudo -u postgres psql -d testpitr -c "
INSERT INTO employees(name, salary) VALUES
  ('Anand', 50000),
  ('Riya',  60000),
  ('Karan', 70000)
ON CONFLICT DO NOTHING;"

echo "[SANDBOX] Current test data in 'testpitr.employees':"
sudo -u postgres psql -d testpitr -c "SELECT * FROM employees;"

# ==============================
# 7. Take First Full Backup
# ==============================
echo "[SANDBOX] Taking first full baseline backup..."
sudo -u postgres pgbackrest --stanza=main backup --type=full
sudo -u postgres pgbackrest info

# ==============================
# 8. Start Cron Service for backups
# ==============================
service cron start

# ==============================
# 9. Instruction Block for User
# ==============================
cat << "EOF"

======================================================================
                  POSTGRESQL PITR DOCKER SANDBOX
======================================================================

The PostgreSQL 14+ and pgBackRest sandbox is ready.
A test database 'testpitr' has been created and backed up.

To test PITR (Point-in-Time Recovery):

1. Connect to the container in a separate terminal:
   docker exec -it pg_pitr_sandbox bash

2. View the baseline data:
   sudo -u postgres psql -d testpitr -c "SELECT * FROM employees;"

3. Note the current system time (This will be your recovery target!):
   date "+%Y-%m-%d %H:%M:%S"

4. Simulate a disaster (Wait 5-10 seconds first, then run):
   sudo -u postgres psql -d testpitr -c "DELETE FROM employees;"

5. Verify database is empty:
   sudo -u postgres psql -d testpitr -c "SELECT * FROM employees;"

6. Run the recovery script with the target time noted in Step 3:
   bash /scripts/auto-recovery.sh "YOUR-TIMESTAMP-HERE"

7. Verify that data has been recovered:
   sudo -u postgres psql -d testpitr -c "SELECT * FROM employees;"

======================================================================
EOF

# Stream postgresql log files to keep container alive and show WAL replays
tail -f /var/log/postgresql/postgresql-*.log
