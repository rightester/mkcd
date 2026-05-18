@echo off
mkdir %*
if errorlevel 1 exit /b 1
for %%a in (%*) do set "last=%%a"
cd /d "%last%" && cmd
