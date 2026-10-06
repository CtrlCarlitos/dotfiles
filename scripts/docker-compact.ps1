#Requires -Version 5.1
<#
docker-compact.ps1 - `dot docker-compact`: shrink Docker Desktop's data disk on Windows.

docker_data.vhdx (images, containers, volumes, build cache) grows and never shrinks on its own;
`docker image prune` / `docker builder prune` free space inside it, not on the drive. This stops
Docker Desktop (VS Code first), shuts WSL down and compacts the disk: Optimize-VHD when the
Hyper-V PowerShell module works here, diskpart's `compact vdisk` otherwise. It asks first.

  dot docker-compact          (elevated; asks y/N)
  dot docker-compact -Yes     (no question)

Prune first to get the most out of it, e.g. from WSL: docker image prune -a; docker builder prune.
#>
param([switch]$Yes)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ps-common.ps1')

if (-not (Test-IsAdmin)) {
    Write-Host "dot docker-compact needs an elevated terminal (Optimize-VHD and diskpart both do)." -ForegroundColor Red
    exit 1
}
Repair-InBoxModulePath

if (Invoke-DockerDiskCompact -ExcludeId @(Get-AncestorProcessId) -Yes:$Yes) { exit 0 }
exit 1
