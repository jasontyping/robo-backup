# Specification: Windows Batch Backup Script with Robocopy

## 1. Overview

A single Windows batch script (`backup.bat` or `backup.cmd`) that copies a source folder (including all subdirectories) to a network backup destination using `robocopy`. The script temporarily authenticates to the network destination using supplied credentials, performs a non-destructive, accumulating file copy, and then disconnects from the network share. No credentials are persisted in the script, command history, or Windows Credential Manager.

## 2. Goals

- Provide a simple, manual backup mechanism to a local NAS.
- Ensure credentials are never saved to disk or command history.
- Allow paths and optional defaults to be configured via an external file.
- Allow all settings to be overridden via command-line arguments.
- Guarantee the network connection is always torn down after the operation, regardless of success or failure.
- Log all activity, including verbose details of files skipped because they are older than the destination.

## 3. Configuration System

### 3.1 Config File (`backup.cfg`)

The script looks for a file named `backup.cfg` in the **same directory as the script itself**. The format is a flat `KEY=value` text file (one per line).

**Supported Keys:**

| Key | Description | Required |
|---|---|---|
| `SOURCE` | Absolute or relative path to the source folder to back up. | Yes (unless provided via CLI) |
| `DESTINATION` | UNC network path to the backup destination (e.g., `\\NAS\Backups\MyFolder`). | Yes (unless provided via CLI) |
| `USERNAME` | NAS username for authentication. | No |
| `LOG_DIR` | Directory where log files will be written. If omitted, defaults to the script's current directory. | No |

**Example `backup.cfg`:**
```ini
SOURCE=C:\Users\John\Documents\Important
DESTINATION=\\192.168.1.50\backup\john_docs
USERNAME=nas_user
LOG_DIR=C:\Users\John\BackupLogs
```

### 3.2 Resolution Priority

The script resolves each setting using the following priority (highest to lowest):

1. **Command-line argument** (if provided).
2. **`backup.cfg` value** (if file exists and key is present).
3. **Interactive prompt** (if value is still missing).

**Rules:**
- The script **must not** abort if `backup.cfg` is missing. It should simply fall back to CLI args or prompts.
- If `USERNAME` is present in the config, the script uses it and does **not** prompt for it unless overridden by a CLI arg.
- If `USERNAME` is missing everywhere, the script prompts the user to type it.
- The `PASSWORD` is **never** read from a file or CLI arg. It is **always** prompted for interactively at runtime.

## 4. Command-Line Interface

The script accepts up to **4 optional positional arguments** and an optional **simulate flag** (`/L`):

```cmd
backup.bat [/L] [source] [destination] [username] [log_dir]
```

**Argument Mapping:**

| Position | Overrides Config Key | Example |
|---|---|---|
| 1 | `SOURCE` | `C:\MyData` |
| 2 | `DESTINATION` | `\\NAS\Share\Backup` |
| 3 | `USERNAME` | `admin` |
| 4 | `LOG_DIR` | `D:\Logs` |

**Simulate Flag:**
- If any argument (case-insensitive) is `/L`, the script runs in **simulate mode**.
- The `/L` flag does **not** consume a positional argument slot.
- In simulate mode, the script performs all normal steps (reads config, connects to the network share, prompts for credentials, creates logs) but passes `/L` to `robocopy`, causing it to **only list files that would be copied** without actually copying anything.

If fewer than 4 positional arguments are provided, only the provided ones override the config/prompts.

## 5. Execution Flow (Algorithm)

The script must execute the following steps in exact order:

### Step 1: Environment Setup
- Use `setlocal EnableDelayedExpansion` to ensure variable expansion behaves correctly inside blocks.
- Determine the script's own directory (e.g., `%~dp0`) to locate `backup.cfg`.
- Scan all command-line arguments for `/L` (case-insensitive). If found, set an internal `SIMULATE` flag to `1` and treat that argument as the simulate switch rather than a positional value.

### Step 2: Read Configuration
- If `backup.cfg` exists in `%~dp0`, parse it line-by-line.
- For each supported key, set an internal variable only if the CLI argument for that key was not provided.
- **Parsing rules for `backup.cfg`:**
  - Ignore blank lines.
  - Ignore lines starting with `;` or `#` or `//` (comments).
  - Split on the **first** `=` character only. The value may contain `=` characters.
  - Trim **leading and trailing whitespace** from both key and value.
  - Do not treat quotes specially; if the value is `C:\My Folder`, the spaces are part of the path.

### Step 3: Resolve Missing Values
- If `SOURCE` is still undefined, prompt the user: `Enter source folder path:` and read input.
- If `DESTINATION` is still undefined, prompt the user: `Enter destination network path:` and read input.
- If `USERNAME` is still undefined, prompt the user: `Enter NAS username:` and read input.
- If `LOG_DIR` is still undefined, default it to the **current working directory** (`.`) where the script was invoked.

### Step 4: Prompt for Password
- Prompt the user: `Enter NAS password:` and read input into a `PASSWORD` variable.
- **Important:** The password input is **visible** on the screen (standard batch `set /p` behavior). This keeps the script pure batch and avoids PowerShell dependencies.

### Step 5: Generate Log Filename
- Create a timestamp string in the format: `YYYYMMDD_HHMMSS` using `%date%` and `%time%` parsing.
- Set `LOG_FILE=%LOG_DIR%\backup_%TIMESTAMP%.log`.
- Ensure `LOG_DIR` exists before the robocopy command. If it does not, create it using `mkdir` (which may need to handle spaces in the path).

### Step 6: Authenticate to Network Share
- Execute: `net use "%DESTINATION%" /user:%USERNAME% %PASSWORD%`
  - **Note:** The destination passed to `net use` should be the **root UNC server or share**, not necessarily the full subfolder path. For example, if `DESTINATION=\\NAS\Backups\SubFolder`, the `net use` command should target `\\NAS\Backups` with the folder path being used in robocopy. If the exact destination is a share root, `net use` can use it directly.
  - **Simplification:** The simplest reliable implementation is to map the full `DESTINATION` path: `net use "%DESTINATION%" /user:%USERNAME% %PASSWORD%`. This works if the user has permissions on that path.
- Check `%ERRORLEVEL%` immediately after `net use`.
  - If **non-zero**, print `ERROR: Failed to authenticate to network share.` to the console, and exit the script with `%ERRORLEVEL%`. **Do not** proceed to Step 7 or 9.
  - If **zero**, proceed.

### Step 7: Execute Robocopy
- Build the robocopy command using the base flags listed below. If `SIMULATE` is active, append `/L` to the command line.
- Execute the `robocopy` command:
  ```cmd
  robocopy "%SOURCE%" "%DESTINATION%" /E /R:5 /W:10 /XO /NP /TEE /V /LOG+:"%LOG_FILE%" %SIMULATE_FLAG%
  ```
  Where `%SIMULATE_FLAG%` is either `/L` (if simulate mode is enabled) or empty.
- **Parameter breakdown (must be used exactly):**
  - `/E` -- Copy subdirectories, including **empty** ones.
  - `/R:5` -- Retry failed copies **5 times**.
  - `/W:10` -- Wait **10 seconds** between retries.
  - `/XO` -- **eXclude Older** destination files. If a destination file exists and is **newer** than the source, it is skipped. If a source file is newer, it overwrites.
  - `/NP` -- **No Progress** percentage display. Keeps console/log output clean.
  - `/TEE` -- Output to **both** the console window **and** the log file simultaneously.
  - `/V` -- **Verbose**. Produces a verbose listing showing skipped files, including those skipped because they are older (`/XO`). This satisfies the requirement to log individual filenames of skipped older files.
  - `/LOG+:"path"` -- Append all output to the specified log file. The `+` means append; if the file does not exist, it is created.
  - `/L` (conditional) -- **List only** (simulate). When the script's simulate flag is active, robocopy lists every file that would be copied without performing any actual file operations.
- After `robocopy` completes, capture its exit code into a variable. Robocopy uses exit codes as a bitmask (e.g., `0` = no changes, `1` = files copied, `2` = extra files, `4` = mismatches, `8` = failed copies, `16` = serious error). Any exit code **>= 8** indicates an error.

### Step 8: Log Summary of Older Files
- Robocopy's `/V` flag, combined with `/XO`, naturally lists every file skipped because the destination is newer.
- Additionally, robocopy prints a summary table at the end of the run. This table includes columns for `Extras`, `Older`, `Newer`, `Changed`. The `Older` count will show how many files were skipped because the destination was newer. This table is included in both the console (via `/TEE`) and the log file (via `/LOG+`).

### Step 9: Disconnect from Network Share
- **This step must execute unconditionally**, regardless of whether `net use` or `robocopy` succeeded or failed. The only exception is if `net use` in Step 6 failed, in which case there is no connection to tear down.
- Execute: `net use "%DESTINATION%" /delete /y`
  - The `/y` suppresses the confirmation prompt.
- Check `%ERRORLEVEL%`. If non-zero, print a warning: `WARNING: Failed to disconnect network share. You may need to disconnect manually.`
- **Note:** If the exact destination path is not what was mapped in Step 6 (e.g., only the share root was mapped), the `/delete` command must target the same path used in Step 6. The implementer should ensure the disconnect target matches the connect target.

### Step 10: Finalize and Exit
- If `robocopy` returned an exit code `>= 8`, print `ERROR: Backup completed with errors.` and exit with code `1`.
- If `robocopy` returned `< 8`:
  - If `SIMULATE` is active, print `Simulation completed successfully.` and exit with code `0`.
  - Otherwise, print `Backup completed successfully.` and exit with code `0`.
- Use `endlocal` before exiting to clean up environment variables.

## 6. Robocopy Behavior Specification

| Requirement | Robocopy Flag | Behavior |
|---|---|---|
| Copy subfolders (including empty) | `/E` | Recursively copies the entire directory tree. |
| Retry failed copies | `/R:5` | Retries up to 5 times on locked/network files. |
| Wait between retries | `/W:10` | Waits 10 seconds between each retry attempt. |
| Overwrite only if source is newer | `/XO` | If destination file exists and is newer, skip it. If source is newer or file doesn't exist, copy it. |
| Hide progress bars | `/NP` | Prevents `100%` progress lines from flooding the log. |
| Dual output (console + log) | `/TEE` | Displays output in the terminal AND writes to the log file. |
| Verbose file listing | `/V` | Logs every file processed, including those skipped. Essential for identifying files skipped due to `/XO`. |
| Append to log file | `/LOG+:"file"` | Appends the entire robocopy output to the specified log file. |
| List only (simulate) | `/L` | Lists files that would be copied without performing any actual copy operations. |

**Non-Goals for Robocopy:**
- Do **not** use `/MIR` (mirror). This would delete files from the destination that are not in the source.
- Do **not** use `/PURGE`. This would delete extra files from the destination.
- Do **not** use `/MOV` or `/MOVE`. Files must remain in the source.

## 7. Error Handling

| Failure Point | Behavior | Exit Code |
|---|---|---|
| `backup.cfg` missing | Continue normally. | -- |
| `net use` authentication fails | Print error to console. Do **not** run robocopy. Exit immediately. | `net use` error code |
| `robocopy` encounters failures (exit >= 8) | Print error to console. Still run disconnect. Exit with `1`. | `1` |
| `net use /delete` fails | Print warning to console. Continue to exit. | Based on robocopy result |

## 8. Logging Specification

- **Log File Name Format:** `backup_YYYYMMDD_HHMMSS.log`
  - `YYYY` = 4-digit year
  - `MM` = 2-digit month
  - `DD` = 2-digit day
  - `HH` = 2-digit hour (24-hour format)
  - `MM` = 2-digit minute
  - `SS` = 2-digit second
- **Log File Location:** `%LOG_DIR%\backup_%TIMESTAMP%.log`
- **Log Content:** The log contains the complete `robocopy` output, including:
  - Source and destination paths.
  - Full file listing (due to `/V`).
  - Files copied.
  - Files skipped (with reason, including "older").
  - Retry attempts.
  - Final summary table.
- **Console Output:** The same content is echoed to the console window in real-time thanks to `/TEE`.

## 9. Batch Script Technical Constraints

- **Language:** Pure Windows Batch (`.bat` or `.cmd`). No PowerShell, VBScript, or external dependencies.
- **Delayed Expansion:** Use `setlocal EnableDelayedExpansion` to safely handle variables inside `if` blocks and `for` loops.
- **Variable Scope:** All internal variables should be cleaned up via `endlocal` on exit.
- **Path Handling:** All paths must be enclosed in double quotes (`"%SOURCE%"`) when passed as arguments to `net use` or `robocopy` to handle spaces.
- **Date/Time Parsing:** Parsing `%date%` and `%time%` into a safe filename string can be tricky due to locale differences. The implementation must handle single-digit hours/minutes/seconds (which may contain a leading space) by replacing spaces with zeros or stripping them. A safe pattern is:
  ```cmd
  set TIMESTAMP=%date:~-4,4%%date:~-10,2%%date:~-7,2%_%time:~0,2%%time:~3,2%%time:~6,2%
  set TIMESTAMP=%TIMESTAMP: =0%
  ```
  *(Note: This assumes a US-style date. The implementer may need to adjust based on their system's `date` format. The spec recommends using `wmic os get localdatetime` for a locale-independent timestamp, but that adds complexity. The implementer should pick one robust method and document it.)*

### 9.1 Handling Paths with Spaces

Windows paths frequently contain spaces (e.g., `C:\Users\John Smith\Documents`). The script must handle these correctly in the following situations:

1. **Quoting all path variables:** Whenever `SOURCE`, `DESTINATION`, `LOG_DIR`, or `LOG_FILE` are passed as arguments to any command (`robocopy`, `net use`, `mkdir`, `if exist`), they **must** be enclosed in double quotes. The spec already shows this in most places, but the implementer must verify it everywhere.

2. **Trailing backslash escaping:** In batch files, if a quoted path ends with a backslash, the backslash escapes the closing quote and corrupts the command. For example, `"C:\My Documents\"` becomes invalid because `\"` is parsed as an escaped quote. **Before** quoting and passing `SOURCE` or `DESTINATION` to commands, the implementer must strip any trailing backslash(es). A safe technique is:
   ```cmd
   if "%SOURCE:~-1%"=="\" set SOURCE=%SOURCE:~0,-1%
   if "%DESTINATION:~-1%"=="\" set DESTINATION=%DESTINATION:~0,-1%
   ```

3. **Passwords with spaces:** The `net use` command must quote the password if it contains spaces. The syntax should be:
   ```cmd
   net use "%DESTINATION%" /user:"%USERNAME%" "%PASSWORD%"
   ```
   Without quotes around `%PASSWORD%`, a password like `hello world` would be parsed as two separate arguments (`hello` and `world`), causing authentication to fail. Similarly, usernames with spaces (e.g., `First Last`) should be passed as `/user:"%USERNAME%"`.

4. **Config file values with spaces:** The `for /f` parser with `tokens=1,* delims==` correctly preserves spaces in the value portion (e.g., `SOURCE=C:\My Documents` yields `C:\My Documents`). However, leading or trailing spaces around the value will be captured in `%%B`. The trimming logic must remove these so the variable does not contain accidental spaces.

5. **`mkdir` with spaces:** Creating the log directory must use quotes: `mkdir "%LOG_DIR%"`. Without quotes, `mkdir C:\My Logs` would attempt to create two directories (`C:\My` and `Logs`).

## 10. Example Usage Scenarios

### Scenario A: Using Config File Only
User creates `backup.cfg` with all settings and runs:
```cmd
backup.bat
```
- Script reads all values from `backup.cfg`.
- Prompts only for password.
- Authenticates, runs robocopy, disconnects.

### Scenario B: Override Everything via CLI
```cmd
backup.bat D:\Photos \\NAS\PhotosBackup nasadmin C:\TempLogs
```
- Script ignores `backup.cfg` entirely for these values.
- Prompts only for password.

### Scenario C: No Config File, No CLI Args
```cmd
backup.bat
```
- Script prompts interactively for `SOURCE`, `DESTINATION`, `USERNAME`.
- Prompts for password.
- Logs to current directory.

### Scenario D: Simulate Mode
```cmd
backup.bat /L D:\Photos \\NAS\PhotosBackup nasadmin C:\TempLogs
```
- Script processes `/L` as the simulate flag.
- Reads/uses the positional arguments normally.
- Prompts for password.
- Connects to the network share, runs robocopy with `/L`, then disconnects.
- No files are actually copied; the log contains only a listing of what would be copied.

## 11. Pseudocode (Complete Script Skeleton)

```batch
@echo off
setlocal EnableDelayedExpansion

:: 1. Determine script directory and scan for /L
set SCRIPT_DIR=%~dp0
set SIMULATE=
for %%A in (%*) do (
    if /I "%%A"=="/L" set SIMULATE=1
)

:: 2. Parse backup.cfg if it exists
if exist "%SCRIPT_DIR%backup.cfg" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%SCRIPT_DIR%backup.cfg") do (
        :: Trim whitespace, ignore comments, set vars if not overridden by CLI
    )
)

:: 3. Override with CLI args (skip /L when assigning positional values)
set ARG_POS=0
:parse_args
if "%~1"=="" goto :args_done
if /I "%~1"=="/L" (
    set SIMULATE=1
    shift
    goto :parse_args
)
set /a ARG_POS+=1
if %ARG_POS%==1 set SOURCE=%~1
if %ARG_POS%==2 set DESTINATION=%~1
if %ARG_POS%==3 set USERNAME=%~1
if %ARG_POS%==4 set LOG_DIR=%~1
shift
goto :parse_args
:args_done

:: 4. Prompt for missing values
if not defined SOURCE set /p SOURCE="Enter source folder path: "
if not defined DESTINATION set /p DESTINATION="Enter destination network path: "
if not defined USERNAME set /p USERNAME="Enter NAS username: "
if not defined LOG_DIR set LOG_DIR=.

:: 5. Prompt for password
set /p PASSWORD="Enter NAS password: "

:: 6. Prepare log file
:: ... timestamp generation ...
set LOG_FILE=%LOG_DIR%\backup_%TIMESTAMP%.log
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

:: Strip trailing backslashes to prevent quote escaping
if "%SOURCE:~-1%"=="\" set SOURCE=%SOURCE:~0,-1%
if "%DESTINATION:~-1%"=="\" set DESTINATION=%DESTINATION:~0,-1%

:: 7. Authenticate
net use "%DESTINATION%" /user:"%USERNAME%" "%PASSWORD%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to authenticate to network share.
    endlocal
    exit /b %ERRORLEVEL%
)

:: 8. Run robocopy
if defined SIMULATE (
    set SIMULATE_FLAG=/L
) else (
    set SIMULATE_FLAG=
)
robocopy "%SOURCE%" "%DESTINATION%" /E /R:5 /W:10 /XO /NP /TEE /V /LOG+:"%LOG_FILE%" %SIMULATE_FLAG%
set ROBOCOPY_RESULT=%ERRORLEVEL%

:: 9. Disconnect (unconditional)
net use "%DESTINATION%" /delete /y
if %ERRORLEVEL% neq 0 (
    echo WARNING: Failed to disconnect network share.
)

:: 10. Check result and exit
if %ROBOCOPY_RESULT% geq 8 (
    echo ERROR: Backup completed with errors.
    endlocal
    exit /b 1
) else (
    if defined SIMULATE (
        echo Simulation completed successfully.
    ) else (
        echo Backup completed successfully.
    )
    endlocal
    exit /b 0
)
```

## 12. Non-Goals (Out of Scope)

- **No incremental/differential logic.** The script does not maintain state between runs; every run is a full robocopy pass.
- **No scheduling.** The script is designed to be run manually.
- **No encryption.** The `backup.cfg` file is plain text.
- **No GUI.** The interface is strictly command-line.
- **No email/SMS notifications.** Success or failure is reported only to the console and the log file.
- **No file versioning.** Older files at the destination are never renamed or archived; they are simply skipped by `/XO`.
- **No credential caching.** The password is never written to disk or the Windows Credential Manager.

## 13. Open Questions / Implementation Notes

- **Locale-Independent Timestamp:** The implementer should verify the date/time parsing logic works on their specific Windows locale, or switch to `wmic os get localdatetime` for a foolproof ISO timestamp.
- **UNC Path Granularity for `net use`:** If `DESTINATION` is a deep subfolder like `\\NAS\Share\FolderA\FolderB`, `net use` against the full path may fail if the user's permissions are set at the `Share` level. A more robust implementation may extract the share root (e.g., `\\NAS\Share`) for `net use`, while still passing the full path to `robocopy`. This decision is left to the implementer.
- **Config File Trimming:** Implementers should ensure the config parser correctly handles values with spaces (e.g., `SOURCE=C:\My Documents`) without requiring quotes in the file.
