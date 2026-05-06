# AD Manager

[![GitHub release](https://img.shields.io/badge/version-2.1-blue?style=flat-square)](https://github.com/karanikn/AD_Manager)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x-blue?style=flat-square&logo=powershell)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11%20%7C%20Server-lightgrey?style=flat-square&logo=windows)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/license-GPL--3.0-green?style=flat-square)](LICENSE)
[![AI Assisted](https://img.shields.io/badge/built%20with-Claude%20AI-orange?style=flat-square&logo=anthropic)](https://claude.ai)

> **All-in-one Active Directory management tool built as a WPF GUI in PowerShell.**  
> Manage users, computers, groups, GPOs, shares, DNS, DHCP, and more — from a single, polished interface.

---

## Screenshots

*Screenshots coming soon.*

---

## Overview

**AD Manager** is a professional Active Directory administration tool built entirely in PowerShell with a WPF GUI. It provides a unified, tabbed interface for the most common — and not so common — AD management tasks, without needing to open ADUC, DNS Manager, DHCP Console, or Group Policy Management separately.

Designed for **IT administrators and sysadmins** managing Windows Server domains.

---

## Quick Launch

```powershell
# Run as Administrator
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ".\AD_Manager.ps1"
```

The script auto-elevates to Administrator and forces STA mode if not already set.

---

## Requirements

| Component | Details |
|-----------|---------|
| PowerShell | 5.1+ (STA mode — auto-launched) |
| RSAT | ActiveDirectory module (required) |
| RSAT | GroupPolicy module (required) |
| RSAT | DnsServer module (optional — DNS Zones tab) |
| RSAT | DhcpServer module (optional — DHCP tab) |
| OS | Windows 10/11 or Windows Server 2012 R2+ |
| Permissions | Domain Admin or equivalent |

---

## Interface

19 tabs covering all major AD administration areas. All long-running operations (NTFS scanning, network scanning) run in background runspaces — the UI stays responsive at all times.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| F5 | Refresh current tab |
| Ctrl+E | Export CSV for current tab |
| Ctrl+F | Focus live filter (Users tab) |

### Theme

Click the sun/moon icon (top right) to toggle Dark / Light mode.

---

## Tabs

### System
Live hardware info for the local machine: OS version, CPU load, RAM (free/total), disk usage per drive.

### Domain
Domain and Forest info, functional levels, Domain SID, FSMO role holders, Domain Controllers grid.

**Last Logon Activity Heatmap** — groups all enabled users by days since last logon into 7 color-coded tiles. Click any tile to see the user list inline (no popup window).

### OU Tree
Hierarchical TreeView of all Organizational Units. Right-click a node to:
- Copy OU path to clipboard
- Load users from that OU (shows popup with usernames)

### Shares
All local shares with Name, Path, Type, MaxAllowed.

**NTFS Permission Scanner** — find which user or group has access to what:

| Option | Default | Description |
|--------|---------|-------------|
| Depth | 2 | Subfolder levels to scan (0=root only, max 6) |
| Skip system folders | On | Skips $Recycle.Bin, System Volume Information, DfsrPrivate, etc. |
| Skip admin shares | On | Skips shares ending in $ (ADMIN$, C$, IPC$, PRINT$, etc.) |
| Warn at 1000+ results | On | Shows Yes/No dialog before continuing large scans |
| Stop button | visible during scan | Cancels between shares |

### Users
Full AD user list with live inline filter.

| Feature | Details |
|---------|---------|
| Live filter | Filters across Username, DisplayName, Email, Department, Title as you type — no reload |
| Export CSV | UTF-8 encoded |
| Export XLSX | Requires ImportExcel module; falls back to UTF-8 BOM CSV |
| Enable / Disable | Multi-select with confirmation dialog showing affected usernames |
| Reset Password | With confirmation; optional force-change-at-next-logon |
| Unlock | Clears lockout flag |
| Member-Of | Shows group membership for selected user |
| Heatmap | Last logon heatmap panel (same as Domain tab, inline) |
| User Details | Right-click -> "Show user details..." -> console panel with all AD attributes + Copy all |
| Copy cell / row | Right-click context menu |
| Row count | "Found 247 users" label, updates with live filter |

### Groups
All AD groups with optional nested member expansion. Filter, Export CSV. Right-click to copy cell/row. Row count label.

### Computers
All AD computer accounts. Filter, Export CSV. Right-click to copy.

**Last Logon Heatmap** button — same tile system as Domain/Users tabs, for computers. Click tile to see computer list inline.

### GPOs
All Group Policy Objects. Separate **GPO Link Viewer** showing which GPO is linked to which OU.

### Pwd Expiry
Users whose password expires within N days (default 30). Configurable. Export CSV.

### Inactive
Users and computers with no logon in N days (default 90). Separate grids. Export CSV.

### Recycle Bin
Deleted AD objects. Requires AD Recycle Bin feature enabled in the domain.

### DNS Zones
DNS zones and resource records. Requires DnsServer RSAT module.

### DHCP
DHCP scopes and active leases. Requires DhcpServer RSAT module.

### Stale PCs
Computers whose machine account password has not changed in N days. Configurable threshold.

### Group Diff
Compare group memberships between two AD users. Shows groups unique to each and common groups. Export CSV.

### AD Health
Automated domain health check covering:
- Domain reachability (Get-ADDomain)
- DC ping and LDAP port 389 per DC
- Replication status (repadmin /showrepl)
- SYSVOL and NETLOGON share accessibility
- Default domain password policy
- Locked-out account count
- Disabled DC detection

### Net Status
Network scanner for all enabled domain computers. Parallel scanning via RunspacePool.

| Column | Description |
|--------|-------------|
| Status | Online / Offline |
| Name | Computer name |
| IP | Resolved IP |
| RTT | Ping round-trip time |
| OS | Operating system |
| DNSHost | FQDN |
| LastLogon | Last AD logon date |
| LastUserLogon | Last user who logged on |
| Uptime | Days since last reboot |
| FreeRAM | Free / Total physical memory |
| FreeDisk | Free / Total per drive |

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| Timeout (ms) | 30 | Ping timeout per computer |
| Retries | 0 | Ping retry count on failure |
| Threads | 20 | Parallel threads (1-50) — main speed control |
| Online only | On | Skip offline computers in results |
| WMI | - | Uptime/RAM/Disk via DCOM (port 135). Works on Servers by default. |
| PSRemoting | - | WinRM fallback (port 5985) when WMI fails. |
| RemoteReg | - | Last logged-on user via Remote Registry service. |

**Get Computers button** — loads the AD computer list as a scrollable checklist. Check/uncheck individual machines before scanning. Useful for targeting only servers, or only specific computers.

**Right-click on result:** Copy cell, Copy row, Ping continuous (`cmd /k ping -t`), RDP connect (`mstsc /v:`).

**Enabling WMI on workstations via GPO:**
```
Computer Configuration -> Windows Defender Firewall -> Inbound Rules
Enable: Windows Management Instrumentation (WMI-In, DCOM-In, ASync-In)
```
Or per machine:
```powershell
Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)"
```

**Enabling Remote Registry via GPO:**
```
Computer Configuration -> Security Settings -> System Services
Remote Registry -> Automatic (Started)
```

**Enabling PSRemoting:**
```powershell
Enable-PSRemoting -Force
```

### Output
Console-style live log (green-on-black, Consolas). Every PowerShell cmdlet executed is logged here. Auto-scroll toggle, Save, Clear.

### Log
Timestamped session log with INFO/OK/WARN/ERROR levels. Save to file.

---

## Menu

### File
| Item | Action |
|------|--------|
| Refresh System + Domain | Reload System and Domain tabs |
| Save log... | Save session log to file |
| Settings... | Toggle live filter, confirm dialogs, row count |
| Exit | Close application |

### Export
Export any dataset to CSV. **Export current view to Excel (.xlsx)** — requires ImportExcel module, falls back to UTF-8 BOM CSV (opens correctly in Excel with Greek characters).

```powershell
Install-Module ImportExcel -Scope CurrentUser
```

### Tools
Module status check, AD Health Check, Dark/Light mode toggle, Clear log.

### Help > About
Version 2.1, author, karanik.gr, GitHub link. Resizable dialog with scrollable content.

---

## Architecture

| Component | Details |
|-----------|---------|
| Language | PowerShell 5.1+ (Windows PowerShell and PS7 compatible) |
| UI | WPF via `[System.Windows.Markup.XamlReader]::Load()` with inline XAML |
| Threading | Background runspaces for NTFS scanning; dedicated orchestrator runspace for Net Status |
| Parallel scanning | `RunspacePool` with configurable thread count for Net Status tab |
| Logging | Dual-stream: structured log buffer + live Output tab via Dispatcher.Invoke |
| Export | CSV (UTF-8 BOM) or XLSX via ImportExcel module |
| Filters | WPF CollectionViewSource for live filter (no AD re-query) |

---

## Changelog

### v2.1 — May 2026

- **Net Status tab** — complete rewrite:
  - Parallel `RunspacePool` scanning (default 20 threads) — 80 computers in ~15s vs 7+ minutes sequential
  - "Get Computers" button — loads AD computer list as scrollable checklist; select individual computers before scanning; Select All / Clear buttons
  - WMI checkbox — Uptime, Free RAM, Free Disk via Win32_OperatingSystem / Win32_LogicalDisk
  - PSRemoting checkbox — WinRM fallback when WMI fails; also reads LastUser from HKLM LogonUI
  - RemoteReg (LastUser) checkbox — reads LastLoggedOnUser from Remote Registry
  - Best-wins logic — each method fills empty fields only; no method overwrites a successful result
  - Detailed tooltips on all three checkboxes: ports, requirements, GPO fix, PowerShell fix
  - Ping (continuous) and RDP connect in right-click context menu
  - Live grid updates every 5 results; progress counter `[29/80] (36%) COMPUTERNAME...`
  - Stop button (visible only during active scan)
- **Computers tab** — Last Logon Heatmap (tile system, inline user list on click)
- **Users tab** — live filter (CollectionViewSource), Export XLSX, heatmap panel, User Details right-click, confirm on Disable and Reset Password, row count label
- **Groups tab** — row count label, right-click copy cell/row
- **OU Tree** — right-click: Copy OU path, Load users from OU
- **Domain tab heatmap** — click tile shows users inline; no popup window
- **Settings dialog** (File > Settings) — live filter on/off, confirm dialogs on/off
- **Keyboard shortcuts** — F5 refresh, Ctrl+E export, Ctrl+F focus filter
- **About dialog** — resizable, scrollable, GitHub link added
- **Dark mode icon** — sun/moon symbol (Segoe UI Symbol) replaces [Dark]/[Light] text

### v2.0 — May 2026 (initial release)

- WPF GUI with 19 tabs: System, Domain, OU Tree, Shares, Users, Groups, Computers, GPOs, Pwd Expiry, Inactive, Recycle Bin, DNS Zones, DHCP, Stale PCs, Group Diff, AD Health, Net Status, Output, Log
- Auto-elevation to Administrator, STA mode auto-enforcement
- Background runspace for NTFS permission scanning with cancel flag and Stop button
- NTFS scanner: skip system folders, skip admin shares, warn at 1000+ results, configurable depth
- Domain tab: Last Logon Activity Heatmap with 7 buckets
- AD Health check: DC reachability, LDAP, replication, SYSVOL, NETLOGON, password policy, lockouts
- Group Diff: side-by-side membership comparison with Export CSV
- Full CSV export for all tabs
- Bulk Enable/Disable/Reset Password/Unlock for users (multi-select)
- Member-Of viewer
- Output tab: live console log green-on-black, Consolas
- Log tab: timestamped session log
- Dark/Light mode toggle
- Menu bar: File, Export, Tools, Help/About

---

## Author

**Nikolaos Karanikolas**  
🌐 [karanik.gr](https://karanik.gr)  
🐙 [github.com/karanikn](https://github.com/karanikn)

---

## AI Assistance

This project was developed with the assistance of **[Claude](https://claude.ai)** (Anthropic AI). The architecture, WPF GUI, threading model, async patterns, parallel RunspacePool scanning, and all PowerShell code were designed and iterated collaboratively between the developer and Claude over an extended development session.

---

## Disclaimer

This tool executes PowerShell with Administrator privileges and makes changes to Active Directory. Always test in a non-production environment first. The author takes no responsibility for data loss or unintended changes resulting from use of this tool.
