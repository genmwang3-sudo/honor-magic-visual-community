@echo off
setlocal
set "ROOT=%~dp0"
set "DOTNET_ROOT=%ROOT%tools\dotnet"
set "DOTNET_ROOT_X64=%ROOT%tools\dotnet"
set "DOTNET_MULTILEVEL_LOOKUP=0"
set "DOTNET_CLI_TELEMETRY_OPTOUT=1"
set "DOTNET_NOLOGO=1"
start "" "%ROOT%versions\0.4.10\MagicCommunity.exe" --root "%ROOT%"
