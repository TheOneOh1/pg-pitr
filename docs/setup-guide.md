# pgBackRest PITR Setup Guide
**PostgreSQL 14+ on Ubuntu 24.04**
**Version:** 2.0 | **Last Updated:** April 2026

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Install Packages](#3-install-packages)
4. [Identify PostgreSQL Paths](#4-identify-postgresql-paths)
5. [Create Backup Repository](#5-create-backup-repository)
6. [Configure pgBackRest](#6-configure-pgbackrest)
7. [Enable WAL Archiving](#7-enable-wal-archiving)
8. [Create & Validate Stanza](#8-create--validate-stanza)
9. [Take First Full Backup](#9-take-first-full-backup)
10. [Production Backup Schedule](#10-production-backup-schedule)
11. [Monitoring & Verification](#11-monitoring--verification)
12. [Test Case - Sample Database](#12-test-case--sample-database)
13. [Simulate Disaster & PITR Recovery](#13-simulate-disaster--pitr-recovery)
14. [Latest Restore (No PITR)](#14-latest-restore-no-pitr)
15. [Automated Recovery Script](#15-automated-recovery-script)
16. [Troubleshooting](#16-troubleshooting)
17. [Real-World Issues & Resolutions](#17-real-world-issues--resolutions)
18. [Understanding PITR - Concepts & Strategy](#18-understanding-pitr--concepts--strategy)
19. [Best Practices](#19-best-practices)
20. [Quick Reference Commands](#20-quick-reference-commands)

---

## 1. Architecture Overview

| Parameter | Value |
|---|---|
| OS | Ubuntu 24.04 |
| PostgreSQL | 14+ |
| Topology | Single PostgreSQL VM |
| Backup Repository | Local (separate disk recommended) |
| Offsite/Remote Copy | Optional, add later via `repo2` |
| WAL Archiving | Continuous (async) |

---

## 2. Prerequisites

Before starting, confirm:

- [ ] PostgreSQL 14+ is installed and running
- [ ] `postgres` system user exists
- [ ] Backup repository path is on a **separate disk** from PostgreSQL data
- [ ] System clock is synced via NTP (`timedatectl status`)
- [ ] You have at least **3x** the size of your PostgreSQL data directory in free disk space

---

## 3. Install Packages

```bash
sudo apt update
sudo apt install -y postgresql postgresql-client pgbackrest
```

> 💡 **Automation Tip:** You can automate the entire package installation, directory provisioning, config deployment, and stanza initialization using the idempotent setup script: [scripts/setup-pgbackrest.sh](../scripts/setup-pgbackrest.sh).


Verify:

```bash
pgbackrest version
psql --version
```

---

## 4. Identify PostgreSQL Paths

```bash
psql -U postgres -c "SHOW data_directory;"
psql -U postgres -c "SHOW config_file;"
```

Typical Ubuntu 24.04 paths:

| Item | Path |
|---|---|
| Data Directory | `/var/lib/postgresql/14/main` |
| Config File | `/etc/postgresql/14/main/postgresql.conf` |
| PostgreSQL Logs | `/var/log/postgresql/postgresql-14-main.log` |

> ⚠️ Confirm these paths before proceeding. Update all config references if yours differ.

---

## 5. Create Backup Repository

```bash
sudo mkdir -p /var/lib/pgbackrest
sudo chown -R postgres:postgres /var/lib/pgbackrest
sudo chmod 750 /var/lib/pgbackrest
```

Also create the log directory:

```bash
sudo mkdir -p /var/log/pgbackrest
sudo chown -R postgres:postgres /var/log/pgbackrest
```

---

## 6. Configure pgBackRest

Create `/etc/pgbackrest.conf`:

> 💡 **Standalone Template:** A production-ready, fully commented version of this configuration is available as a standalone file at [configs/pgbackrest.example.conf](../configs/pgbackrest.example.conf).


```ini
[global]
repo1-path=/var/lib/pgbackrest

# Retention
repo1-retention-full=7
repo1-retention-diff=7            # align with full retention window

# Performance
start-fast=y
process-max=2
archive-async=y                   # async WAL push, avoids blocking transactions
spool-path=/var/spool/pgbackrest  # required for async archiving

# Storage optimisation (pgBackRest 2.39+)
repo1-bundle=y                    # reduces small-file overhead
repo1-block=y                     # block-level incremental (pgBackRest 2.46+)

# Compression
compress-type=zst
compress-level=3

# Logging
log-level-console=info
log-level-file=detail
log-level-stderr=off              # keeps cron output clean
log-path=/var/log/pgbackrest

[main]
pg1-path=/var/lib/postgresql/14/main
pg1-port=5432
```

Create the spool directory for async archiving:

```bash
sudo mkdir -p /var/spool/pgbackrest
sudo chown postgres:postgres /var/spool/pgbackrest
sudo chmod 750 /var/spool/pgbackrest
```

---

## 7. Enable WAL Archiving

Edit `/etc/postgresql/14/main/postgresql.conf`:

> 💡 **Standalone Template:** A standalone template of these parameters is available at [configs/postgresql.example.conf](../configs/postgresql.example.conf).


```ini
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
archive_timeout = 60          # force WAL switch every 60s; tune for write volume
wal_level = replica
max_wal_senders = 3
```

> ⚠️ `archive_timeout=60` works well for low-to-medium write workloads. For high-write instances, increase it to reduce WAL file count.

Restart PostgreSQL and confirm it's running:

```bash
sudo systemctl restart postgresql
sudo systemctl status postgresql
```

---

## 8. Create & Validate Stanza

Create the stanza (run as `postgres` user):

```bash
sudo -u postgres pgbackrest --stanza=main stanza-create
```

Validate WAL archiving and stanza config:

```bash
sudo -u postgres pgbackrest --stanza=main check
```

Expected output: `check command end: completed successfully`

If this fails, stop here. See [Troubleshooting](#16-troubleshooting).

---

## 9. Take First Full Backup

```bash
sudo -u postgres pgbackrest --stanza=main backup --type=full
```

Verify:

```bash
sudo -u postgres pgbackrest info
```

You should see one backup entry with type `full`.

---

## 10. Production Backup Schedule

Edit the postgres user's crontab directly (avoids `sudo` prefix issues in cron):

```bash
sudo -u postgres crontab -e
```

Add:

```cron
# Full backup - daily at 2 AM
0 2 * * * pgbackrest --stanza=main backup --type=full

# Differential backup - every 6 hours
0 */6 * * * pgbackrest --stanza=main backup --type=diff

# Incremental backup - every hour (optional, reduces RPO)
0 * * * * pgbackrest --stanza=main backup --type=incr

# Weekly stanza verification
0 3 * * 0 pgbackrest --stanza=main verify
```

Backup strategy summary:

| Type | Frequency | Purpose |
|---|---|---|
| Full | Daily 2 AM | Base restore point |
| Differential | Every 6 hours | Faster restore than full replay |
| Incremental | Hourly (optional) | Tighter RPO |
| WAL Archiving | Continuous | Enables PITR to any second |
| Verify | Weekly | Confirms backup integrity |

---

## 11. Monitoring & Verification

Daily monitoring commands:

```bash
# Backup status and retention
sudo -u postgres pgbackrest info

# Validate stanza and WAL archiving
sudo -u postgres pgbackrest --stanza=main check

# Review recent logs
ls -lh /var/log/pgbackrest/
tail -100 /var/log/pgbackrest/main-backup.log
```

What to check daily:

- [ ] Latest backup timestamp is within expected window
- [ ] No `ERROR` or `WARN` lines in logs
- [ ] WAL archiving is current (no growing backlog)
- [ ] Disk space on repository is sufficient

---

## 12. Test Case - Sample Database

Use this to validate the full backup → disaster → PITR workflow before you need it for real.

### 12.1 Create Test Database

```bash
sudo -u postgres createdb testpitr
sudo -u postgres psql -d testpitr
```

Run inside psql:

```sql
CREATE TABLE employees (
  id        SERIAL PRIMARY KEY,
  name      VARCHAR(50),
  salary    INT,
  created_at TIMESTAMP DEFAULT now()
);

INSERT INTO employees(name, salary) VALUES
  ('Levi', 50000),
  ('Mikasa',  60000),
  ('Kenny', 70000);

SELECT * FROM employees;
```

Exit psql (`\q`).

### 12.2 Take Baseline Backup

```bash
sudo -u postgres pgbackrest --stanza=main backup --type=full
```

Note the current timestamp. You'll use this as the PITR target:

```bash
date '+%Y-%m-%d %H:%M:%S'
```

---

## 13. Simulate Disaster & PITR Recovery

### 13.1 Simulate Data Loss

```bash
sudo -u postgres psql -d testpitr -c "DELETE FROM employees;"
sudo -u postgres psql -d testpitr -c "SELECT * FROM employees;"
# Expected: 0 rows
```

### 13.2 Determine Recovery Target Time

Use a timestamp **just before** the DELETE. See [Section 18](#18-understanding-pitr--concepts--strategy) for how to pick the right one.

### 13.3 Stop PostgreSQL

```bash
sudo systemctl stop postgresql
```

### 13.4 Clear Existing Data Directory

pgBackRest won't restore into a non-empty directory.

```bash
# Move existing data directory somewhere safe
sudo mv /var/lib/postgresql/14/main /var/lib/postgresql/14/main-old-$(date +%Y%m%d_%H%M%S)

# Recreate empty target directory
sudo mkdir -p /var/lib/postgresql/14/main
sudo chown postgres:postgres /var/lib/postgresql/14/main
sudo chmod 700 /var/lib/postgresql/14/main
```

> **Alternative (delta restore):** If moving the directory isn't practical, use `--delta`. This is slower and has consistency risks only use it if you know what you're doing:
> ```bash
> sudo -u postgres pgbackrest --stanza=main restore \
>   --type=time --target="2026-04-28 11:30:00" \
>   --target-action=promote --delta
> ```

### 13.5 Restore to Target Time

```bash
sudo -u postgres pgbackrest --stanza=main restore \
  --type=time \
  --target="2026-04-28 11:30:00" \
  --target-action=promote
```

> ⚠️ `--target-action=promote` is **required** on PostgreSQL 12+. Without it, the database stays in read-only recovery mode after replay finishes.

### 13.6 Start PostgreSQL

```bash
sudo systemctl start postgresql
```

### 13.7 Validate Recovery

```bash
sudo -u postgres psql -d testpitr -c "SELECT * FROM employees;"
# Expected: 3 rows restored
```

If you see `ERROR: cannot execute INSERT in a read-only transaction`, the database hasn't promoted yet:

```bash
sudo -u postgres psql -c "SELECT pg_promote();"
```

---

## 14. Latest Restore (No PITR)

Use this when you want the most recent backup state with no specific time target:

```bash
sudo systemctl stop postgresql

sudo mv /var/lib/postgresql/14/main /var/lib/postgresql/14/main-old-$(date +%Y%m%d_%H%M%S)
sudo mkdir -p /var/lib/postgresql/14/main
sudo chown postgres:postgres /var/lib/postgresql/14/main
sudo chmod 700 /var/lib/postgresql/14/main

sudo -u postgres pgbackrest --stanza=main restore

sudo systemctl start postgresql
```

---

## 15. Automated Recovery Script

The standard automated recovery script is located at [scripts/auto-recovery.sh](../scripts/auto-recovery.sh). It automates the full PITR process with safety checks.

Usage:


```bash
bash auto-recovery.sh "2026-04-28 09:44:00"
```

Script:

```bash
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

# Step 5: Wait for PostgreSQL to be ready
echo "[5/6] Waiting for PostgreSQL to be ready..."
until sudo -u postgres pg_isready -q; do
  echo "  Still waiting..."
  sleep 2
done

# Step 6: Confirm promotion (fallback if automatic promotion didn't take)
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
```

> ⚠️ Once recovery is verified, delete the `-old` directory to free up disk space.

---

## 16. Troubleshooting

| Issue | Check | Fix |
|---|---|---|
| `stanza-create` fails | `sudo systemctl status postgresql` | Make sure PostgreSQL is running and `pg1-path` matches the actual data directory |
| `archive-push` timeout | `sudo -u postgres pgbackrest --stanza=main check` | Check `/var/log/postgresql/` logs; confirm `archive_command` is correct |
| Permission denied | Check ownership | `sudo chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest` |
| No backups visible | Run info | `sudo -u postgres pgbackrest info` take a new full backup if none exist |
| Restore target not reached | Wrong timestamp or WAL gap | Use an earlier target time; check WAL retention covers the target period |
| PostgreSQL won't start after restore | Check journals | `journalctl -u postgresql -xe` |
| Read-only after restore | Not promoted | `sudo -u postgres psql -c "SELECT pg_promote();"` |
| Restore fails data dir not empty | Data directory exists | Move the directory (see Section 13.4) or use `--delta` |

---

## 17. Real-World Issues & Resolutions

### Issue 1: Restore Fails Because Data Directory Exists

**Error:**
```
ERROR: unable to restore to path ... because it contains files
```

**Why:** pgBackRest won't overwrite an existing data directory. This is a safety measure.

**Fix:**
```bash
sudo systemctl stop postgresql
sudo mv /var/lib/postgresql/14/main /var/lib/postgresql/14/main-old
sudo mkdir -p /var/lib/postgresql/14/main
sudo chown postgres:postgres /var/lib/postgresql/14/main
sudo chmod 700 /var/lib/postgresql/14/main

sudo -u postgres pgbackrest --stanza=main restore \
  --type=time --target="<TARGET_TIME>" --target-action=promote
```

---

### Issue 2: Read-Only Transactions After Restore

**Error:**
```sql
ERROR: cannot execute INSERT in a read-only transaction
```

**Why:** After PITR, PostgreSQL is in recovery (read-only) mode. Using `--target-action=promote` on the restore command should handle this automatically. If it doesn't, promote manually.

**Fix:**
```bash
sudo -u postgres psql -c "SELECT pg_promote();"
# Restart if needed:
sudo systemctl restart postgresql
```

---

## 18. Understanding PITR - Concepts & Strategy

### How PITR Works

```
Base Backup  →  WAL Replay  →  Stop at Target Time  →  Promote
```

1. pgBackRest restores the nearest base backup **before** the target time
2. PostgreSQL replays WAL segments up to the target time
3. Recovery stops; database is promoted to read-write

---

### Example Timeline

```
08:53  →  Base Backup taken
08:54  →  INSERT: employees data loaded
08:55  →  INSERT: more data added
08:56  →  DELETE employees (accidental)
08:57  →  Issue detected
```

Correct recovery target:
```bash
--target="08:55:30"   # Just before the DELETE
```

Getting the target wrong:

| Mistake | Result |
|---|---|
| Target too late (08:56:30) | Includes the DELETE data not recovered |
| Target too early (08:53:30) | Loses valid inserts from 08:54–08:55 |

---

### How to Determine Recovery Target Time

**Method 1: Application / API Logs** *(best option)*
Check your application logs for the last successful transaction before the incident.

**Method 2: PostgreSQL Logs**
```bash
tail -f /var/log/postgresql/postgresql-14-main.log
grep "DELETE" /var/log/postgresql/postgresql-14-main.log
```

**Method 3: Trial Restore** *(for non-production only)*
- Restore to an approximate time
- Check the data
- Adjust and retry if needed
- Always do this on a **separate host**, not production

---

### Recovery Type Reference

| Scenario | Command |
|---|---|
| Restore to specific time | `pgbackrest restore --type=time --target="YYYY-MM-DD HH:MM:SS" --target-action=promote` |
| Restore to latest | `pgbackrest restore` |
| Restore to immediate (end of backup) | `pgbackrest restore --type=immediate` |

---

## 19. Best Practices

| Area | Recommendation |
|---|---|
| Repository | Keep on a **separate disk or server** from PostgreSQL data |
| Restore testing | Test a full restore **monthly** on a separate host |
| Log monitoring | Check backup logs **daily** for errors |
| Retention | Keep at least **7 daily** restore points |
| Time sync | Use NTP PITR timestamps depend on accurate system time |
| WAL files | **Never manually delete WAL files** let pgBackRest manage retention |
| Promotion | Always use `--target-action=promote` on restore commands |
| Crontab | Use `sudo -u postgres crontab -e` not `sudo crontab -u postgres -e` avoids sudo prefix issues |
| Delta restore | Only use `--delta` if you understand the consistency risks |
| Repository verification | Run `pgbackrest verify` weekly to catch corruption early |
| Async archiving | Use `archive-async=y` on write-heavy instances so archiving doesn't block transactions |

---

## 20. Quick Reference Commands

```bash
# Backup
sudo -u postgres pgbackrest --stanza=main backup --type=full
sudo -u postgres pgbackrest --stanza=main backup --type=diff
sudo -u postgres pgbackrest --stanza=main backup --type=incr

# Status & Validation
sudo -u postgres pgbackrest info
sudo -u postgres pgbackrest --stanza=main check
sudo -u postgres pgbackrest --stanza=main verify

# Restore - PITR
sudo -u postgres pgbackrest --stanza=main restore \
  --type=time --target="YYYY-MM-DD HH:MM:SS" --target-action=promote

# Restore - Latest
sudo -u postgres pgbackrest --stanza=main restore

# Promote (if needed manually)
sudo -u postgres psql -c "SELECT pg_promote();"

# PostgreSQL service
sudo systemctl start postgresql
sudo systemctl stop postgresql
sudo systemctl restart postgresql
sudo systemctl status postgresql

# Logs
tail -100 /var/log/pgbackrest/main-backup.log
journalctl -u postgresql -xe
```

---

*All commands assume the `postgres` system user unless prefixed with `sudo`.*

*Companion document: [Understanding PITR](understanding-pitr.md)*
