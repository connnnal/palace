@echo off

SETLOCAL

FOR %%a IN (%*) DO SET "%%a=1"

:: Flags for visual applications.
SET app_vis_flags=
IF "%-window%"=="1" (
	SET app_vis_flags=%app_vis_flags% -subsystem:windows
)

:: Flags for applications.
SET app_flags=
IF "%-retail"=="1" (
	SET app_flags=%app_flags% -source-code-locations:obfuscated
)
IF "%-no-crt%"=="1" (
	SET app_flags=%app_flags% -no-crt
)
IF "%-instrument%"=="1" (
	SET app_flags=%app_flags% -define:USE_PERFORMANCEAPI_INSTRUMENTATION=true -extra-linker-flags:"/ignore:4099"
)

:: Flags for all binaries.
SET all_flags=
IF NOT "%-nocollections%"=="1" (
	SET all_flags=%all_flags% -collection:lib=lib
)
IF "%-vet%"=="1" (
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
	SET all_flags=%all_flags% -o:speed -debug
) ELSE (
	ECHO [debug mode]
	SET all_flags=%all_flags% -debug
	SET app_vis_flags=%app_vis_flags% -define:USE_GFX_DEBUG=true
)
IF "%-show-timings%"=="1" (
	SET all_flags=%all_flags% -show-timings
)
IF "%-show-system-calls%"=="1" (
	SET all_flags=%all_flags% -show-system-calls
)
IF "%-retail%"=="1" (
	SET all_flags=%all_flags% -microarch:ivybridge
) ELSE (
	SET all_flags=%all_flags% -microarch:native
)

:: Targets
IF "%-test%"=="1" (
	odin test src -out:palace_tests.exe %all_flags% -keep-executable
)
IF %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

IF "%shadertool%"=="1" (
	odin build shadertool -out:shadertool.exe %all_flags% %app_flags% -keep-executable
)
IF %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

IF "%app%"=="1" (
	odin build src -out:palace.exe %all_flags% %app_flags% %app_vis_flags% -keep-executable
)
IF %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%
