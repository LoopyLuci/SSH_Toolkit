<#
SSHToolkit - the module. Import this directly (`Import-Module SSHToolkit`) to use every
function below from your own scripts/tools, or run `bin/ssh-toolkit.ps1` for the
standalone interactive menu / CLI wrapper around the same functions - see README.md.

Everything here is intentionally free of any dependency on how it's invoked: no
Read-Host, no Write-Host-only return values, every function returns real objects so a
caller (a script, another module, or a CI pipeline) can consume them programmatically.
The interactive menu and the -Action dispatcher both live in bin/ssh-toolkit.ps1, on
top of this module, not mixed into it.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------- storage ----

$script:StoreDir  = Join-Path $HOME '.ssh-toolkit'
$script:StorePath = Join-Path $script:StoreDir 'connections.json'
$script:SshDir    = Join-Path $HOME '.ssh'
$script:SshConfig = Join-Path $script:SshDir 'config'

function Initialize-SshLinkStore {
    <#
    .SYNOPSIS
        Ensures the toolkit's own storage folder, ~/.ssh, and ~/.ssh/config all exist.
        Called automatically by every function that reads or writes them - you don't
        need to call this yourself.
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:StoreDir))  { New-Item -ItemType Directory -Path $script:StoreDir -Force | Out-Null }
    if (-not (Test-Path $script:SshDir))    { New-Item -ItemType Directory -Path $script:SshDir -Force | Out-Null }
    if (-not (Test-Path $script:SshConfig)) { New-Item -ItemType File -Path $script:SshConfig -Force | Out-Null }
    if (-not (Test-Path $script:StorePath)) { '[]' | Set-Content -Path $script:StorePath -Encoding utf8 }
}

function Get-SshLinkConnections {
    <#
    .SYNOPSIS
        Every registered connection, as an array (always an array, even with 0 or 1 entries).
    #>
    [CmdletBinding()]
    param()
    Initialize-SshLinkStore
    $raw = Get-Content -Path $script:StorePath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    # NOT `@(Get-Content ... | ConvertFrom-Json)` as one expression - PowerShell's
    # ConvertFrom-Json returns a multi-item JSON array as one already-array pipeline
    # object, and wrapping THAT directly in @() re-wraps it into a 1-element array
    # holding the whole array (confirmed live, both Windows PowerShell 5.1 and pwsh 7).
    # Assigning to a variable first avoids it.
    $data = $raw | ConvertFrom-Json
    if ($null -eq $data) { return @() }
    # This returns an array, but PowerShell still unrolls it one element at a time down
    # the pipeline/return channel (standard behavior - the same thing Get-ChildItem,
    # Get-Process etc. all do) - with exactly ONE connection registered, a caller who
    # writes `$x = Get-SshLinkConnections` (no @()) gets back a bare object, not a
    # 1-element array (confirmed live). This is normal, well-known PowerShell behavior,
    # not a bug to work around with -NoEnumerate here - that would instead break every
    # internal `Get-SshLinkConnections | Where-Object {...}` call in this module (also
    # confirmed live: -NoEnumerate stops the very next pipeline stage from seeing
    # individual elements at all, including an always-empty array). The fix belongs on
    # the CALLER: always write `@(Get-SshLinkConnections)` when you need guaranteed
    # array semantics (.Count, indexing) - documented in README.md's Gotchas section.
    return @($data)
}

function Save-SshLinkConnections {
    <#
    .SYNOPSIS
        Overwrites the whole connection registry. Internal - callers should use
        Add-SshLinkConnection / Set-SshLinkConnection / Remove-SshLinkConnection instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Connections)
    Initialize-SshLinkStore
    ConvertTo-Json -InputObject @($Connections) -Depth 6 | Set-Content -Path $script:StorePath -Encoding utf8
}

function Get-SshLinkConnection {
    <#
    .SYNOPSIS
        One connection by name, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    (Get-SshLinkConnections) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

# ---------------------------------------------------------- ssh config block ----
# Each connection's Host block is wrapped in its own marker comments so it can be
# found and replaced/removed precisely, without disturbing any Host blocks you (or
# another tool) already have in ~/.ssh/config.

function Get-SshConfigBlockText {
    [CmdletBinding()]
    param($Connection)
    $lines = @("# >>> ssh-toolkit:$($Connection.Name) >>>")
    $lines += "Host $($Connection.Name)"
    $lines += "    HostName $($Connection.HostName)"
    $lines += "    Port $($Connection.Port)"
    if ($Connection.User)         { $lines += "    User $($Connection.User)" }
    if ($Connection.IdentityFile) { $lines += "    IdentityFile $($Connection.IdentityFile)" }
    if ($Connection.ProxyJump)    { $lines += "    ProxyJump $($Connection.ProxyJump)" }
    if ($Connection.Multiplex) {
        # One shared background master connection per Name; later connects reuse it
        # instead of paying the TCP+auth cost again. ControlPath lives under the
        # toolkit's own folder so it never collides with sockets from other tools.
        $controlDir = Join-Path $script:StoreDir 'control'
        $lines += "    ControlMaster auto"
        $lines += "    ControlPath $(Join-Path $controlDir '%r@%h-%p')"
        $lines += "    ControlPersist 10m"
    }
    foreach ($fwd in @($Connection.LocalForward))  { if ($fwd) { $lines += "    LocalForward $fwd" } }
    foreach ($fwd in @($Connection.RemoteForward)) { if ($fwd) { $lines += "    RemoteForward $fwd" } }
    $lines += '    IdentitiesOnly yes'
    $lines += "# <<< ssh-toolkit:$($Connection.Name) <<<"
    return ($lines -join "`r`n")
}

function Backup-SshConfigFile {
    <#
    .SYNOPSIS
        A timestamped copy of ~/.ssh/config before this toolkit changes it - that file is
        sensitive and easy to break by hand, and this toolkit is not the only thing that
        may have written to it. Keeps the last 20 backups.
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:SshConfig)) { return }
    $backupDir = Join-Path $script:StoreDir 'config-backups'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -Path $script:SshConfig -Destination (Join-Path $backupDir "config.$stamp") -Force
    Get-ChildItem $backupDir -Filter 'config.*' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Set-SshConfigBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Connection)
    Backup-SshConfigFile
    $content = if (Test-Path $script:SshConfig) { Get-Content -Path $script:SshConfig -Raw } else { '' }
    if ($null -eq $content) { $content = '' }
    $startTag = "# >>> ssh-toolkit:$($Connection.Name) >>>"
    $endTag   = "# <<< ssh-toolkit:$($Connection.Name) <<<"
    $block = Get-SshConfigBlockText -Connection $Connection
    if ($content -match [regex]::Escape($startTag)) {
        $pattern = "(?s)" + [regex]::Escape($startTag) + ".*?" + [regex]::Escape($endTag)
        # A MatchEvaluator delegate, not a replacement-pattern string - the block text can
        # itself contain "$" (a Notes/path field could), which .NET's string-replacement
        # syntax would otherwise reinterpret as a backreference.
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block }
        $content = [regex]::Replace($content, $pattern, $evaluator)
    }
    else {
        if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { $content += "`r`n" }
        $content += "`r`n$block`r`n"
    }
    Set-Content -Path $script:SshConfig -Value $content -Encoding utf8
}

function Remove-SshConfigBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path $script:SshConfig)) { return }
    Backup-SshConfigFile
    $content = Get-Content -Path $script:SshConfig -Raw
    $startTag = "# >>> ssh-toolkit:$Name >>>"
    $endTag   = "# <<< ssh-toolkit:$Name <<<"
    if ($content -notmatch [regex]::Escape($startTag)) { return }
    $pattern = "(?s)\r?\n?" + [regex]::Escape($startTag) + ".*?" + [regex]::Escape($endTag) + "\r?\n?"
    $content = [regex]::Replace($content, $pattern, "`r`n")
    Set-Content -Path $script:SshConfig -Value $content -Encoding utf8
}

# ------------------------------------------------------------------- actions ----

function Add-SshLinkConnection {
    <#
    .SYNOPSIS
        Registers a new SSH connection: saves it in the toolkit's own registry AND
        writes a real Host block into ~/.ssh/config, so `ssh <Name>` works standalone
        (VS Code Remote-SSH, WinSCP, git, anything that reads the OpenSSH client config)
        without needing this toolkit at all afterward.
    .EXAMPLE
        Add-SshLinkConnection -Name devbox -HostName 10.0.0.12 -User luci -GenerateKey
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 22,
        [string]$User,
        [string]$IdentityFile,
        [switch]$GenerateKey,
        [string]$ProxyJump,
        [string]$Notes,
        [switch]$Force,
        [string]$LauncherPath,
        [switch]$Multiplex,
        [string[]]$LocalForward,
        [string[]]$RemoteForward,
        [string]$Tags
    )
    $existing = Get-SshLinkConnection -Name $Name
    if ($existing -and -not $Force) {
        throw "A connection named '$Name' already exists. Pass -Force to overwrite it, or use Set-SshLinkConnection to change just some fields."
    }
    if ($GenerateKey -and -not $IdentityFile) {
        $IdentityFile = Join-Path $script:SshDir "id_ed25519_$Name"
        if (-not (Test-Path $IdentityFile)) {
            Write-Verbose "Generating a new ed25519 keypair at $IdentityFile ..."
            & ssh-keygen -t ed25519 -f $IdentityFile -N '""' -C "ssh-toolkit:$Name" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed (exit $LASTEXITCODE)." }
        }
        else {
            Write-Verbose "Key already exists at $IdentityFile - reusing it."
        }
    }
    $conn = [pscustomobject]@{
        Name          = $Name
        HostName      = $HostName
        Port          = $Port
        User          = $User
        IdentityFile  = $IdentityFile
        ProxyJump     = $ProxyJump
        Notes         = $Notes
        Multiplex     = [bool]$Multiplex
        LocalForward  = @($LocalForward  | Where-Object { $_ })
        RemoteForward = @($RemoteForward | Where-Object { $_ })
        Tags          = $Tags
        CreatedAt     = (Get-Date).ToString('o')
    }
    $all = @(Get-SshLinkConnections | Where-Object { $_.Name -ne $Name })
    $all += $conn
    Save-SshLinkConnections -Connections $all
    Set-SshConfigBlock -Connection $conn
    $launcher = New-SshLinkLauncher -Name $Name -LauncherPath $LauncherPath
    $conn | Add-Member -NotePropertyName LauncherPath -NotePropertyValue $launcher -PassThru
}

function Set-SshLinkConnection {
    <#
    .SYNOPSIS
        Updates only the fields you actually pass on an existing connection - a field
        you don't mention is left exactly as it was (never silently blanked).
    .EXAMPLE
        Set-SshLinkConnection -Name devbox -Multiplex -LocalForward "8080:localhost:80"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$HostName,
        [Nullable[int]]$Port,
        [string]$User,
        [string]$IdentityFile,
        [string]$ProxyJump,
        [string]$Notes,
        [Nullable[bool]]$Multiplex,
        [string[]]$LocalForward,
        [string[]]$RemoteForward,
        [string]$Tags
    )
    $conn = Get-SshLinkConnection -Name $Name
    if (-not $conn) { throw "No connection named '$Name'. Use Add-SshLinkConnection to create it first." }
    foreach ($field in 'HostName', 'Port', 'User', 'IdentityFile', 'ProxyJump', 'Notes', 'Multiplex', 'Tags') {
        if ($PSBoundParameters.ContainsKey($field)) {
            $conn.$field = (Get-Variable -Name $field -ValueOnly)
        }
    }
    if ($PSBoundParameters.ContainsKey('LocalForward'))  { $conn.LocalForward  = @($LocalForward  | Where-Object { $_ }) }
    if ($PSBoundParameters.ContainsKey('RemoteForward')) { $conn.RemoteForward = @($RemoteForward | Where-Object { $_ }) }
    $all = @(Get-SshLinkConnections | Where-Object { $_.Name -ne $Name })
    $all += $conn
    Save-SshLinkConnections -Connections $all
    Set-SshConfigBlock -Connection $conn
    return $conn
}

function New-SshLinkLauncher {
    <#
    .SYNOPSIS
        Writes a tiny standalone Connect-<Name>.ps1 script that just runs `ssh <Name>` -
        safe to copy anywhere, hand to a teammate, or have another program/agent call
        directly without knowing this toolkit exists (it only needs the ~/.ssh/config
        entry, which Add-SshLinkConnection already wrote).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$LauncherPath)
    $folder = if ($LauncherPath) { $LauncherPath } else { $script:StoreDir }
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $file = Join-Path $folder "Connect-$Name.ps1"
    @"
# Standalone launcher generated by SSHToolkit - safe to copy anywhere, or hand to
# another user/agent/program. Needs only that this machine's OpenSSH client and the
# '$Name' entry in ~\.ssh\config exist; does not need SSHToolkit itself.
#
# Usage:
#   .\Connect-$Name.ps1                 opens an interactive session
#   .\Connect-$Name.ps1 "some command"  runs one remote command and exits
param([Parameter(ValueFromRemainingArguments)][string[]]`$Command)
if (`$Command) { & ssh $Name (`$Command -join ' ') } else { & ssh $Name }
"@ | Set-Content -Path $file -Encoding utf8
    return $file
}

function Remove-SshLinkConnection {
    <#
    .SYNOPSIS
        Removes a connection from the registry and its Host block from ~/.ssh/config.
        Key FILES are never deleted - only the registry entry and config block.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [switch]$Force)
    $conn = Get-SshLinkConnection -Name $Name
    if (-not $conn) { throw "No connection named '$Name'." }
    if (-not $Force -and -not $PSCmdlet.ShouldProcess($Name, 'Remove SSH connection')) { return }
    $all = @(Get-SshLinkConnections | Where-Object { $_.Name -ne $Name })
    Save-SshLinkConnections -Connections $all
    Remove-SshConfigBlock -Name $Name
    $launcher = Join-Path $script:StoreDir "Connect-$Name.ps1"
    if (Test-Path $launcher) { Remove-Item $launcher -Force }
}

function Connect-SshLink {
    <#
    .SYNOPSIS
        Opens an interactive session (or runs one remote Command and returns) for a
        registered connection.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Command)
    $conn = Get-SshLinkConnection -Name $Name
    if (-not $conn) { throw "No connection named '$Name'. Run Get-SshLinkConnections to see what's registered." }
    if ($Command) { & ssh $Name $Command } else { & ssh $Name }
}

function Test-SshLinkConnection {
    <#
    .SYNOPSIS
        A quick, short-timeout reachability+auth check. Never throws for a dead/
        unreachable machine - that's a normal, expected result, returned as $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSeconds = 8)
    $conn = Get-SshLinkConnection -Name $Name
    if (-not $conn) { throw "No connection named '$Name'." }
    $output = & ssh -o BatchMode=yes -o ConnectTimeout=$TimeoutSeconds $Name 'echo SSH_TOOLKIT_OK' 2>&1
    return ($LASTEXITCODE -eq 0) -and ($output -match 'SSH_TOOLKIT_OK')
}

function Install-SshLinkPublicKey {
    <#
    .SYNOPSIS
        Installs a connection's public key into the remote's authorized_keys, for
        password-less login afterward. Asks for the remote's password once (real
        OpenSSH prompt) - there is no ssh-copy-id on Windows, so this replicates it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $conn = Get-SshLinkConnection -Name $Name
    if (-not $conn) { throw "No connection named '$Name'." }
    if (-not $conn.IdentityFile) { throw "'$Name' has no IdentityFile set - nothing to install." }
    $pub = "$($conn.IdentityFile).pub"
    if (-not (Test-Path $pub)) { throw "Public key not found at $pub." }
    $keyText = (Get-Content -Path $pub -Raw).Trim()
    $remoteCmd = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$keyText' ~/.ssh/authorized_keys || echo '$keyText' >> ~/.ssh/authorized_keys; echo INSTALLED"
    $target = if ($conn.User) { "$($conn.User)@$($conn.HostName)" } else { $conn.HostName }
    & ssh -p $conn.Port $target $remoteCmd
    return $LASTEXITCODE -eq 0
}

function Get-SshLinkStatus {
    <#
    .SYNOPSIS
        Reachability status for one connection object (as returned by
        Get-SshLinkConnections), for building your own dashboards/health checks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Connection, [int]$TimeoutSeconds = 5)
    try {
        $null = & ssh -o BatchMode=yes -o ConnectTimeout=$TimeoutSeconds $Connection.Name 'exit 0' 2>&1
        return [pscustomobject]@{ Name = $Connection.Name; Reachable = ($LASTEXITCODE -eq 0); ExitCode = $LASTEXITCODE }
    }
    catch {
        return [pscustomobject]@{ Name = $Connection.Name; Reachable = $false; ExitCode = -1 }
    }
}

function Get-SshLinkStatusAll {
    <#
    .SYNOPSIS
        Get-SshLinkStatus for every registered connection - a health-check sweep.
    #>
    [CmdletBinding()]
    param()
    # Wrap in @() when you need guaranteed array semantics - see Get-SshLinkConnections'
    # own comment on why (single-item pipeline unrolling is normal PowerShell behavior).
    foreach ($c in (Get-SshLinkConnections)) {
        $status = Get-SshLinkStatus -Connection $c
        [pscustomobject]@{ Name = $c.Name; Target = "$($c.User)@$($c.HostName):$($c.Port)"; ProxyJump = $c.ProxyJump; Reachable = $status.Reachable }
    }
}

function Get-SshLinkGraph {
    <#
    .SYNOPSIS
        Every connection as a flat list of {Connection, Depth, Reachable}, ordered so a
        caller can render an indented tree by ProxyJump chain - the data behind
        ssh-toolkit.ps1's -Action Visualize, exposed here for any other UI to reuse
        (a GUI, a web page, ABP's own TUI/dashboard).
    #>
    [CmdletBinding()]
    param()
    $all = @(Get-SshLinkConnections)
    $byName = @{}
    foreach ($c in $all) { $byName[$c.Name] = $c }
    $childrenOf = @{}
    foreach ($c in $all) {
        $parent = if ($c.ProxyJump -and $byName.ContainsKey($c.ProxyJump)) { $c.ProxyJump } else { '' }
        if (-not $childrenOf.ContainsKey($parent)) { $childrenOf[$parent] = @() }
        $childrenOf[$parent] += $c
    }
    function Walk {
        param([string]$ParentKey, [int]$Depth)
        foreach ($c in ($childrenOf[$ParentKey] | Sort-Object Name)) {
            $status = Get-SshLinkStatus -Connection $c -TimeoutSeconds 3
            [pscustomobject]@{ Connection = $c; Depth = $Depth; Reachable = $status.Reachable }
            if ($childrenOf.ContainsKey($c.Name)) { Walk -ParentKey $c.Name -Depth ($Depth + 1) }
        }
    }
    Walk -ParentKey '' -Depth 0
}

function Export-SshLinkConnections {
    <#
    .SYNOPSIS
        Writes every registered connection to a JSON file - a backup, or a way to move
        your connection set to another machine. Private key FILES are never included,
        only their paths.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    $all = Get-SshLinkConnections
    ConvertTo-Json -InputObject @($all) -Depth 6 | Set-Content -Path $FilePath -Encoding utf8
    return [pscustomobject]@{ FilePath = $FilePath; Count = $all.Count }
}

function Import-SshLinkConnections {
    <#
    .SYNOPSIS
        Reads connections from a file written by Export-SshLinkConnections and adds
        them (skips a name that already exists, unless -Force).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath, [switch]$Force)
    if (-not (Test-Path $FilePath)) { throw "File not found: $FilePath" }
    $rawJson = Get-Content -Path $FilePath -Raw
    $parsed = $rawJson | ConvertFrom-Json
    $incoming = @($parsed)
    $existingNames = (Get-SshLinkConnections).Name
    $added = 0; $skipped = @()
    foreach ($c in $incoming) {
        if (($existingNames -contains $c.Name) -and -not $Force) {
            $skipped += $c.Name
            continue
        }
        Add-SshLinkConnection -Name $c.Name -HostName $c.HostName -Port $c.Port -User $c.User `
            -IdentityFile $c.IdentityFile -ProxyJump $c.ProxyJump -Notes $c.Notes -Tags $c.Tags `
            -Multiplex:([bool]$c.Multiplex) -LocalForward @($c.LocalForward) -RemoteForward @($c.RemoteForward) `
            -Force:$Force | Out-Null
        $added++
    }
    return [pscustomobject]@{ Added = $added; Skipped = $skipped }
}

function Copy-SshLinkFile {
    <#
    .SYNOPSIS
        scp wrapper for a registered connection - copy a file/folder to or from the
        other machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemotePath,
        [switch]$ToRemote
    )
    $conn = Get-SshLinkConnection -Name $Name
    if (-not $conn) { throw "No connection named '$Name'." }
    $remoteSpec = "${Name}:$RemotePath"
    if ($ToRemote) { & scp -r $LocalPath $remoteSpec } else { & scp -r $remoteSpec $LocalPath }
    if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)." }
}

# --------------------------------------------------------------------- update ----

function Get-SshToolkitVersion {
    <#
    .SYNOPSIS
        The installed module's version (from its manifest).
    #>
    [CmdletBinding()]
    param()
    (Get-Module SSHToolkit).Version
}

function Find-SshToolkitRoot {
    # The module's own folder (where SSHToolkit.psd1 lives), for the update functions -
    # not exported, purely internal plumbing.
    Split-Path -Parent $PSScriptRoot 2>$null | Out-Null
    $PSScriptRoot
}

function Test-SshToolkitUpdate {
    <#
    .SYNOPSIS
        Checks the public GitHub repo's latest release against the installed version.
        Never applies anything - see Update-SshToolkit for that.
    .OUTPUTS
        A [pscustomobject] with InstalledVersion, LatestVersion, UpdateAvailable,
        ReleaseUrl - or a clear error if GitHub can't be reached (never throws for that;
        an update check failing is not a reason to break whatever called it).
    #>
    [CmdletBinding()]
    param([string]$Repo = 'LoopyLuci/SSH_Toolkit')
    $installed = Get-SshToolkitVersion
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'SSHToolkit' } -TimeoutSec 10
        $latestTag = $release.tag_name.TrimStart('v')
        $latest = [version]$latestTag
        return [pscustomobject]@{
            InstalledVersion = $installed
            LatestVersion    = $latest
            UpdateAvailable  = ($latest -gt $installed)
            ReleaseUrl       = $release.html_url
            Error            = $null
        }
    }
    catch {
        return [pscustomobject]@{
            InstalledVersion = $installed; LatestVersion = $null; UpdateAvailable = $false
            ReleaseUrl = $null; Error = $_.Exception.Message
        }
    }
}

function Update-SshToolkit {
    <#
    .SYNOPSIS
        Applies an available update in place. If the module's own folder is a git
        checkout (a plain clone, or a git submodule of a host project), runs `git pull`
        (or `git submodule update --remote` when it detects it's a submodule) - the
        normal way a host project would track this toolkit. Otherwise (a plain
        downloaded copy) downloads and extracts the latest release archive over the
        current files, leaving your ~/.ssh-toolkit registry and ~/.ssh/config untouched
        either way (this only ever replaces the toolkit's OWN files).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Repo = 'LoopyLuci/SSH_Toolkit', [switch]$Force)
    $root = $PSScriptRoot
    $check = Test-SshToolkitUpdate -Repo $Repo
    if ($check.Error) { throw "Couldn't check for updates: $($check.Error)" }
    if (-not $check.UpdateAvailable -and -not $Force) {
        return [pscustomobject]@{ Updated = $false; Reason = 'already up to date'; Version = $check.InstalledVersion }
    }
    if (-not $PSCmdlet.ShouldProcess($root, "Update SSHToolkit to $($check.LatestVersion)")) {
        return [pscustomobject]@{ Updated = $false; Reason = 'cancelled'; Version = $check.InstalledVersion }
    }
    $isGit = Test-Path (Join-Path $root '.git')
    if ($isGit) {
        Push-Location $root
        try {
            & git rev-parse --is-inside-work-tree *> $null
            if ($LASTEXITCODE -ne 0) { throw 'not a git working tree' }
            & git pull --ff-only 2>&1 | Out-String | Write-Verbose
            if ($LASTEXITCODE -ne 0) { throw "git pull failed (exit $LASTEXITCODE) - resolve manually" }
        }
        finally { Pop-Location }
    }
    else {
        $zipUrl = "https://github.com/$Repo/archive/refs/tags/v$($check.LatestVersion).zip"
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sshtoolkit-update-$([guid]::NewGuid()).zip"
        Invoke-WebRequest -Uri $zipUrl -OutFile $tmp -UseBasicParsing
        $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) "sshtoolkit-update-$([guid]::NewGuid())"
        Expand-Archive -Path $tmp -DestinationPath $extractDir
        $inner = Get-ChildItem $extractDir -Directory | Select-Object -First 1
        Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $root -Recurse -Force
        Remove-Item $tmp, $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Updated = $true; Version = $check.LatestVersion }
}

Export-ModuleMember -Function @(
    'Initialize-SshLinkStore', 'Get-SshLinkConnections', 'Get-SshLinkConnection',
    'Add-SshLinkConnection', 'Set-SshLinkConnection', 'Remove-SshLinkConnection',
    'New-SshLinkLauncher', 'Connect-SshLink', 'Test-SshLinkConnection',
    'Install-SshLinkPublicKey', 'Get-SshLinkStatus', 'Get-SshLinkStatusAll', 'Get-SshLinkGraph',
    'Export-SshLinkConnections', 'Import-SshLinkConnections', 'Copy-SshLinkFile',
    'Get-SshConfigBlockText', 'Get-SshToolkitVersion', 'Test-SshToolkitUpdate', 'Update-SshToolkit'
)
