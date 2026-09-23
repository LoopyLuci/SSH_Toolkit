<#
.SYNOPSIS
    SSH Toolkit - create, manage, visualize and use named SSH connections between
    machines. Interactive menu for people, named parameters for scripts and agents.
    This is the standalone entry point; every action is also a plain function you can
    call directly after `Import-Module SSHToolkit` from your own scripts - see README.md.

.PARAMETER Action
    List | Add | Edit | Remove | Connect | Test | TestAll | Visualize | InstallKey | Show |
    GenerateLauncher | Copy | Export | Import | Update | CheckUpdate
    Omit this (and every other parameter) to get the interactive menu instead.

.PARAMETER Name
    A short alias for the connection, e.g. "devbox", "prod-server".

.PARAMETER HostName
    The real hostname or IP address of the other machine.

.PARAMETER Port
    SSH port on the other machine. Default 22.

.PARAMETER User
    The username to log in as on the other machine.

.PARAMETER IdentityFile
    Path to the private key to use. With -GenerateKey and no IdentityFile, a new
    ed25519 keypair is generated at ~/.ssh/id_ed25519_<Name>.

.PARAMETER GenerateKey
    With -Action Add: generate a new ed25519 keypair instead of using an existing one.

.PARAMETER ProxyJump
    Optional jump host (another registered Name, or a raw user@host[:port]).

.PARAMETER Command
    With -Action Connect or Test: a remote command to run non-interactively.

.PARAMETER Json
    Machine-readable JSON output instead of a table/text - for agents and scripts.

.PARAMETER Force
    With -Action Add: overwrite an existing connection. With -Action Remove: skip
    confirmation. With -Action Update: apply even if already up to date.

.PARAMETER LauncherPath
    Folder to write the standalone Connect-<Name>.ps1 launcher into.

.PARAMETER Multiplex
    Turn on SSH connection multiplexing (ControlMaster) for this connection.

.PARAMETER LocalForward / RemoteForward
    One or more "port:host:port" forwards (ssh -L / -R). Repeatable.

.PARAMETER Tags
    Free-text, comma-separated labels for grouping in -Action Visualize.

.PARAMETER LocalPath / RemotePath / ToRemote
    With -Action Copy: local and remote paths, and which direction.

.PARAMETER FilePath
    With -Action Export/Import: the JSON file to write to / read from.

.EXAMPLE
    .\ssh-toolkit.ps1
.EXAMPLE
    .\ssh-toolkit.ps1 -Action Add -Name devbox -HostName 10.0.0.12 -User luci -GenerateKey
.EXAMPLE
    .\ssh-toolkit.ps1 -Action Connect -Name devbox -Command "uname -a"
.EXAMPLE
    .\ssh-toolkit.ps1 -Action Visualize
.EXAMPLE
    .\ssh-toolkit.ps1 -Action CheckUpdate -Json
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Scripted')]
    [ValidateSet('List', 'Add', 'Edit', 'Remove', 'Connect', 'Test', 'TestAll', 'Visualize',
                 'InstallKey', 'Show', 'GenerateLauncher', 'Copy', 'Export', 'Import',
                 'Update', 'CheckUpdate')]
    [string]$Action,

    [Parameter(ParameterSetName = 'Scripted')] [string]$Name,
    [Parameter(ParameterSetName = 'Scripted')] [string]$HostName,
    [Parameter(ParameterSetName = 'Scripted')] [int]$Port = 22,
    [Parameter(ParameterSetName = 'Scripted')] [string]$User,
    [Parameter(ParameterSetName = 'Scripted')] [string]$IdentityFile,
    [Parameter(ParameterSetName = 'Scripted')] [switch]$GenerateKey,
    [Parameter(ParameterSetName = 'Scripted')] [string]$ProxyJump,
    [Parameter(ParameterSetName = 'Scripted')] [string]$Command,
    [Parameter(ParameterSetName = 'Scripted')] [switch]$Json,
    [Parameter(ParameterSetName = 'Scripted')] [switch]$Force,
    [Parameter(ParameterSetName = 'Scripted')] [string]$LauncherPath,
    [Parameter(ParameterSetName = 'Scripted')] [string]$Notes,
    [Parameter(ParameterSetName = 'Scripted')] [switch]$Multiplex,
    [Parameter(ParameterSetName = 'Scripted')] [string[]]$LocalForward,
    [Parameter(ParameterSetName = 'Scripted')] [string[]]$RemoteForward,
    [Parameter(ParameterSetName = 'Scripted')] [string]$Tags,
    [Parameter(ParameterSetName = 'Scripted')] [string]$LocalPath,
    [Parameter(ParameterSetName = 'Scripted')] [string]$RemotePath,
    [Parameter(ParameterSetName = 'Scripted')] [switch]$ToRemote,
    [Parameter(ParameterSetName = 'Scripted')] [string]$FilePath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\SSHToolkit.psd1') -Force

# ------------------------------------------------------------ display helpers ----

function Show-SshLinkList {
    param([switch]$Json)
    $all = Get-SshLinkConnections
    if ($Json) { ConvertTo-Json -InputObject @($all) -Depth 4; return }
    if (-not $all -or $all.Count -eq 0) {
        Write-Host "No connections yet. Add one with -Action Add, or run with no arguments for the menu."
        return
    }
    $all | Select-Object Name, HostName, Port, User, ProxyJump, Tags,
        @{N = 'Multiplex'; E = { [bool]$_.Multiplex } }, Notes | Format-Table -AutoSize
}

function Show-SshLinkConnectionDetail {
    param([Parameter(Mandatory)][string]$Name, [switch]$Json)
    $conn = Get-SshLinkConnection -Name $Name
    if (-not $conn) { throw "No connection named '$Name'." }
    if ($Json) { $conn | ConvertTo-Json -Depth 4; return }
    $conn | Format-List
    Write-Host "`n--- ~/.ssh/config block ---"
    Write-Host (Get-SshConfigBlockText -Connection $conn)
}

function Show-SshLinkStatusAllTable {
    param([switch]$Json)
    $rows = @(Get-SshLinkStatusAll)
    if ($Json) { ConvertTo-Json -InputObject $rows -Depth 3; return }
    if ($rows.Count -eq 0) { Write-Host 'No connections registered yet.'; return }
    foreach ($r in $rows) {
        $color = if ($r.Reachable) { 'Green' } else { 'Red' }
        $mark = if ($r.Reachable) { 'UP  ' } else { 'DOWN' }
        Write-Host ("  [{0}] {1,-16} {2}" -f $mark, $r.Name, $r.Target) -ForegroundColor $color
    }
}

function Show-SshLinkGraphTree {
    $rows = @(Get-SshLinkGraph)
    if ($rows.Count -eq 0) { Write-Host 'No connections registered yet.'; return }
    Write-Host ''
    Write-Host 'This machine' -ForegroundColor Cyan
    foreach ($r in $rows) {
        $c = $r.Connection
        $mark = if ($r.Reachable) { 'UP  ' } else { 'DOWN' }
        $color = if ($r.Reachable) { 'Green' } else { 'Red' }
        $indent = '  ' * ($r.Depth + 1)
        $tagText = if ($c.Tags) { " [$($c.Tags)]" } else { '' }
        Write-Host ("$indent+-- [{0}] {1}  ({2}@{3}:{4}){5}" -f $mark, $c.Name, $c.User, $c.HostName, $c.Port, $tagText) -ForegroundColor $color
    }
    Write-Host ''
}

# --------------------------------------------------------------- interactive ----

function Read-RequiredHost {
    param([string]$Prompt)
    do { $v = Read-Host $Prompt } while ([string]::IsNullOrWhiteSpace($v))
    return $v.Trim()
}

function Invoke-InteractiveMenu {
    while ($true) {
        Write-Host ''
        Write-Host '=== SSH Toolkit ===' -ForegroundColor Cyan
        Write-Host ' 1) List connections'
        Write-Host ' 2) Add a connection'
        Write-Host ' 3) Connect'
        Write-Host ' 4) Test a connection'
        Write-Host ' 5) Install this connection''s key on the remote machine'
        Write-Host ' 6) Show details / ssh config block'
        Write-Host ' 7) Remove a connection'
        Write-Host ' 8) Generate a standalone launcher script for a connection'
        Write-Host ' 9) Visualize all connections (status + proxy-jump tree)'
        Write-Host '10) Test every connection'
        Write-Host '11) Edit a connection'
        Write-Host '12) Copy a file to/from a connection'
        Write-Host '13) Export connections to a file'
        Write-Host '14) Import connections from a file'
        Write-Host '15) Check for a toolkit update'
        Write-Host '16) Quit'
        $choice = Read-Host 'Choose'
        try {
            switch ($choice) {
                '1' { Show-SshLinkList }
                '2' {
                    $name = Read-RequiredHost 'Name for this connection (e.g. devbox)'
                    $hostName = Read-RequiredHost 'Hostname or IP of the other machine'
                    $portRaw = Read-Host 'Port [22]'
                    $port = if ([string]::IsNullOrWhiteSpace($portRaw)) { 22 } else { [int]$portRaw }
                    $user = Read-Host 'Username on the other machine (blank = your current user)'
                    $useExisting = Read-Host 'Use an existing private key? (y/N, N = generate a new one)'
                    if ($useExisting -in @('y', 'Y')) {
                        $identity = Read-RequiredHost 'Path to the existing private key'
                        Add-SshLinkConnection -Name $name -HostName $hostName -Port $port -User $user -IdentityFile $identity | Out-Null
                    }
                    else {
                        $conn = Add-SshLinkConnection -Name $name -HostName $hostName -Port $port -User $user -GenerateKey
                        Write-Host "Public key is at $($conn.IdentityFile).pub - install it with menu option 5." -ForegroundColor Yellow
                    }
                }
                '3' { Connect-SshLink -Name (Read-RequiredHost 'Name of the connection to open') }
                '4' {
                    $name = Read-RequiredHost 'Name of the connection to test'
                    $ok = Test-SshLinkConnection -Name $name
                    Write-Host $(if ($ok) { 'OK - reachable and authenticated.' } else { 'FAILED - see ssh''s own output above, if any.' }) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
                }
                '5' { Install-SshLinkPublicKey -Name (Read-RequiredHost 'Name of the connection') | Out-Null }
                '6' { Show-SshLinkConnectionDetail -Name (Read-RequiredHost 'Name of the connection') }
                '7' { Remove-SshLinkConnection -Name (Read-RequiredHost 'Name of the connection to remove') }
                '8' {
                    $path = New-SshLinkLauncher -Name (Read-RequiredHost 'Name of the connection')
                    Write-Host "Wrote $path" -ForegroundColor Green
                }
                '9' { Show-SshLinkGraphTree }
                '10' { Show-SshLinkStatusAllTable }
                '11' {
                    $name = Read-RequiredHost 'Name of the connection to edit'
                    $existing = Get-SshLinkConnection -Name $name
                    if (-not $existing) { throw "No connection named '$name'." }
                    Write-Host "Leave a field blank to keep its current value." -ForegroundColor DarkGray
                    $editParams = @{ Name = $name }
                    $hostNameNew = Read-Host "HostName [$($existing.HostName)]"
                    if ($hostNameNew) { $editParams.HostName = $hostNameNew }
                    $portNew = Read-Host "Port [$($existing.Port)]"
                    if ($portNew) { $editParams.Port = [int]$portNew }
                    $userNew = Read-Host "User [$($existing.User)]"
                    if ($userNew) { $editParams.User = $userNew }
                    $multiplexNew = Read-Host "Enable multiplexing? (y/n) [$([bool]$existing.Multiplex)]"
                    if ($multiplexNew) { $editParams.Multiplex = ($multiplexNew -in @('y', 'Y')) }
                    Set-SshLinkConnection @editParams | Out-Null
                    Write-Host "Updated '$name'." -ForegroundColor Green
                }
                '12' {
                    $name = Read-RequiredHost 'Name of the connection'
                    $direction = Read-Host 'Copy to the remote machine? (y/N)'
                    $local = Read-RequiredHost 'Local path'
                    $remote = Read-RequiredHost 'Remote path'
                    Copy-SshLinkFile -Name $name -LocalPath $local -RemotePath $remote -ToRemote:($direction -in @('y', 'Y'))
                    Write-Host 'Done.' -ForegroundColor Green
                }
                '13' {
                    $result = Export-SshLinkConnections -FilePath (Read-RequiredHost 'File to export to')
                    Write-Host "Exported $($result.Count) connection(s) to $($result.FilePath)" -ForegroundColor Green
                }
                '14' {
                    $result = Import-SshLinkConnections -FilePath (Read-RequiredHost 'File to import from')
                    Write-Host "Imported $($result.Added) connection(s), skipped $($result.Skipped.Count)." -ForegroundColor Green
                }
                '15' {
                    $check = Test-SshToolkitUpdate
                    if ($check.Error) { Write-Host "Couldn't check: $($check.Error)" -ForegroundColor Red }
                    elseif ($check.UpdateAvailable) {
                        Write-Host "Update available: $($check.InstalledVersion) -> $($check.LatestVersion)" -ForegroundColor Yellow
                        if ((Read-Host 'Apply now? (y/N)') -in @('y', 'Y')) { Update-SshToolkit | Out-Null; Write-Host 'Updated.' -ForegroundColor Green }
                    }
                    else { Write-Host "Up to date ($($check.InstalledVersion))." -ForegroundColor Green }
                }
                '16' { return }
                default { Write-Host 'Not a valid choice.' -ForegroundColor Yellow }
            }
        }
        catch {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# ------------------------------------------------------------------- dispatch ----

if (-not $Action) {
    Invoke-InteractiveMenu
    return
}

switch ($Action) {
    'List' { Show-SshLinkList -Json:$Json }
    'Add' {
        if (-not $Name -or -not $HostName) { throw '-Action Add needs at least -Name and -HostName.' }
        Add-SshLinkConnection -Name $Name -HostName $HostName -Port $Port -User $User -IdentityFile $IdentityFile `
            -GenerateKey:$GenerateKey -ProxyJump $ProxyJump -Notes $Notes -Force:$Force -LauncherPath $LauncherPath `
            -Multiplex:$Multiplex -LocalForward $LocalForward -RemoteForward $RemoteForward -Tags $Tags | Out-Null
    }
    'Edit' {
        if (-not $Name) { throw '-Action Edit needs -Name.' }
        $editParams = @{ Name = $Name }
        foreach ($p in 'HostName', 'Port', 'User', 'IdentityFile', 'ProxyJump', 'Notes', 'Tags', 'LocalForward', 'RemoteForward') {
            if ($PSBoundParameters.ContainsKey($p)) { $editParams[$p] = Get-Variable -Name $p -ValueOnly }
        }
        if ($PSBoundParameters.ContainsKey('Multiplex')) { $editParams.Multiplex = [bool]$Multiplex }
        Set-SshLinkConnection @editParams | Out-Null
    }
    'Remove' {
        if (-not $Name) { throw '-Action Remove needs -Name.' }
        Remove-SshLinkConnection -Name $Name -Force:$Force
    }
    'Connect' {
        if (-not $Name) { throw '-Action Connect needs -Name.' }
        Connect-SshLink -Name $Name -Command $Command
        # Without this, a failed remote command (or a failed connection entirely) still
        # leaves this SCRIPT's own exit code at 0, since a failing external command
        # doesn't automatically propagate through a PowerShell script's exit code -
        # only ssh's own $LASTEXITCODE reflects it. A caller checking "did this
        # succeed" by exit code (any script, or bot/ssh_toolkit.py's Python wrapper in
        # AgenticBotPlatform) needs this to be real.
        exit $LASTEXITCODE
    }
    'Test' {
        if (-not $Name) { throw '-Action Test needs -Name.' }
        $ok = Test-SshLinkConnection -Name $Name
        if ($Json) { ConvertTo-Json -InputObject @{ Name = $Name; Reachable = $ok } }
        if (-not $ok) { exit 1 }
    }
    'TestAll' { Show-SshLinkStatusAllTable -Json:$Json }
    'Visualize' {
        if ($Json) { ConvertTo-Json -InputObject @(Get-SshLinkGraph) -Depth 6 } else { Show-SshLinkGraphTree }
    }
    'InstallKey' {
        if (-not $Name) { throw '-Action InstallKey needs -Name.' }
        $ok = Install-SshLinkPublicKey -Name $Name
        if (-not $ok) { exit 1 }
    }
    'Show' {
        if (-not $Name) { throw '-Action Show needs -Name.' }
        Show-SshLinkConnectionDetail -Name $Name -Json:$Json
    }
    'GenerateLauncher' {
        if (-not $Name) { throw '-Action GenerateLauncher needs -Name.' }
        $path = New-SshLinkLauncher -Name $Name -LauncherPath $LauncherPath
        Write-Host "Wrote $path" -ForegroundColor Green
    }
    'Copy' {
        if (-not $Name -or -not $LocalPath -or -not $RemotePath) { throw '-Action Copy needs -Name, -LocalPath and -RemotePath.' }
        Copy-SshLinkFile -Name $Name -LocalPath $LocalPath -RemotePath $RemotePath -ToRemote:$ToRemote
    }
    'Export' {
        if (-not $FilePath) { throw '-Action Export needs -FilePath.' }
        $result = Export-SshLinkConnections -FilePath $FilePath
        Write-Host "Exported $($result.Count) connection(s) to $($result.FilePath)" -ForegroundColor Green
    }
    'Import' {
        if (-not $FilePath) { throw '-Action Import needs -FilePath.' }
        $result = Import-SshLinkConnections -FilePath $FilePath -Force:$Force
        Write-Host "Imported $($result.Added) connection(s), skipped $($result.Skipped.Count)." -ForegroundColor Green
    }
    'CheckUpdate' {
        $check = Test-SshToolkitUpdate
        if ($Json) { $check | ConvertTo-Json; return }
        if ($check.Error) { Write-Host "Couldn't check: $($check.Error)" -ForegroundColor Red; exit 1 }
        if ($check.UpdateAvailable) { Write-Host "Update available: $($check.InstalledVersion) -> $($check.LatestVersion)" -ForegroundColor Yellow }
        else { Write-Host "Up to date ($($check.InstalledVersion))." -ForegroundColor Green }
    }
    'Update' {
        $result = Update-SshToolkit -Force:$Force
        if ($Json) { $result | ConvertTo-Json; return }
        Write-Host $(if ($result.Updated) { "Updated to $($result.Version)." } else { "Not updated: $($result.Reason)." }) -ForegroundColor $(if ($result.Updated) { 'Green' } else { 'Yellow' })
    }
}
