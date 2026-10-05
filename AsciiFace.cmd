@echo off
rem Run AsciiFace straight from this folder (no install needed for the preview).
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0asciiface.ps1"
