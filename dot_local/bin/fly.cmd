@echo off
rem fly -> flyctl for cmd and PowerShell (Windows-only, with core). winget's
rem Fly-io.flyctl exposes only flyctl; Fly's docs say fly, and brew and Fly's
rem install.sh give macOS and Linux both names. Forwards every argument.
flyctl %*
