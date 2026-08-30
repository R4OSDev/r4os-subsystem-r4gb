@echo off
setlocal EnableExtensions DisableDelayedExpansion
where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell 7 ^(pwsh.exe^) is required.
    exit /b 1
)
pwsh.exe -NoLogo -NoProfile -File "%~dp0Build.ps1" %*
exit /b %ERRORLEVEL%
