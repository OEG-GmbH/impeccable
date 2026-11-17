@echo off
setlocal
rem Impeccable launcher (Windows), this fork. Runs exactly one engine:
rem bin\windows-<arch>\impeccable.exe next to this file, verified via certutil
rem against engine-checksums.txt next to this file. There is no other
rem candidate (no IMPECCABLE_BIN, no user cache, no PATH lookup) and no
rem download: a missing or unverified binary stops the launcher with a message.
rem - Hash and run open the path twice. Unlike the sh launcher, this file does
rem   not check owner and ACLs (no portable way in batch); the fork ships no
rem   Windows build, so engine-checksums.txt lists no Windows digest and this
rem   launcher refuses to run anything until one is added.
rem - Exit status: 3 when no binary is installed next to this file, 127 when
rem   one is there but refused; otherwise the engine's own status.
rem
rem Structure notes:
rem - No multi-line parenthesized blocks: cmd expands %var% at block parse
rem   time. Linear goto flow keeps every expansion on its own line, and avoids
rem   delayed expansion eating ! characters in user arguments.
rem - The binary is hashed on every run: there is no stamp cache, so nothing
rem   next to the binary can vouch for it and this file writes nothing beside
rem   it. On ARM64 the arm64 digest is checked first and the x64 digest is the
rem   fallback (Windows on ARM runs x64 binaries).
if not defined IMPECCABLE_SKILL_DIR set "IMPECCABLE_SKILL_DIR=%~dp0.."
if not defined IMPECCABLE_SELF set "IMPECCABLE_SELF=%~f0"
set "arch=x64"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "arch=arm64"

set "version="
if exist "%~dp0VERSION" set /p version=<"%~dp0VERSION"
if not defined version goto no_version
set "asset=impeccable-windows-%arch%.exe"
set "manifest=%~dp0engine-checksums.txt"
call :read_expected
set "run=%~dp0bin\windows-%arch%\impeccable.exe"
rem Existence first: a launcher-only copy says "not installed" even when the
rem manifest lists no digest for this platform yet.
if not exist "%run%" goto no_binary
if not defined expected if not defined expected_x64 goto no_checksum
call :sha256 "%run%" "%TEMP%\impeccable-hash-%RANDOM%%RANDOM%.txt"
if not defined actual goto cannot_hash
if /I "%actual%"=="%expected%" goto run
if /I "%actual%"=="%expected_x64%" goto run
echo impeccable: checksum mismatch for "%run%" (sha256 %actual%, "%manifest%" expects %expected%); refusing to run it 1>&2
exit /b 127
:run
"%run%" %*
exit /b %errorlevel%

:read_expected
rem Sets expected (and, on ARM64, expected_x64: Windows on ARM runs x64
rem binaries) from engine-checksums.txt.
call :manifest_digest "%asset%" expected
set "expected_x64="
if "%arch%"=="arm64" call :manifest_digest impeccable-windows-x64.exe expected_x64
exit /b 0

:manifest_digest
rem Sets the variable named %2 to the digest the first engine-checksums.txt
rem line for this version and asset %1 records, empty when there is none.
set "%~2="
if not exist "%manifest%" exit /b 0
for /f "usebackq tokens=1-3" %%a in ("%manifest%") do if "%%a"=="%version%" if /I "%%b"=="%~1" if not defined %~2 set "%~2=%%c"
exit /b 0

:sha256
rem Sets actual to the sha256 of %~1, empty when certutil fails. %~2 is the
rem scratch file for its output. Check certutil's status before parsing: its
rem error text on stdout is not a digest.
set "actual="
certutil -hashfile "%~1" SHA256 >"%~2" 2>nul
if errorlevel 1 goto sha256_done
for /f "usebackq skip=1 delims=" %%h in ("%~2") do if not defined actual set "actual=%%h"
if not defined actual goto sha256_done
set "actual=%actual: =%"
:sha256_done
del "%~2" >nul 2>nul
exit /b 0

:no_version
echo impeccable: no engine version in "%~dp0VERSION"; refusing to run 1>&2
exit /b 127

:no_checksum
echo impeccable: no checksum for engine %version% (%asset%) in "%manifest%"; refusing to run 1>&2
exit /b 127

:no_binary
echo impeccable: engine %version% is not installed: no binary at "%run%" 1>&2
echo impeccable: the fork downloads nothing. Copy the fork build of %asset% there; its sha256 must be the one "%manifest%" lists. 1>&2
if not defined expected if not defined expected_x64 echo impeccable: "%manifest%" lists no digest for engine %version% asset %asset% yet; add the fork build's sha256 there as well. 1>&2
exit /b 3

:cannot_hash
echo impeccable: cannot verify "%run%" (certutil could not hash it); refusing to run it 1>&2
exit /b 127
