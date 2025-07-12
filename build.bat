@echo off

SETLOCAL

FOR %%a IN (%*) DO SET "%%a=1"

:: Flags for all binaries.
SET all_flags=
IF NOT "%-nocollections%"=="1" (
	SET all_flags=%all_flags% -collection:src=src -collection:lib=lib
)
IF NOT "%-novet%"=="1" (
	SET all_flags=%all_flags% -vet
)
IF NOT "%-nostyle%"=="1" (
	SET all_flags=%all_flags% -strict-style
)
IF NOT "%-allowdo%"=="1" (
	SET all_flags=%all_flags% -disallow-do
)
IF "%-release%"=="1" (
	ECHO [release mode]
	SET all_flags=%all_flags% -o:speed
) ELSE (
	ECHO [debug mode]
	SET all_flags=%all_flags% -debug
)
IF "%-show-timings%"=="1" (
	SET all_flags=%all_flags% -show-timings
)
IF "%-show-system-calls%"=="1" (
	SET all_flags=%all_flags% -show-system-calls
)
IF "%-retail%"=="1" (
	SET all_flags=%all_flags% -microarch:native
) ELSE (
	SET all_flags=%all_flags% -microarch:ivybridge
)

:: Flags for shipped visual applications.
SET app_flags=
IF "%-window%"=="1" (
	SET app_flags=%app_flags% -subsystem:windows
)
IF "%-retail"=="1" (
	SET app_flags=%app_flags% -source-code-locations:obfuscated
)
IF "%-no-crt%"=="1" (
	SET app_flags=%app_flags% -no-crt
)
IF "%-instrument%"=="1" (
	SET app_flags=%app_flags% -define:USE_PERFORMANCEAPI_INSTRUMENTATION=true -extra-linker-flags:"/ignore:4099"
)

:: Targets
IF "%-test%"=="1" (
	odin test src -out:palace_tests.exe %all_flags%
)
IF %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

odin build src -out:palace.exe %all_flags% %app_flags%
IF %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%
