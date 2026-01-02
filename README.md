# oracle-hot-backup-19c-se2

**Oracle 19c Standard Edition II - Automated Hot Backup Solution using Rsync with Physical Standby (DR) Support**

## Overview

This project provides a production-ready, enterprise-grade solution for automating hot backups of Oracle 19c Standard Edition II databases and replicating them to a physical standby (DR) environment via rsync and archivelog shipping. The solution is designed for 24x7 uptime with minimal RPO/RTO impact.

### Key Features

- **Tablespace-based Hot Backup**: BEGIN/END BACKUP per tablespace with intelligent archivelog application
- **Parallel Rsync**: 4 concurrent workers for fast, resumable data transfer
- **Path Translation**: Flexible filesystem mapping (e.g., `/u05` → `/u15`) with automatic prefix detection
- **Idempotent Execution**: Safe re-runs; completed tablespaces are skipped; failed transfers resume automatically
- **SCN-based Cutoff**: Captures production SCN at backup start and ships only relevant archivelogs
- **Managed Recovery**: Automated archivelog cataloging and managed standby database (MRP) support
- **tmux Orchestration**: Real-time monitoring of 3 parallel processes (hot backup, archivelog shipper, monitor)
- **Log Segregation**: One log file per tablespace plus consolidated error tracking

## Architecture

### Components

1. **hot_backup_ts_to_pamvs0003l.sh**
   - Main hot backup script
   - Executes BEGIN BACKUP → rsync → END BACKUP per tablespace
   - Skips TEMP tablespace and system-managed temporary undo
   - Maintains state files (`.done`) to track completion
   - Translates filesystem paths based on configurable mapping
   - Logs to `logs/ts_<TABLESPACE>.log`

2. **copy_archivelog_to_pamvs0003l.sh**
   - Archivelog shipper with continuous monitoring
   - Captures SCN before hot backup starts
   - Ships only `thread#=1` archivelogs with `FIRST_CHANGE# >= SCN_CUTOFF`
   - Validates files not in use (lsof check) before copying
   - Maintains state file (`last_arch_seq_thread1`) for resumption
   - Logs to `logs/copy_archivelog_to_pamvs0003l.log`

3. **orquestra_dr.sh**
   - Orchestrator script creating tmux session with 3 windows:
     - Window 0: `archivelog` (archive shipper)
     - Window 1: `hot_backup` (hot backup + rsync)
     - Window 2: `monitor` (tail logs, DB status, archivelog progress)
   - Safe re-execution (reuses existing session if available)

## Prerequisites

### On Production Server (SRVORA19PRD)

- Oracle 19c Standard Edition II with `dbprod` database (SID=dbprod)
- SSH access to DR server (PAMVS0003L) as oracle user
- rsync installed and configured
- tmux for parallel execution
- Bash shell (>=4.0)
- sqlplus connectivity to local database

### On Standby Server (PAMVS0003L)

- Matching Oracle 19c SE2 installation (same patch level recommended)
- Destination directories created and owned by oracle user
- Sufficient free space in `/u15/oradata/dbprod/datafile/DBPROD/`
- Archive log destination configured (`/u12/flash_recovery_area/DBPROD/archivelog/`)

## Installation

### 1. Clone the Repository

```bash
cd /home/oracle
git clone https://github.com/AMonteiroDBA/oracle-hot-backup-19c-se2.git
cd oracle-hot-backup-19c-se2

# Or organize in your existing structure
cp -r bin/* /home/oracle/.alkdba/new/bin/
cp -r docs/* /home/oracle/.alkdba/new/docs/
```

### 2. Configure Variables

Edit `orquestra_dr.sh` and adjust:

```bash
# Destination standby
DEST_HOST="pamvs0003l.friosulense.com.br"
DEST_USER="oracle"

# Filesystem mapping (from PROD → DR)
declare -A PATH_MAP=(
  ["/u05"]="/u15"
  # Add more mappings as needed
)

# Parallel workers for rsync
PARALLEL_WORKERS=4

# Archivelog destination on standby
DEST_ARCHLOG_DIR="/u12/flash_recovery_area/DBPROD/archivelog"

# Datafile destination on standby
DEST_DATAFILE_BASE="/u15/oradata/dbprod/datafile/DBPROD"
```

### 3. Prepare Directories

```bash
mkdir -p /home/oracle/.alkdba/new/{bin,log,tmp,docs}
chmod 750 /home/oracle/.alkdba/new/{bin,log,tmp}
```

### 4. Make Scripts Executable

```bash
chmod +x /home/oracle/.alkdba/new/bin/*.sh
```

## Usage

### Quick Start

```bash
# 1. Start the orchestrator (creates tmux session with 3 windows)
/home/oracle/.alkdba/new/bin/orquestra_dr.sh

# 2. Attach to the session to monitor progress
tmux attach -t DR_DBPROD

# 3. Navigate between windows
# Press Ctrl+b then:
#   0 = archivelog window
#   1 = hot_backup window
#   2 = monitor window

# 4. After completion, in standby:
rman target /
CATALOG START WITH '/u12/flash_recovery_area/DBPROD/archivelog/';
RECOVER DATABASE;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;

# 5. For monthly DR drill:
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE OPEN READ ONLY;
# ... run tests ...
SHUTDOWN ABORT;
STARTUP MOUNT;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
```

### State Files and Recovery

If the process fails, you can safely re-execute:

```bash
# Re-run from where it stopped
/home/oracle/.alkdba/new/bin/orquestra_dr.sh
```

State files tracked:
- `${STATE_DIR}/ts_<TABLESPACE>.done` - Completed tablespaces
- `${STATE_DIR}/last_arch_seq_thread1.dbprod` - Last archivelog sequence shipped
- `${STATE_DIR}/scn_cutoff.dbprod` - Backup SCN cutoff (logged in archive script output)

## Directory Structure

```
oracle-hot-backup-19c-se2/
├── README.md                                 (This file)
├── .gitignore                                (Git ignore patterns)
├── bin/
│   ├── hot_backup_ts_to_pamvs0003l.sh       (Main hot backup script)
│   ├── copy_archivelog_to_pamvs0003l.sh     (Archivelog shipper)
│   └── orquestra_dr.sh                      (Orchestrator)
├── docs/
│   ├── DEPLOYMENT.md                        (Deployment guide)
│   ├── TROUBLESHOOTING.md                   (Common issues)
│   └── CONFIGURATION.md                     (Detailed config options)
└── logs/                                    (Generated during execution)
    ├── orquestra_dr.out
    ├── hot_backup_ts_to_pamvs0003l.out
    ├── ts_SYSTEM.log
    ├── ts_SYSAUX.log
    └── ...
```

## Logging and Monitoring

### Real-time Monitoring

```bash
# From the monitor window (Ctrl+b 2):
tail -f /home/oracle/.alkdba/new/log/hot_backup_ts_to_pamvs0003l.out
tail -f /home/oracle/.alkdba/new/log/copy_archivelog_to_pamvs0003l.log

# Or in SQL (on standby after recovery starts):
SELECT THREAD#, SEQUENCE#, APPLIED, COMPLETION_TIME
FROM   V$ARCHIVED_LOG
WHERE  APPLIED = 'YES'
ORDER  BY THREAD#, SEQUENCE#;
```

### Important Logs

- `hot_backup_ts_to_pamvs0003l.out` - High-level backup progress
- `hot_backup_ts_to_pamvs0003l.rsync.log` - Detailed rsync output
- `ts_*.log` - Per-tablespace BEGIN/END BACKUP commands and rsync status
- `copy_archivelog_to_pamvs0003l.log` - Archive shipping progress and SCN tracking

## Known Limitations

1. **TEMP Tablespace**: Not copied (standard for hot backup). Recreate on standby if needed.
2. **OMF Datafiles**: Path translation works for both OMF and non-OMF files.
3. **Large Databases**: With 750+ datafiles, rsync with `--append-verify` is slower than block-level incremental. First run is slowest; subsequent runs (in case of failure) resume quickly.
4. **Network Dependency**: Solution is SSH/rsync based; not suitable for high-latency/low-bandwidth links without tuning rsync compression (`-z`).

## Security Considerations

- SSH keys must be configured for passwordless oracle-to-oracle access.
- Ensure rsync over SSH with appropriate firewall rules.
- Logs contain filesystem paths; restrict log access to authorized DBAs.
- Consider enabling audit on standby database operations.

## Troubleshooting

See `docs/TROUBLESHOOTING.md` for:
- ORA-01274: Cannot add data file
- rsync timeouts
- Archivelog gaps
- SCN advancement issues

## Support and Contributing

This is an open-source project. For issues, questions, or improvements:

1. Check `docs/TROUBLESHOOTING.md` first
2. Open an issue with:
   - Oracle version and patch level
   - Number of datafiles / tablespaces
   - Error messages from logs
   - Database size and available bandwidth
3. Submit pull requests for enhancements

## License

MIT License - See LICENSE file (if provided)

## Author

A. Monteiro DBA  
DBA Consultant specializing in Oracle backup/recovery and disaster recovery solutions.

## References

- Oracle 19c Documentation: https://docs.oracle.com/en/database/oracle/oracle-database/19/
- rsync Manual: https://linux.die.net/man/1/rsync
- Data Guard Concepts: https://docs.oracle.com/en/database/oracle/oracle-database/19/dgcon/
