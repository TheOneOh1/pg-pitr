# pgBackRest PITR — Understanding & Standard Operating Procedure

**Applies to:** PostgreSQL 14+ on Ubuntu 24.04
**Audience:** DevOps Engineers, Engineering Managers
**Scope:** Single-instance PostgreSQL (applicable to other DB instances with minor adjustments)
**Version:** 1.0 | **Last Updated:** April 2026

---

## Table of Contents

**Part A — Understanding**
1. [What is PITR?](#1-what-is-pitr)
2. [Core Terminology](#2-core-terminology)
3. [How the Components Relate](#3-how-the-components-relate)
4. [The PITR Workflow — End to End](#4-the-pitr-workflow--end-to-end)
5. [Recovery Target Settings](#5-recovery-target-settings)
6. [RPO and RTO](#6-rpo-and-rto)

**Part B — Standard Operating Procedure**

7. [Backup Policy](#7-backup-policy)
8. [Retention Policy](#8-retention-policy)
9. [WAL Archive Management](#9-wal-archive-management)
10. [Recovery Procedure — PITR to Specific Time](#10-recovery-procedure--pitr-to-specific-time)
11. [Recovery Procedure — Latest Restore (No PITR)](#11-recovery-procedure--latest-restore-no-pitr)
12. [Post-Recovery Validation](#12-post-recovery-validation)
13. [Routine Operational Checks](#13-routine-operational-checks)
14. [Future Enhancements](#14-future-enhancements)

---

---

# PART A — UNDERSTANDING

---

## 1. What is PITR?

**Point-in-Time Recovery (PITR)** lets you restore a PostgreSQL database to any specific moment in its history. Not just the last backup — any second within your retention window.

You need this when:
- Someone runs an accidental `DELETE` or `DROP TABLE`
- A bad data migration goes through
- Corruption shows up at a known timestamp
- An app bug writes bad data starting from a specific point

PITR requires two things working together: **base backups** and **continuous WAL archiving**. Neither works alone — you need both.

---

## 2. Core Terminology

| Term | What It Means |
|---|---|
| **Base Backup** | A full snapshot of the PostgreSQL data directory at a point in time. Starting point for any restore. |
| **WAL (Write-Ahead Log)** | A sequential log of every change made to the database. PostgreSQL writes here first, before applying to data files. |
| **WAL Archiving** | Continuously copying WAL segments from PostgreSQL to the pgBackRest repository as they complete. |
| **WAL Segment** | A 16 MB file (default) holding a chunk of WAL data. When full, it gets archived and a new one starts. |
| **Stanza** | pgBackRest's name for a backup configuration tied to a specific PostgreSQL instance. Ours is called `main`. |
| **Repository** | Where pgBackRest stores all backup data and archived WAL segments. |
| **Full Backup** | Complete copy of all PostgreSQL data files. Self-contained — can restore on its own. |
| **Differential Backup** | Everything that changed since the last full backup. Needs the full to restore. |
| **Incremental Backup** | Everything that changed since the last backup of any type. Needs the full + all prior backups in the chain to restore. |
| **PITR** | Point-in-Time Recovery — restoring to a specific timestamp using a base backup + WAL replay. |
| **Recovery Target** | The timestamp (or transaction ID) where WAL replay stops during a PITR restore. |
| **Promotion** | Taking a PostgreSQL instance out of read-only recovery mode and making it read-write. |
| **`pg_promote()`** | PostgreSQL function that promotes a recovering instance to primary (read-write). |
| **`archive_command`** | Shell command PostgreSQL calls to archive each WAL segment to the pgBackRest repository. |
| **`archive_timeout`** | Forces a WAL segment switch after N seconds of inactivity. Keeps WAL archiving regular even on quiet instances. |
| **`wal_level`** | Controls how much information goes into WAL. Must be `replica` or higher for archiving. |
| **`start-fast`** | pgBackRest option that forces an immediate checkpoint at backup start. Backup begins from the latest consistent state instead of waiting for the next scheduled checkpoint. |
| **`--target-action=promote`** | Tells PostgreSQL to automatically promote to read-write after reaching the recovery target. Required on PostgreSQL 12+. |
| **`--delta`** | A restore mode that only replaces changed files instead of requiring an empty data directory. Use with caution. |

---

## 3. How the Components Relate

Know how these pieces connect before you run any recovery.

```
┌─────────────────────────────────────────────────────────────┐
│                     BACKUP SIDE                             │
│                                                             │
│  PostgreSQL DB                                              │
│       │                                                     │
│       ├──► WAL Segments ──► archive_command ──► pgBackRest  │
│       │         (continuous, every 60s minimum)   Repository│
│       │                                               │     │
│       └──► Full / Diff / Incr Backup ─────────────────►     │
│                  (scheduled via cron)                       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     RESTORE SIDE                            │
│                                                             │
│  pgBackRest Repository                                      │
│       │                                                     │
│       ├──► Nearest Base Backup before target time           │
│       │         (restored to data directory)                │
│       │                                                     │
│       └──► WAL Segments replayed in sequence                │
│                 until target time is reached                │
│                          │                                  │
│                          └──► PostgreSQL promoted ──► Live  │
└─────────────────────────────────────────────────────────────┘
```

**Key rules:**

- A restore always starts from a **base backup taken before the target time**. No base backup before your target = no recovery.
- WAL segments fill the gap between the base backup time and the recovery target. If any segment in that range is missing, recovery stops at the gap.
- Differentials and incrementals save backup time and storage, but they don't affect PITR granularity. WAL archiving is what gives you second-level precision.
- The repository must keep WAL segments for the **entire retention window**, not just the backup files.

---

## 4. The PITR Workflow — End to End

The full lifecycle from normal operations to recovery.

### 4.1 Normal Operation (Ongoing)

```
Day 0, 02:00  →  Full backup taken
Day 0, 08:00  →  Differential backup taken
Day 0, 09:00  →  Incremental backup taken
Day 0, 09:00–10:00  →  WAL archived every 60s (continuous)
```

Every transaction is captured in WAL. pgBackRest archives each WAL segment as it completes. This creates an unbroken record of all changes.

### 4.2 Incident Occurs

```
Day 0, 10:34:52  →  Accidental DELETE executed
Day 0, 10:37:00  →  Issue detected
```

### 4.3 Recovery Decision

The engineer figures out:
1. **What** was lost or corrupted
2. **When** it happened (from app logs, PostgreSQL logs, or monitoring)
3. **Target time** = just before the incident (`10:34:30`)

### 4.4 Recovery Execution

```
pgBackRest selects: Full backup from Day 0 02:00
  + Differential from 08:00
  + Incremental from 09:00
  + WAL replay from 09:00 → 10:34:30

Result: Database state as of 10:34:30 — the DELETE never happened
```

### 4.5 Promotion

PostgreSQL exits recovery mode and becomes read-write. Normal operations resume.

---

## 5. Recovery Target Settings

Two flags control where and how recovery stops during a PITR restore:

### `--type`

| Value | What It Does |
|---|---|
| `time` | Stop replay at a specific timestamp. Most common. |
| `immediate` | Stop as soon as the backup is consistent (end of backup, no WAL replay). |
| *(omitted)* | Replay all available WAL — restore to the latest possible state. |

### `--target`

The timestamp to stop at. Format: `"YYYY-MM-DD HH:MM:SS"`.

Example: `--target="2026-04-28 10:34:30"`

> ⚠️ The target time is relative to your server's system clock. Make sure NTP is active and consistent. Even a few seconds of clock drift can put your target in the wrong position relative to WAL events.

### `--target-action`

| Value | What Happens |
|---|---|
| `promote` | Automatically promote to read-write after reaching target. **Always use this.** |
| `pause` | Stop at target but stay in read-only recovery. You'll need to run `pg_promote()` manually. |
| `shutdown` | Stop PostgreSQL after reaching target. Requires manual restart + promotion. |

**Always use `--target-action=promote`** unless you specifically need to inspect the data in read-only state before committing to the recovery point.

### How pgBackRest picks the base backup

pgBackRest automatically picks the most recent base backup that started **before** the target time. You don't need to specify which backup to use.

If the target time is before all available backups, the restore will fail. Check coverage with:

```bash
sudo -u postgres pgbackrest info
```

---

## 6. RPO and RTO

| Metric | What It Means | In This Setup |
|---|---|---|
| **RPO** (Recovery Point Objective) | Maximum acceptable data loss, measured in time | ~1 hour (with hourly incrementals + continuous WAL) |
| **RTO** (Recovery Time Objective) | Maximum acceptable time to restore service | 30–90 minutes depending on DB size and backup chain depth |

**To reduce RPO:** Lower `archive_timeout` (e.g. to `30`). This only matters if the server crashes before a WAL segment fills — normally WAL is archived within seconds of a commit.

**To reduce RTO:** Take more frequent full backups. This shortens the WAL replay window. For large databases, going from 24-hour to 12-hour fulls can cut RTO noticeably.

---

---

# PART B — STANDARD OPERATING PROCEDURE

---

## 7. Backup Policy

### 7.1 Backup Schedule

| Backup Type | Schedule | Time | Purpose |
|---|---|---|---|
| Full | Weekly (Sunday) | 01:00 | Base restore point; resets diff/incr chain |
| Differential | Daily (Mon–Sat) | 02:00 | Daily changes from last full |
| Incremental | Hourly | Every hour | Closes RPO gap between differentials |
| WAL Archiving | Continuous | Every 60s minimum | Enables PITR to any second |
| Integrity Verify | Weekly (Sunday) | 03:30 | Catches repository corruption early |

> **Note on existing policy (Full: 4 weeks, Diff: 7 days):** That's the retention policy. The schedule above shifts full backups to weekly (not daily) to keep storage costs reasonable, and adds hourly incrementals for tighter RPO. Daily fulls work too — just adjust the cron.

### 7.2 Crontab Configuration

Run as the `postgres` user:

```bash
sudo -u postgres crontab -e
```

```cron
# Full backup - weekly on Sunday at 01:00
0 1 * * 0 pgbackrest --stanza=main backup --type=full

# Differential backup - daily Mon–Sat at 02:00
0 2 * * 1-6 pgbackrest --stanza=main backup --type=diff

# Incremental backup - hourly (skips hours covered by full/diff)
0 3-23 * * * pgbackrest --stanza=main backup --type=incr
0 0 * * 1-6 pgbackrest --stanza=main backup --type=incr

# Weekly integrity verification - Sunday at 03:30
30 3 * * 0 pgbackrest --stanza=main verify
```

### 7.3 Storage Estimate

| Component | Estimate |
|---|---|
| Full backup | ~1x DB size (compressed ~30–50% with zst) |
| Differential | ~10–30% of DB size per day |
| Incremental | ~1–5% of DB size per hour |
| WAL archive | ~1–5 GB/day for moderate write workloads |
| **Total (4-week window)** | **Plan for 5–8x DB size on the repository disk** |

---

## 8. Retention Policy

### 8.1 Configured Retention

| Type | Retention | Config Key |
|---|---|---|
| Full backups | 4 weeks (4 sets) | `repo1-retention-full=4` |
| Differential backups | 7 days | `repo1-retention-diff=7` |
| Incremental backups | Managed automatically within diff chain | — |
| WAL archives | Kept as long as the oldest full backup needs them | Automatic |

> pgBackRest automatically expires WAL archives that no retained backup needs. WAL retention isn't configured separately — it follows backup retention.

### 8.2 How Retention Works

- When a full backup expires (after 4 weeks), all differentials, incrementals, and WAL segments that were **only** needed by that full are also expired.
- Differentials older than 7 days are expired, along with any incrementals that only depend on those differentials.
- There will always be at least one restorable full backup available.

### 8.3 Retention Trade-offs

| If You Reduce Retention | Impact |
|---|---|
| Fewer full backups (<4) | Less historical coverage; smaller storage |
| Fewer diff days (<7) | Faster restore (shorter chain) but less recovery options |
| No incrementals | Higher RPO (up to 6 hours between diffs) |

---

## 9. WAL Archive Management

### 9.1 How WAL Archiving Works

PostgreSQL writes every transaction to WAL segments (16 MB files by default). When a segment fills — or `archive_timeout` is reached — `archive_command` runs, and pgBackRest copies the segment to the repository.

```
Transaction commits
  → Written to WAL segment
  → Segment fills (or archive_timeout fires)
  → archive_command called
  → pgBackRest copies segment to repository
  → Segment marked as archived
```

### 9.2 Key Settings

> 💡 **Standalone Configuration Templates:** You can view the fully documented configuration files under [configs/pgbackrest.example.conf](../configs/pgbackrest.example.conf) and [configs/postgresql.example.conf](../configs/postgresql.example.conf).

| Setting | Value | Why |

|---|---|---|
| `archive_mode` | `on` | Enables WAL archiving |
| `archive_command` | `pgbackrest --stanza=main archive-push %p` | Hands each WAL segment to pgBackRest |
| `archive_timeout` | `60` | Forces archiving every 60 seconds even on quiet instances |
| `wal_level` | `replica` | Minimum level required for archiving |
| `archive-async` | `y` | Archives WAL in the background; prevents blocking transactions |

### 9.3 Rules

- **Never manually delete WAL files** from the PostgreSQL data directory (`pg_wal/`) or the repository. pgBackRest handles this.
- **Never run** `pg_resetwal` — it breaks WAL continuity and kills PITR.
- If the archive command fails, PostgreSQL keeps retrying. A sustained failure causes WAL segments to pile up in `pg_wal/`, which will eventually fill the disk. Monitor this.
- Check archiving daily:

```bash
sudo -u postgres pgbackrest --stanza=main check
```

---

## 10. Recovery Procedure — PITR to Specific Time

**When to use this:** You need to restore the database to a specific point in time, usually to undo an accidental operation.

---

### Pre-Recovery Checklist

Before doing anything, confirm:

- [ ] You know the **target recovery time** (just before the incident)
- [ ] The target time is within your backup retention window (`pgbackrest info`)
- [ ] You've told relevant stakeholders the database will be offline
- [ ] You have enough disk space to move the old data directory

---

### Step 1 — Identify Target Recovery Time

**From application logs:**
```bash
grep -i "error\|delete\|drop" /path/to/app.log | tail -50
```

**From PostgreSQL logs:**
```bash
grep -i "DELETE\|DROP\|TRUNCATE" /var/log/postgresql/postgresql-14-main.log | tail -50
```

Set your target to **30–60 seconds before** the first sign of the problem.

Example: If the accidental DELETE shows up at `10:34:52`, use `--target="2026-04-28 10:34:30"`.

---

### Step 2 — Verify Backup Coverage

```bash
sudo -u postgres pgbackrest info
```

Confirm a backup exists **before** your target time. The output shows backup start and stop times. If nothing predates the target, PITR to that point won't work.

---

### Step 3 — Stop PostgreSQL

```bash
sudo systemctl stop postgresql
```

Confirm it's stopped:

```bash
sudo systemctl status postgresql
```

---

### Step 4 — Move Existing Data Directory

pgBackRest won't overwrite a non-empty data directory. Move it first.

```bash
sudo mv /var/lib/postgresql/14/main \
        /var/lib/postgresql/14/main-old-$(date +%Y%m%d_%H%M%S)

sudo mkdir -p /var/lib/postgresql/14/main
sudo chown postgres:postgres /var/lib/postgresql/14/main
sudo chmod 700 /var/lib/postgresql/14/main
```

---

### Step 5 — Execute Restore

```bash
sudo -u postgres pgbackrest --stanza=main restore \
  --type=time \
  --target="YYYY-MM-DD HH:MM:SS" \
  --target-action=promote
```

Replace `YYYY-MM-DD HH:MM:SS` with your actual target time.

This command:
1. Picks the nearest base backup before the target time
2. Restores it to the data directory
3. Replays WAL up to the target time
4. Promotes the database to read-write

---

### Step 6 — Start PostgreSQL

```bash
sudo systemctl start postgresql
```

Wait for it to be ready:

```bash
until sudo -u postgres pg_isready -q; do
  echo "Waiting for PostgreSQL..."
  sleep 2
done
echo "PostgreSQL is ready."
```

---

### Step 7 — Validate Recovery

See [Section 12 — Post-Recovery Validation](#12-post-recovery-validation).

---

### Step 8 — Cleanup

Once you've validated and the database is confirmed healthy:

```bash
# Remove the old data directory to free disk space
sudo rm -rf /var/lib/postgresql/14/main-old-*
```

> ⚠️ Don't delete the old directory until validation is fully done. Keep it for at least 24 hours as a safety net.

---

### Automated Recovery Script

For repeatable, hands-off execution, use the standard [scripts/auto-recovery.sh](../scripts/auto-recovery.sh) script:

```bash
bash scripts/auto-recovery.sh "2026-04-28 10:34:30"
```


---

## 11. Recovery Procedure — Latest Restore (No PITR)

**When to use this:** The database is corrupted or gone and you need to restore to the most recent backup state. No specific time target.

---

### Step 1 — Stop PostgreSQL

```bash
sudo systemctl stop postgresql
```

---

### Step 2 — Move Existing Data Directory

```bash
sudo mv /var/lib/postgresql/14/main \
        /var/lib/postgresql/14/main-old-$(date +%Y%m%d_%H%M%S)

sudo mkdir -p /var/lib/postgresql/14/main
sudo chown postgres:postgres /var/lib/postgresql/14/main
sudo chmod 700 /var/lib/postgresql/14/main
```

---

### Step 3 — Execute Restore

```bash
sudo -u postgres pgbackrest --stanza=main restore
```

This restores the most recent backup and replays all available WAL — getting as close to the present as possible.

---

### Step 4 — Start PostgreSQL

```bash
sudo systemctl start postgresql
```

---

### Step 5 — Validate Recovery

See [Section 12 — Post-Recovery Validation](#12-post-recovery-validation).

---

## 12. Post-Recovery Validation

Run these checks after **every** recovery, regardless of type.

### 12.1 Confirm Database is Read-Write

```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
```

Expected: `f` (false — not in recovery).

If you get `t`, the database is still in read-only mode. Promote manually:

```bash
sudo -u postgres psql -c "SELECT pg_promote();"
```

---

### 12.2 Confirm PostgreSQL is Accepting Connections

```bash
sudo -u postgres pg_isready
```

Expected: `/var/run/postgresql:5432 - accepting connections`

---

### 12.3 Check Database List

```bash
sudo -u postgres psql -c "\l"
```

Confirm your expected databases are there.

---

### 12.4 Spot-Check Critical Tables

Connect to the target database and check row counts on key tables:

```bash
sudo -u postgres psql -d <your_database>
```

```sql
SELECT schemaname, tablename, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 20;
```

Compare against known pre-incident counts if you have them.

---

### 12.5 Verify Recovery Timestamp

Confirm the database recovered to the right point:

```sql
SELECT now();
```

Cross-reference with the backup timeline from `pgbackrest info` to make sure the recovery target was reached.

---

### 12.6 Check PostgreSQL Logs for Errors

```bash
tail -100 /var/log/postgresql/postgresql-14-main.log
```

Look for any `ERROR` or `FATAL` entries after startup.

---

### 12.7 Confirm WAL Archiving Resumed

After recovery, WAL archiving should resume on its own. Confirm:

```bash
sudo -u postgres pgbackrest --stanza=main check
```

Expected: `check command end: completed successfully`

---

### 12.8 Validation Sign-off Checklist

| Check | Expected Result | Pass / Fail |
|---|---|---|
| `pg_is_in_recovery()` returns `f` | Database is read-write | |
| `pg_isready` succeeds | Accepting connections | |
| `\l` shows expected databases | All databases present | |
| Critical table row counts look right | Data is intact | |
| No `ERROR` or `FATAL` in PostgreSQL logs | Clean startup | |
| `pgbackrest check` passes | WAL archiving resumed | |

> Don't hand the database back to application teams until everything on this list passes.

---

## 13. Routine Operational Checks

### 13.1 Daily

| Task | Command |
|---|---|
| Confirm last backup completed | `sudo -u postgres pgbackrest info` |
| Check for archiving errors | `sudo -u postgres pgbackrest --stanza=main check` |
| Scan backup logs | `tail -50 /var/log/pgbackrest/main-backup.log` |
| Confirm disk space is sufficient | `df -h /var/lib/pgbackrest` |

**Alert thresholds:**
- Disk usage on repository > 80% → escalate immediately
- Last backup older than 26 hours → investigate
- Any `ERROR` in pgBackRest logs → investigate same day

### 13.2 Weekly

| Task | Command |
|---|---|
| Run integrity verification | `sudo -u postgres pgbackrest --stanza=main verify` |
| Review retention — confirm old backups expired | `sudo -u postgres pgbackrest info` |
| Check PostgreSQL log for archiving warnings | `grep -i "archive" /var/log/postgresql/postgresql-14-main.log` |

### 13.3 Monthly

| Task | Notes |
|---|---|
| Full restore drill | Restore to a separate host (not production). Run the Section 12 checks. Write down how long it took — that's your RTO baseline. |
| Review backup storage growth | Adjust retention or plan for more disk if needed |
| Review and update this SOP | Add any new issues or process changes |

---

## 14. Future Enhancements

This SOP covers a single-instance, local-repository setup. Here's what to consider as things scale.

### 14.1 Remote Repository (Separate Server or Cloud Storage)

Keeping backups on the same host as PostgreSQL is a single point of failure. If the VM dies, or if the disk gets corrupted, you lose both the database and the backup.

**Next step:** Add a second repository (`repo2`) on a separate VM or object storage (S3, MinIO, etc.):

```ini
# In /etc/pgbackrest.conf
repo2-type=s3
repo2-path=/pgbackrest
repo2-s3-bucket=your-bucket-name
repo2-s3-region=ap-south-1
repo2-s3-endpoint=s3.amazonaws.com
repo2-retention-full=4
```

pgBackRest can write to multiple repositories at the same time — backups go to both local and remote with no extra work.

### 14.2 Separate Backup Disk (Do This First)

If remote storage isn't an option yet, at least move the repository to a **separate physical disk** from the PostgreSQL data directory. Protects against single-disk failure:

```bash
# Mount second disk at /mnt/backups
# Update repo1-path in /etc/pgbackrest.conf to /mnt/backups/pgbackrest
```

### 14.3 Standby / Replica Setup

For high-availability, adding a streaming replica gives you:
- Backups taken from the standby (no I/O hit on primary)
- Automatic failover if the primary goes down

pgBackRest supports this with `backup-standby=y`.

### 14.4 Alerting Integration

Hook pgBackRest log output into your monitoring stack (Grafana, PagerDuty, Slack, etc.) to alert on:
- Backup failures
- Archive failures (WAL backlog growing)
- Repository disk usage thresholds

---

---

*This document is maintained by the DevOps team. Review it after any recovery event or infrastructure change. All commands assume the `postgres` system user unless prefixed with `sudo`.*

*Companion document: [Setup Guide](setup-guide.md)*
