# SSH Toolkit

Create, manage, visualize and use named SSH connections between machines — as a
PowerShell **module** you can drop into your own scripts/tools, or as a **fully
standalone tool** with an interactive menu for people and named parameters for scripts
and agents.

A connection you add is saved in this toolkit's own small registry (`~/.ssh-toolkit/`)
**and** written as a real `Host` block into your `~/.ssh/config`. That means once
added, `ssh <name>` (and anything else that reads the standard OpenSSH client config —
VS Code Remote-SSH, WinSCP, git, rsync) works on its own; this toolkit is never a
required dependency to actually connect, only to set one up quickly and manage many of
them.

## Two ways to use it

### 1. As a standalone tool

```powershell
git clone https://github.com/LoopyLuci/SSH_Toolkit.git
cd SSH_Toolkit

# Interactive menu
.\bin\ssh-toolkit.ps1

# Or scripted / agent-driven
.\bin\ssh-toolkit.ps1 -Action Add -Name devbox -HostName 10.0.0.12 -User luci -GenerateKey
.\bin\ssh-toolkit.ps1 -Action Connect -Name devbox -Command "uname -a"
.\bin\ssh-toolkit.ps1 -Action Visualize
.\bin\ssh-toolkit.ps1 -Action List -Json
```

Run `Get-Help .\bin\ssh-toolkit.ps1 -Full` for every action and parameter.

### 2. As a module in your own project

```powershell
Import-Module /path/to/SSH_Toolkit/SSHToolkit.psd1

Add-SshLinkConnection -Name devbox -HostName 10.0.0.12 -User luci -GenerateKey
Get-SshLinkConnections | Where-Object { $_.Tags -match 'prod' }
Test-SshLinkConnection -Name devbox
```

Every function returns a real object (never just printed text), so you can build your
own UI, dashboard, or automation on top — see **Functions** below, and
`Get-SshLinkGraph` in particular, which is the exact data `-Action Visualize` renders,
exposed so another program can render it its own way.

**Adding it to another project**, three ways, in increasing order of "stays in sync
with upstream":

- **Vendor a copy** — just copy this folder in. Simplest; you own the copy and its updates.
- **Git submodule** (recommended for most projects):
  ```bash
  git submodule add https://github.com/LoopyLuci/SSH_Toolkit.git vendor/ssh-toolkit
  ```
  `Update-SshToolkit` (below) detects a submodule checkout and updates it in place.
- **Sidecar process** — run `bin/ssh-toolkit.ps1` as a separate installed tool and call
  it from any language via subprocess + `-Json` output; no PowerShell module loading
  needed in the host project at all. This is how
  [AgenticBotPlatform](https://github.com/LoopyLuci/AgenticBotPlatform) integrates it
  (Python calling out to the module's CLI).

## Staying up to date

```powershell
Test-SshToolkitUpdate      # check only, never changes anything
Update-SshToolkit          # apply if an update is available
Update-SshToolkit -Force   # re-apply even if already up to date
```

`Update-SshToolkit` detects how it was installed and does the right thing: for a git
checkout (a plain clone, or a submodule of a host project — which normally sits at a
detached `HEAD` with no tracking branch, where a plain `git pull` fails outright) it
fetches and checks out the exact latest **release tag**, so "updated" always means
"now at the version `Test-SshToolkitUpdate` reported". For a plain downloaded copy (no
`.git` at all) it downloads and extracts the latest release archive in place. Either
way, it only ever touches the toolkit's **own** files — your `~/.ssh-toolkit` registry
and `~/.ssh/config` are never touched by an update.

A host project that wants **automatic** update checks (e.g. "check weekly, notify but
don't apply" or "check and auto-apply") should call `Test-SshToolkitUpdate`/
`Update-SshToolkit` from its own scheduler and decide what "automatic" means for its
own users — this toolkit deliberately never schedules anything on its own or phones
home unasked; every check is a single call you make when you choose to.

## Functions

| Function | What it does |
| --- | --- |
| `Add-SshLinkConnection` | Register a new connection; writes the `~/.ssh/config` block too |
| `Set-SshLinkConnection` | Update only the fields you pass on an existing connection |
| `Remove-SshLinkConnection` | Remove a connection (never deletes key files) |
| `Get-SshLinkConnections` / `Get-SshLinkConnection` | List all / get one |
| `Connect-SshLink` | Open an interactive session, or run one remote command |
| `Test-SshLinkConnection` | A quick reachable+authenticated check (never throws for a dead host) |
| `Get-SshLinkStatus` / `Get-SshLinkStatusAll` | Reachability for one / every connection |
| `Get-SshLinkGraph` | Every connection as a tree by proxy-jump chain, with live status — the data behind `-Action Visualize` |
| `Install-SshLinkPublicKey` | Put a connection's public key on the remote (there's no `ssh-copy-id` on Windows) |
| `Copy-SshLinkFile` | `scp` wrapper, either direction |
| `Export-SshLinkConnections` / `Import-SshLinkConnections` | Back up / restore the whole registry (key paths only, not key files) |
| `New-SshLinkLauncher` | A standalone `Connect-<name>.ps1` that works without this toolkit at all |
| `Get-SshToolkitVersion` / `Test-SshToolkitUpdate` / `Update-SshToolkit` | Version and self-update |

## Features

- Real SSH multiplexing (`-Multiplex`, `ControlMaster`) for fast repeated connections
- Local/remote port forwards (`-LocalForward` / `-RemoteForward`)
- Proxy-jump chains (reach a machine only visible through another one you've registered)
- Tags, for grouping in the visualize view
- `~/.ssh/config` is backed up (last 20 kept) before every change this toolkit makes
- Every registry write is atomic JSON; nothing here ever stores a private key itself,
  only a path to one

## Gotchas (real PowerShell behavior, not this toolkit's bugs)

- **Always wrap list-returning calls in `@()`** when you need array semantics —
  `@(Get-SshLinkConnections).Count`, not `(Get-SshLinkConnections).Count`. With exactly
  one connection registered, PowerShell hands back a bare object instead of a
  1-element array on direct assignment (`$x = Get-SshLinkConnections`) — the exact same
  behavior `Get-ChildItem`/`Get-Process` have. Piping (`Get-SshLinkConnections |
  Where-Object {...}`) is unaffected either way.
- Windows has no `ssh-copy-id` — `Install-SshLinkPublicKey` replicates it (asks for the
  remote's password once, a real OpenSSH prompt).

## Requirements

Windows PowerShell 5.1+ or PowerShell 7+, and OpenSSH's client (`ssh`, `scp`,
`ssh-keygen` — built into Windows 10/11, or install the "OpenSSH Client" optional
feature).

## Contributing

No CI/Pester suite is set up yet — `tests/smoke_test.ps1` is a fast end-to-end sanity
check (isolated fake `$HOME`, never touches your real `~/.ssh`); run it before opening
a PR:

```powershell
.\tests\smoke_test.ps1
```

## License

MIT — see [LICENSE](LICENSE).
