@echo off
rem Start AsciiFace from this folder.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0asciiface.ps1"
