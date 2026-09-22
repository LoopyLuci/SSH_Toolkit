<#
A quick end-to-end smoke test against a fake $HOME, exercising both the module directly
and the bin/ssh-toolkit.ps1 CLI wrapper. Not a full Pester suite (none is set up yet -
see README's Contributing section) but enough to catch a real regression before a
release tag. Exits non-zero on any failure.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testHome = Join-Path $env:TEMP "sshtoolkit-smoketest-$(Get-Random)"
New-Item -ItemType Directory -Path $testHome -Force | Out-Null
Set-Variable -Name HOME -Value $testHome -Scope Global -Force

$failures = 0
function Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "  ok: $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "=== Module: direct function calls ===" -ForegroundColor Cyan
Import-Module (Join-Path $root 'SSHToolkit.psd1') -Force
$connA = Add-SshLinkConnection -Name boxA -HostName 10.0.0.1 -User u -IdentityFile (Join-Path $testHome '.ssh\k1') -Tags 'prod' -Multiplex
Assert ($connA.Name -eq 'boxA') 'Add-SshLinkConnection returns the new connection'
# NOTE: always wrap in @() when you need array semantics (.Count, indexing) - a single
# result comes back as a bare object otherwise, same as Get-ChildItem/Get-Process. See
# README.md's Gotchas section and SSHToolkit.psm1's Get-SshLinkConnections comment.
Assert (@(Get-SshLinkConnections).Count -eq 1) 'Get-SshLinkConnections sees it'
Assert ((Get-Content (Join-Path $testHome '.ssh\config') -Raw) -match 'Host boxA') 'ssh config block was written'

$connB = Add-SshLinkConnection -Name boxB -HostName 10.0.0.2 -User u -IdentityFile (Join-Path $testHome '.ssh\k2') -ProxyJump boxA
Assert (@(Get-SshLinkGraph).Count -eq 2) 'Get-SshLinkGraph sees both, including the proxy-jumped one'

$updated = Set-SshLinkConnection -Name boxA -User newuser
Assert ($updated.User -eq 'newuser') 'Set-SshLinkConnection updates only the given field'
Assert ((Get-SshLinkConnection -Name boxA).HostName -eq '10.0.0.1') 'Set-SshLinkConnection left HostName alone'

$exportFile = Join-Path $testHome 'export.json'
$exported = Export-SshLinkConnections -FilePath $exportFile
Assert ($exported.Count -eq 2) 'Export-SshLinkConnections wrote both'
Remove-SshLinkConnection -Name boxB -Force
Assert (@(Get-SshLinkConnections).Count -eq 1) 'Remove-SshLinkConnection removed boxB'
$imported = Import-SshLinkConnections -FilePath $exportFile
Assert ($imported.Added -eq 1 -and $imported.Skipped.Count -eq 1) 'Import-SshLinkConnections re-adds only the missing one'
Assert (@(Get-SshLinkConnections).Count -eq 2) 'Both are back after import'

Write-Host "=== bin/ssh-toolkit.ps1: CLI wrapper ===" -ForegroundColor Cyan
$cli = Join-Path $root 'bin\ssh-toolkit.ps1'
$listJson = & $cli -Action List -Json | ConvertFrom-Json
Assert (@($listJson).Count -eq 2) 'CLI List -Json sees both connections'

$graphJson = & $cli -Action Visualize -Json | ConvertFrom-Json
Assert (@($graphJson).Count -eq 2) 'CLI Visualize -Json returns structured graph data'

& $cli -Action Remove -Name boxA -Force
& $cli -Action Remove -Name boxB -Force
Assert ((Get-SshLinkConnections).Count -eq 0) 'CLI Remove works for both'

Write-Host "=== Update check (network-dependent, non-fatal if it fails) ===" -ForegroundColor Cyan
try {
    $check = Test-SshToolkitUpdate -Repo 'LoopyLuci/SSH_Toolkit'
    Write-Host "  Test-SshToolkitUpdate: installed=$($check.InstalledVersion) error=$($check.Error)"
}
catch { Write-Host "  (skipped: $($_.Exception.Message))" -ForegroundColor Yellow }

Remove-Item $testHome -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -gt 0) {
    Write-Host "`n$failures check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nAll checks passed." -ForegroundColor Green
