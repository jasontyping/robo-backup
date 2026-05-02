# Robo-Backup

A simple Windows batch script for backing up folders to a network share (NAS) using `robocopy`. No dependencies, no credential storage -- just a single `.bat` file and an optional config.

## Features

- **Robocopy-powered** -- incremental, accumulating backups that skip older files (`/XO`)
- **Configurable** -- set source, destination, username, and log directory in a `backup.cfg` file
- **CLI overrides** -- pass up to 4 positional arguments to override config values
- **Simulate mode** -- use `/L` to preview what would be copied without making any changes
- **Secure** -- password is always prompted interactively and never written to disk or Credential Manager
- **Auto-cleanup** -- network connections are always torn down after the run, regardless of success or failure
- **Verbose logging** -- every run produces a timestamped log with full robocopy output (console + file)
- **Pure batch** -- no PowerShell, VBScript, or external dependencies

## Quick Start

1. Place `simple-backup.bat` in a folder of your choice.
2. Create a `backup.cfg` file in the same folder:

   ```ini
   SOURCE=C:\Users\John\Documents\Important
   DESTINATION=\\192.168.1.50\backup\john_docs
   USERNAME=nas_user
   LOG_DIR=C:\Users\John\BackupLogs
   ```

3. Run the script:

   ```cmd
   simple-backup.bat
   ```

4. Enter your NAS password when prompted.

That's it. The backup runs, logs are written, and the network connection is cleaned up automatically.

## Usage

### Config File Only

```cmd
simple-backup.bat
```

Reads all settings from `backup.cfg` and prompts only for the password.

### Override via Command Line

```cmd
simple-backup.bat [source] [destination] [username] [log_dir]
```

Example:

```cmd
simple-backup.bat D:\Photos \\NAS\PhotosBackup nasadmin C:\TempLogs
```

Positional arguments override `backup.cfg` values. Any values not provided via CLI fall back to the config file, then to interactive prompts.

### Simulate Mode

```cmd
simple-backup.bat /L
```

Or with arguments:

```cmd
simple-backup.bat /L D:\Photos \\NAS\PhotosBackup nasadmin
```

Runs everything normally but passes `/L` to robocopy, so it only lists files that *would* be copied without actually copying anything.

### No Config, No Arguments

```cmd
simple-backup.bat
```

Prompts interactively for source, destination, username, and password. Logs to the current directory.

## Configuration

Create a file named `backup.cfg` in the same directory as the script.

| Key | Description | Required |
|---|---|---|
| `SOURCE` | Path to the source folder to back up | Yes (unless provided via CLI) |
| `DESTINATION` | UNC network path to the backup destination (e.g., `\\NAS\Backups\MyFolder`) | Yes (unless provided via CLI) |
| `USERNAME` | NAS username for authentication | No |
| `LOG_DIR` | Directory where log files are written. Defaults to current directory if omitted | No |

**Rules:**

- Lines starting with `;`, `#`, or `//` are treated as comments
- Blank lines are ignored
- Values may contain spaces and `=` characters
- The script works fine if `backup.cfg` is missing -- it will fall back to CLI args or prompts

## Value Resolution Priority

1. Command-line argument (highest)
2. `backup.cfg` value
3. Interactive prompt (lowest)

The `PASSWORD` is **never** read from a file or CLI argument. It is always prompted interactively.

## Robocopy Flags

The script uses the following robocopy options:

| Flag | Purpose |
|---|---|
| `/E` | Copy subdirectories, including empty ones |
| `/R:5` | Retry failed copies 5 times |
| `/W:10` | Wait 10 seconds between retries |
| `/XO` | Exclude older files (skip if destination is newer) |
| `/NP` | No progress percentage (cleaner output) |
| `/TEE` | Output to both console and log file |
| `/V` | Verbose file listing (includes skipped files) |
| `/LOG+` | Append output to log file |

**Not used:** `/MIR`, `/PURGE`, `/MOV`, `/MOVE` -- this script never deletes or moves source files.

## Logging

Each run produces a log file named `backup_YYYYMMDD_HHMMSS.log` in the configured `LOG_DIR`. The log contains the complete robocopy output, including:

- Source and destination paths
- Files copied and skipped (with reasons)
- Retry attempts
- Final summary table

The same output is displayed in the console in real-time.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success (no errors; robocopy exit code < 8) |
| `1` | Backup completed with errors (robocopy exit code >= 8) |
| Other | `net use` authentication failure (passes through the Windows error code) |

Note: robocopy uses a bitmask for exit codes. Codes 0-7 indicate various levels of success (no changes, files copied, extra files detected, etc.). Codes >= 8 indicate actual errors.

## Requirements

- Windows (any version with `robocopy` and `net use`)
- Access to a network share (SMB/CIFS)
- No third-party software

## License

MIT
