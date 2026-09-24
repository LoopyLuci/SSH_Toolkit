# Changelog

All notable changes to SSH Toolkit are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [1.1.0] — 2026-09-23

### Added
- `New-SshLinkKeypair -Name <name>` — generates (or reuses) an ed25519 keypair at
  `~/.ssh/id_ed25519_<name>` without registering a connection for it. Factored out of
  `Add-SshLinkConnection -GenerateKey` for a caller that needs its own public key to hand
  to the other side before it knows enough to register a full connection (e.g. the
  username to log in as, which the other side hasn't said yet).
- `Install-SshLinkTrustedKey -PublicKey <text>` — installs an already-received public key
  into this machine's own trusted keys (the right file for an admin vs. a regular Windows
  account, or `~/.ssh/authorized_keys` elsewhere), with the same ACL lock Windows sshd
  requires. Unlike `Install-SshLinkPublicKey` (which pushes a local key OUT over a real,
  password-prompting SSH session), this installs a key that arrived IN through some other
  already-authenticated channel — no SSH session, no prompt, safe to call unattended.
  Idempotent. Both are exposed through `bin/ssh-toolkit.ps1` as `-Action GenerateKeypair`
  and `-Action InstallTrustedKey`. Built for AgenticBotPlatform's peer-pairing handshake
  (`bot/peers.py`) to exchange and trust SSH keys automatically between two paired
  machines, with no manual key copying.

## [1.0.5] — 2026-09-22

### Fixed
- `bin/ssh-toolkit.ps1 -Action Connect` now propagates the remote command's real exit
  code (`exit $LASTEXITCODE`) — until now a failed remote command, or a connection that
  failed outright, still left the wrapping script's own exit code at 0, so a caller
  checking "did this succeed" by exit code (a script, or another program's own
  wrapper) got a false success.
- Every `ssh`/`scp` call this module makes now passes `-F <its own config file>`
  explicitly, instead of relying on `ssh`/`scp`'s own default `~/.ssh/config`
  resolution. On Windows, Win32-OpenSSH resolves the user's home directory through the
  real Windows user profile, **not** the `$env:USERPROFILE`/`$env:HOME` environment
  variables (confirmed live) — so anything that had reason to run this module with a
  non-default `$HOME` (automated tests, most notably) would silently read/write the
  wrong config file. Real end users on an ordinary single-user machine were never
  affected by this (their `$HOME` already matches their real profile) but the fix
  makes behavior deterministic regardless.
- `Install-SshLinkPublicKey` now connects through the registered alias (honoring
  `ProxyJump` and everything else already in the connection's config entry)
  instead of reconstructing a raw `user@host -p port` target by hand.

## [1.0.4] — 2026-09-22

### Changed
- No functional change — a version bump used to live-verify v1.0.3's
  `Update-SshToolkit` submodule fix actually works end to end (updating a real host
  project's pinned submodule checkout from v1.0.3 to this release), not just that the
  bug it fixed reproduces on older versions.

## [1.0.3] — 2026-09-22

### Fixed
- `Update-SshToolkit`'s git path used `git pull`, which **fails outright** on a git
  submodule checkout — a submodule normally sits at a detached `HEAD` with no tracking
  branch (confirmed live, wiring up a real host project). Now fetches tags and checks
  out the exact latest release tag instead, which works for both a plain clone and a
  submodule, and matches exactly what `Test-SshToolkitUpdate` compared against.

## [1.0.2] — 2026-09-22

### Fixed
- `Test-SshToolkitUpdate`'s `InstalledVersion`/`LatestVersion` now serialize to JSON as
  plain "1.0.2"-style strings, not a `[version]` object's raw Major/Minor/Build struct.

## [1.0.1] — 2026-09-22

### Added
- `bin/ssh-toolkit.ps1 -Action Visualize -Json` — the proxy-jump graph as structured
  JSON (`Get-SshLinkGraph`'s own data), for a program embedding this toolkit to render
  its own visualization instead of parsing the ASCII tree.

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
