@echo off
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "CONFIG_FILE=%SCRIPT_DIR%backup.cfg"

set "ARG_SOURCE="
set "ARG_DESTINATION="
set "ARG_USERNAME="
set "ARG_LOG_DIR="
set "SIMULATE="
set "ARG_POS=0"

:ParseArgs
if "%~1"=="" goto :ParseArgsDone
if /i "%~1"=="/L" (
    set "SIMULATE=1"
) else (
    set /a ARG_POS+=1
    if !ARG_POS!==1 set "ARG_SOURCE=1" & set "SOURCE=%~1"
    if !ARG_POS!==2 set "ARG_DESTINATION=1" & set "DESTINATION=%~1"
    if !ARG_POS!==3 set "ARG_USERNAME=1" & set "NAS_USER=%~1"
    if !ARG_POS!==4 set "ARG_LOG_DIR=1" & set "LOG_DIR=%~1"
)
shift
goto :ParseArgs
:ParseArgsDone

if exist "%CONFIG_FILE%" (
    for /f "usebackq delims=" %%L in ("%CONFIG_FILE%") do (
        set "CFG_LINE=%%L"
        call :Trim CFG_LINE

        if defined CFG_LINE (
            set "COMMENT_PREFIX=!CFG_LINE:~0,1!"
            set "COMMENT_PREFIX_TWO=!CFG_LINE:~0,2!"

            if not "!COMMENT_PREFIX!"==";" if not "!COMMENT_PREFIX!"=="#" if not "!COMMENT_PREFIX_TWO!"=="//" (
                for /f "tokens=1,* delims==" %%A in ("!CFG_LINE!") do (
                    set "CFG_KEY=%%A"
                    set "CFG_VALUE=%%B"
                    call :Trim CFG_KEY
                    call :Trim CFG_VALUE

                    if /i "!CFG_KEY!"=="SOURCE" if not defined ARG_SOURCE set "SOURCE=!CFG_VALUE!"
                    if /i "!CFG_KEY!"=="DESTINATION" if not defined ARG_DESTINATION set "DESTINATION=!CFG_VALUE!"
                    if /i "!CFG_KEY!"=="USERNAME" if not defined ARG_USERNAME set "NAS_USER=!CFG_VALUE!"
                    if /i "!CFG_KEY!"=="LOG_DIR" if not defined ARG_LOG_DIR set "LOG_DIR=!CFG_VALUE!"
                )
            )
        )
    )
)

if not defined SOURCE set /p SOURCE="Enter source folder path: "
if not defined DESTINATION set /p DESTINATION="Enter destination network path: "
if not defined NAS_USER set /p NAS_USER="Enter NAS username: "
if not defined LOG_DIR set "LOG_DIR=."

set /p PASSWORD="Enter NAS password: "

call :StripTrailingBackslashes SOURCE
call :StripTrailingBackslashes DESTINATION

call :GenerateTimestamp
set "LOG_FILE=%LOG_DIR%\backup_%TIMESTAMP%.log"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

net use "%DESTINATION%" /user:"%NAS_USER%" "%PASSWORD%"
set "NET_USE_RESULT=%ERRORLEVEL%"
if not "%NET_USE_RESULT%"=="0" (
    echo ERROR: Failed to authenticate to network share.
    endlocal & exit /b %NET_USE_RESULT%
)

set "SIMULATE_FLAG="
if defined SIMULATE set "SIMULATE_FLAG=/L"
robocopy "%SOURCE%" "%DESTINATION%" /E /R:5 /W:10 /XO /NP /TEE /V /LOG+:"%LOG_FILE%" %SIMULATE_FLAG%
set "ROBOCOPY_RESULT=%ERRORLEVEL%"

net use "%DESTINATION%" /delete /y
set "DISCONNECT_RESULT=%ERRORLEVEL%"
if not "%DISCONNECT_RESULT%"=="0" (
    echo WARNING: Failed to disconnect network share. You may need to disconnect manually.
)

if %ROBOCOPY_RESULT% geq 8 (
    echo ERROR: Backup completed with errors.
    endlocal & exit /b 1
) else (
    if defined SIMULATE (
        echo Simulation completed successfully.
    ) else (
        echo Backup completed successfully.
    )
    endlocal & exit /b 0
)

:Trim
set "TRIM_VALUE=!%~1!"
for /f "tokens=* delims= 	" %%T in ("!TRIM_VALUE!") do set "TRIM_VALUE=%%T"
:TrimTrailingLoop
if defined TRIM_VALUE if "!TRIM_VALUE:~-1!"==" " (
    set "TRIM_VALUE=!TRIM_VALUE:~0,-1!"
    goto :TrimTrailingLoop
)
if defined TRIM_VALUE if "!TRIM_VALUE:~-1!"=="	" (
    set "TRIM_VALUE=!TRIM_VALUE:~0,-1!"
    goto :TrimTrailingLoop
)
set "%~1=!TRIM_VALUE!"
exit /b 0

:StripTrailingBackslashes
set "STRIP_VALUE=!%~1!"
:StripTrailingBackslashesLoop
if defined STRIP_VALUE if "!STRIP_VALUE:~-1!"=="\" (
    set "STRIP_VALUE=!STRIP_VALUE:~0,-1!"
    goto :StripTrailingBackslashesLoop
)
set "%~1=!STRIP_VALUE!"
exit /b 0

:GenerateTimestamp
rem Uses WMIC localdatetime for a locale-independent YYYYMMDD_HHMMSS timestamp.
set "LOCAL_DATETIME="
for /f "tokens=2 delims==" %%T in ('wmic os get localdatetime /value 2^>nul') do if not defined LOCAL_DATETIME set "LOCAL_DATETIME=%%T"
if defined LOCAL_DATETIME (
    set "TIMESTAMP=!LOCAL_DATETIME:~0,8!_!LOCAL_DATETIME:~8,6!"
) else (
    rem Fallback for systems without WMIC. This follows the spec's safe US-style date parsing pattern.
    set "TIMESTAMP=%date:~-4,4%%date:~-10,2%%date:~-7,2%_%time:~0,2%%time:~3,2%%time:~6,2%"
    set "TIMESTAMP=!TIMESTAMP: =0!"
)
exit /b 0
