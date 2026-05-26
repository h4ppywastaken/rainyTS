@echo off
title rainyTS Client (stand-alone)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0@Resources\TS6Client.ps1"
pause
