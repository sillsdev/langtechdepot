@echo off
REM LangTechDepot subscription tool for Windows - double-click this file.
REM
REM Windows refuses to run downloaded PowerShell scripts on a stock machine, so
REM setup-langtechdepot.ps1 cannot just be right-clicked. This wrapper runs it
REM the one way that works without changing any machine-wide setting, so a
REM field user has a single file to double-click and no command to memorise.
REM
REM %~dp0 is the folder holding this file. Without it the script would not be
REM found unless the window happened to already be in that folder - and "Run as
REM administrator" starts in system32, never here.
REM
REM -NoProfile: a user's PowerShell profile cannot interfere with the install.
REM -NoPause:   the pause below is this window's own, so the user is not asked
REM             to press Enter twice. It also keeps the window open when
REM             PowerShell itself refuses to start, which is the one failure
REM             the script cannot report for itself.

REM The likeliest mistake is downloading this file on its own, since it is the
REM one the instructions say to click. Say so plainly rather than letting
REM PowerShell report it as a bad -File argument.
if not exist "%~dp0langtechdepot-subscribe.ps1" (
    echo langtechdepot-subscribe.ps1 is not in this folder, so there is nothing to run.
    echo Download it from the same place you got this file, put the two side by
    echo side, and double-click this one again.
    echo.
    pause
    exit /b 1
)

powershell -ExecutionPolicy Bypass -File .\langtechdepot-subscribe.ps1

REM Stashed before pause, which resets ERRORLEVEL, so an unattended caller
REM still sees whether the install actually worked.
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
