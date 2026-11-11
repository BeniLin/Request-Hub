@echo off
rem Add or update a project (registry.csv + projects/<KEY>.md)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\add-project.ps1"
pause
