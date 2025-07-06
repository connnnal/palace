@echo off

odin build src -out:palace.exe -collection:src=src -collection:lib=lib -debug
IF %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%
