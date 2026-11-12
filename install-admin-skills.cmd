@echo off
rem Install admin skills to the user-level Claude skills folder
set "SOURCE=%~dp0admin-skills\spec-init"
set "TARGET=%USERPROFILE%\.claude\skills"
if not exist "%SOURCE%\SKILL.md" (
  echo [X] Source not found: "%SOURCE%"
  echo     Nothing was changed.
  pause
  exit /b 1
)
if not exist "%TARGET%" mkdir "%TARGET%"
rem Remove the installed copy first, so files deleted or renamed in the source do not linger.
rem Edits made directly in the installed copy are lost: always edit admin-skills\spec-init.
if exist "%TARGET%\spec-init" rmdir /S /Q "%TARGET%\spec-init"
xcopy /E /I /Y "%SOURCE%" "%TARGET%\spec-init" >nul
if errorlevel 1 (
  echo [X] Install failed.
) else (
  echo [OK] spec-init installed to "%TARGET%\spec-init"
  echo Restart Claude, then open a project repo and say: initialize specs
)
pause
