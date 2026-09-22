# Changelog

All notable changes to SSH Toolkit are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-09-22

### Added
- Initial release, as a proper PowerShell module (`SSHToolkit.psd1`/`.psm1`) plus a
  standalone CLI/interactive entry point (`bin/ssh-toolkit.ps1`).
- Connection registry (`~/.ssh-toolkit/connections.json`) backed by a real `~/.ssh/config`
  `Host` block per connection, so a connection works with plain `ssh <name>` and any
  other OpenSSH-config-aware tool without this toolkit installed.
- `Add-SshLinkConnection`, `Set-SshLinkConnection`, `Remove-SshLinkConnection`,
  `Get-SshLinkConnections`/`Get-SshLinkConnection`.
- `Connect-SshLink`, `Test-SshLinkConnection`, `Install-SshLinkPublicKey` (no
  `ssh-copy-id` on Windows), `Copy-SshLinkFile` (`scp` wrapper).
- `Get-SshLinkStatus`/`Get-SshLinkStatusAll`, `Get-SshLinkGraph` (proxy-jump tree with
  live status — the data behind `-Action Visualize`).
- `Export-SshLinkConnections`/`Import-SshLinkConnections`, `New-SshLinkLauncher`
  (a standalone per-connection `Connect-<name>.ps1`).
- SSH multiplexing (`-Multiplex`/`ControlMaster`), local/remote port forwards, tags,
  proxy-jump chains.
- `~/.ssh/config` backed up (last 20 kept) before every change this toolkit makes.
- `Get-SshToolkitVersion`, `Test-SshToolkitUpdate`, `Update-SshToolkit` — version
  checking and in-place self-update (git pull for a git/submodule checkout, release
  archive download otherwise), never touching the connection registry or `~/.ssh/config`.
