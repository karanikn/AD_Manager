# AD Manager

[![GitHub release](https://img.shields.io/badge/version-2.1-blue?style=flat-square)](https://github.com/karanikn/AD_Manager)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x-blue?style=flat-square&logo=powershell)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11%20%7C%20Server-lightgrey?style=flat-square&logo=windows)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/license-GPL--3.0-green?style=flat-square)](LICENSE)
[![AI Assisted](https://img.shields.io/badge/built%20with-Claude%20AI-orange?style=flat-square&logo=anthropic)](https://claude.ai)

> **All-in-one Active Directory management tool built as a WPF GUI in PowerShell.**  
> Manage users, computers, groups, GPOs, shares, DNS, DHCP, network status, and more — from a single polished interface. No ADUC, no MMC snap-ins, no separate consoles.

---

## Overview

**AD Manager** is a professional Active Directory administration tool built entirely in PowerShell (~4,700 lines) with a WPF GUI. It provides a unified tabbed interface for the most common — and not so common — AD management tasks.

Designed for **IT administrators and sysadmins** managing Windows Server domains. Runs directly on a domain controller or any domain-joined machine with RSAT installed. Single `.ps1` file, no installation required.

---

## Quick Launch

```powershell
# Run from PowerShell (as Administrator recommended)
Set-ExecutionPolicy -Scope Process Bypass
.\AD_Manager.ps1
```

---

## Requirements

| Requirement | Details |
|-------------|---------|
| PowerShell | 5.1 (primary target) or 7.x |
| OS | Windows 10/11 or Windows Server 2012 R2+ |
| Module | `ActiveDirectory` — RSAT on workstation, or run directly on a DC |
| Optional | `DnsServer` module for the DNS Zones tab |
| Optional | `DhcpServer` module for the DHCP tab |
| Permissions | Domain Admin or delegated AD permissions as appropriate |

---

## Interface — All Tabs

### System
Local machine hardware and software inventory. Loads automatically on startup. Text wraps to window width — no horizontal scroll.

| Section | Contents |
|---------|----------|
| Operating System | Caption, architecture, hostname, timezone |
| Computer / Manufacturer | Make, model, serial number |
| BIOS | Manufacturer, version, serial |
| Processor | Name, cores, max speed |
| Memory (RAM) | Total, used, free + per-slot breakdown (size, speed, manufacturer) |
| Disk Drives | Logical (label, total, used, free, used%) and physical drives |
| Network Adapters | Adapter name, MAC, IP, gateway, DNS servers |
| Services | All services with state/start mode/account — live text filter |
| Startup Applications | Items in registry Run keys with command and location |
| Top 30 Processes | Sorted by CPU time (Name, PID, CPU, RAM MB, Company) |

**Refresh System Info** reloads all sections on demand.

---

### Domain
Domain and forest summary. Loads automatically on startup.

- Forest name, functional level, schema version
- Domain name, SID, NetBIOS name
- FSMO roles: PDC Emulator, RID Master, Infrastructure Master, Schema Master, Domain Naming Master
- All Domain Controllers with site, IP, OS, Global Catalog status, RODC status
- Object counts (users, groups)
- **Last Logon Heatmap** — calendar heat tiles by day; click any tile to see which users last logged on that day inline below the heatmap

---

### OU Tree
Organizational Unit hierarchy browser. Displays the full OU tree. Export the complete structure to CSV.

---

### Shares
Local share enumeration with deep NTFS permission scanner.

- Lists all shared folders (name, path, description, share permissions)
- Click a share → recursively scans NTFS permissions
- GridSplitter between shares list and permissions grid
- Export to CSV

---

### Users
Full AD user management hub.

**Toolbar:**

| Button | Action |
|--------|--------|
| Load | Fetch all domain users |
| Export CSV | Export current view to CSV |
| Export XLSX | Export to Excel with formatting |
| Enable / Disable | Toggle selected user(s) with optional confirmation |
| Reset Pwd | Reset password for selected user |
| Unlock | Unlock a locked-out account |
| Member-Of | Show all groups the selected user belongs to |
| **Auth Audit** | Authentication event audit for selected user (all DCs) |
| Heatmap | Last logon activity heatmap |

**Live filter** — type in the Filter box to instantly narrow the list by username, display name, email, department, or title.

**Disabled only** checkbox — show only disabled accounts.

**Columns:** Username, DisplayName, Email, Enabled, LockedOut, Department, Title, PwdLastSet, PwdNeverExpires, LastLogon, Created, OU

**Right-click menu:** Copy cell value · Copy row · Show user details

**Double-click** any row → User Details dialog.

---

#### User Details Dialog

Opens on double-click or right-click → *Show user details*.

- **Left panel (dark console)** — full user attributes: Username, Display, Email, Title, Department, Office, Phone, Mobile, Manager, Direct Reports count, Description, OU, Enabled, LockedOut, Created, Last Logon, Pwd LastSet, Pwd Never Expires, Account Expiry, SID, Distinguished Name
- **Right panel** — Group Membership list (multi-select with Ctrl+Click / Shift+Click)
  - **Browse...** — opens Browse Groups: loads all AD groups on open, searchable by name (partial match), supports multi-select → adds user to all selected groups
  - **Add** — add to a group typed directly in the text box
  - **Remove from Selected Groups** — removes user from highlighted groups with confirmation
- **Copy Info** — copies the info panel text to clipboard

---

#### Auth Audit Dialog

Select a user → click **Auth Audit**.

Queries **all Domain Controllers** in parallel for the configured number of days back (default 7, max 90). Runs in a background runspace — dialog stays responsive.

| Event ID | Meaning |
|----------|---------|
| 4624 | Successful logon (includes logon type: 2=Console, 3=Network, 7=Unlock, 10=RDP, 11=Cached) |
| 4625 | Failed logon attempt |
| 4768 | Kerberos TGT request (initial authentication) |
| 4769 | Kerberos service ticket request (resource access) |
| 4771 | Kerberos pre-authentication failure (wrong password) |
| 4776 | NTLM credential validation |
| 4740 | Account lockout |

**Result columns:** Time, DC, EventID, Status, Description, Source IP, Workstation, Logon Type, Auth Package

**Stop** button cancels mid-scan. **Export CSV** saves results.

> **Prerequisite:** Audit policies must be enabled in GPO. The yellow notice in the dialog shows the exact GPO path. Use **File → Settings → Audit Policies** to check current status and apply policies.

---

### Groups

AD group management with member editing.

**Toolbar:** Load · Export CSV · Include nested members (checkbox) · live Filter

**Columns:** Name, SAMAccount, Category, Scope, Description

**Right-click:** Copy cell · Copy row · **Group Details / Members...**

**Double-click** → Group Details dialog.

---

#### Group Details Dialog

- **Left panel** — group info: Name, SAMAccount, Category, Scope, Description, Email, ManagedBy, Created, Modified, Members count, Distinguished Name
- **Right panel** — Member list (multi-select)
  - **Browse...** — loads all AD users and groups on open, searchable, multi-select → **Add Selected** adds them all
  - **Add** — add by SAMAccountName
  - **Remove Selected Members** — with confirmation
- **Copy Info** — copies info panel to clipboard

---

### Computers

AD computer account list.

**Columns:** Name, SAMAccount, DNSHostName, OS, OSVersion, Enabled, LastLogon, Created

**Right-click:** Copy cell · Copy row · **Ping (continuous)** · **RDP connect**

**Heatmap** — last logon heatmap for computer accounts.

---

### GPOs

Group Policy Object list.

**Columns:** Name, ID (GUID), Status, Owner, Created, Modified, UserVersion, ComputerVersion

**GPO Link Viewer** button — shows every GPO-to-OU link across the domain.

Export to CSV.

---

### Pwd Expiry

Users whose password will expire within N days (configurable). Export to CSV.

---

### Inactive

Users and computers with no logon in N days (configurable threshold). Two separate grids. Export to CSV.

---

### Recycle Bin

Deleted AD objects — requires the AD Recycle Bin feature to be enabled on the domain.

Columns: object name, class, when deleted, last known parent OU.

---

### DNS Zones

Requires `DnsServer` PowerShell module.

- All DNS zones (name, type, replication scope)
- Click a zone → load its resource records (Name, Type, TTL, RecordData)
- Export to CSV

---

### DHCP

Requires `DhcpServer` PowerShell module.

- All DHCP scopes with subnet, range, state, lease count
- Click a scope → load active leases (IP address, MAC, hostname, expiry)
- Export to CSV

---

### Stale PCs

Computer accounts whose machine account password has not changed in N days (configurable). Indicates machines that may be offline, decommissioned, or disconnected from the domain.

---

### Group Diff

Side-by-side group membership comparison between two AD users. Shows groups unique to each user and groups they share.

---

### AD Health

Domain health diagnostic checks:

| Check | Method |
|-------|--------|
| DC Reachability | Ping each DC |
| LDAP | TCP port 389 test per DC |
| Replication | `repadmin /replsummary` |
| SYSVOL share | SMB accessibility check |
| NETLOGON share | SMB accessibility check |
| GPO Policies | Detect orphaned / unlinked GPOs |

---

### Net Status

Parallel network scanner for all domain computers.

**Controls:**

| Control | Description |
|---------|-------------|
| Get Computers | Load AD computer list as scrollable checkboxes — check/uncheck which to scan |
| Select All / Clear | Bulk select/deselect |
| Start Scan | Begin parallel scan |
| Stop | Abort in-progress scan |
| Export CSV | Save results |
| Timeout (ms) | Per-host timeout (default 30 ms) |
| Retries | Ping retries (default 0) |
| Threads | Parallel workers via RunspacePool (default 20, max 50) |
| Discovery | Detection method (see table below) |

**Discovery methods:**

| Method | Behavior |
|--------|----------|
| Ping (ICMP) | Standard ICMP — may be blocked by Windows Firewall on workstations |
| TCP 445 (SMB) | SMB port check — usually open on domain machines even when ICMP is blocked |
| TCP 88 (Kerberos) | Kerberos KDC port — domain controllers |
| TCP 389 (LDAP) | LDAP port — domain controllers |
| TCP 3389 (RDP) | Remote Desktop port |
| **Multi-port (any)** | Tries Ping → 445 → 88 → 389 → 3389 in sequence — highest detection rate (default) |

**Enrichment options:**

| Checkbox | What it adds |
|----------|-------------|
| Online only | Hides offline machines from results |
| WMI | Uptime, Free RAM, Free Disk per drive via CIM/WMI |
| PSRemoting | Same enrichment via PowerShell Remoting (fallback when WMI fails) |
| RemoteReg (LastUser) | Last logged-on username from remote registry |

**Result columns:** Status · Name · IP · RTT · Port445 · Port88 · Port389 · OS · LastLogon · LastUserLogon · Uptime · FreeRAM · FreeDisk · FreeDisk% · DNSHost

**Right-click on results:** Copy cell · Copy row · Ping (continuous) · RDP connect

Scan runs in a **background runspace** (MTA RunspacePool). Progress shown as `[done/total] (pct%) hostname...`. Grid updates live every 5 results.

---

### Output

Live console showing every PowerShell command executed by the tool, with timestamps and results. Format: `[HH:mm:ss][CMD] Get-ADUser ...` / `[INF] Loading users...`. Auto-scroll toggle. Save to file.

---

### Log

Timestamped session event log — every action, warning, and error. Save to file.

---

## File Menu

| Item | Action |
|------|--------|
| Export Current Tab | Export the active tab's grid to CSV |
| **Settings** | Open Settings dialog |
| Exit | Close the application |

---

## Settings

### General Tab
- Keyboard shortcuts (F5 = Refresh, Ctrl+E = Export, Ctrl+F = Filter focus)
- Feature toggles: live filter on DataGrids, confirm before destructive actions, show row count below grids

### Audit Policies Tab

Full audit policy configurator. Each subcategory has independent **Success** and **Failure** checkboxes in a scrollable table.

**Categories and subcategories:**

| Category | Subcategory | Key Events |
|----------|-------------|------------|
| Account Logon | Kerberos Authentication Service | 4768, 4769, 4771 |
| Account Logon | Credential Validation / NTLM | 4776, 4777 |
| Logon/Logoff | Logon | 4624, 4625 |
| Logon/Logoff | Logoff | 4634 |
| Logon/Logoff | Account Lockout | 4740 |
| Logon/Logoff | Special Logon | 4672 |
| Account Management | User Account Management | 4720–4738 |
| Account Management | Security Group Management | 4727–4756 |
| Account Management | Computer Account Management | 4741–4743 |
| Object Access | File System | (requires SACL) |
| Object Access | File Share | 5140 |
| Object Access | Directory Service Access | 4662 |
| Object Access | Directory Service Changes | 4720 (DS) |
| Policy Change | Audit Policy Change | 4719 |
| Policy Change | Authentication Policy Change | 4706, 4707 |
| Privilege Use | Sensitive Privilege Use | 4672, 4673 |
| System | Security State Change | 4608, 4609 |
| System | System Integrity | 4612 |

Every row has a detailed **tooltip** with: event IDs, practical use case, volume warnings, and exact GPO path (`Computer Configuration → Policies → Windows Settings → Security Settings → Advanced Audit Policy Configuration → [Category] → Audit [Subcategory]`).

**Buttons:**

| Button | Action |
|--------|--------|
| Check Current Status | Runs `auditpol /get /category:*` and auto-ticks checkboxes to reflect current state |
| Apply via auditpol | Applies all Success/Failure settings using `auditpol.exe` (requires Administrator) |
| All Success | Tick all Success checkboxes |
| All Failure | Tick all Failure checkboxes |
| Clear All | Untick everything |

The output console (resizable with the GridSplitter) shows auditpol output and apply results.

---

## Column Sorting

Click any column header in any grid to sort ascending. Click again for descending. Sort indicator (▲▼) shown on the active column. Works across all tabs.

---

## General Features

**Live Filter** — Users, Groups, Computers tabs support real-time text filtering without reloading from AD.

**Heatmaps** — Calendar heat tiles showing Last Logon distribution by day. Available in Domain tab (users) and Users tab. Click any tile to see which accounts last logged on that day.

**Export** — CSV export on all major grids. Users tab additionally supports Excel (.xlsx) export with auto-fit columns and header formatting.

**Runspace Architecture** — Net Status scan and Auth Audit run in separate PowerShell runspaces (background threads) keeping the UI fully responsive. Clean Stop buttons cancel gracefully.

---

## File Structure

```
AD_Manager.ps1    # Single self-contained script (~4,700 lines)
README.md         # This file
```

---

## Changelog

### v2.1 (Current)

- **Net Status tab** — parallel RunspacePool scanner (MTA threading); six discovery methods (Ping / TCP 445 / 88 / 389 / 3389 / Multi-port); WMI + PSRemoting + RemoteReg enrichment; Port445 / Port88 / Port389 columns; live progress counter; Stop button; Export CSV; RDP and Ping context menu; scrollable computer checklist
- **User Details dialog** — full attribute info panel + group membership editor; Browse Groups (loads all on open, search filter, multi-select); Add to group; Remove from selected groups
- **Auth Audit** — per-user authentication event query across all DCs; background runspace; events 4624 / 4625 / 4768 / 4769 / 4771 / 4776 / 4740; Stop button; Export CSV; GPO prerequisite notice
- **Group Details dialog** — full group info panel + member list; Browse Users/Groups (loads all, multi-select); Add by SAMAccountName; Remove selected members
- **Settings → Audit Policies tab** — Success/Failure checkbox table per subcategory; Check Current Status reads auditpol and auto-ticks; Apply via auditpol; All Success / All Failure / Clear All; rich tooltips with exact GPO paths; resizable output console via GridSplitter
- **Column sorting** — universal sort handler on all DataGrids using `PSObject.Properties[$p].Value` for reliable PS 5.1 compatibility; direction toggle with ▲▼ indicator
- **Computers tab** — RDP and Ping context menu items (same as Net Status)
- **System tab** — TextWrapping on all stat fields; no horizontal scroll
- **Auth Audit prerequisite notice** — yellow panel in dialog with exact GPO path required

### v2.0

- Initial WPF GUI release — 19 tabs
- Live filter on Users / Groups / Computers
- Last logon heatmap (Domain and Users tabs)
- Export CSV and XLSX
- Member-Of viewer
- NTFS permission recursive scanner
- GPO link viewer
- AD Health diagnostic suite

---

## Author

**Nikolaos Karanikolas**  
IT Administrator · Developer  
[karanik.gr](https://karanik.gr) · [github.com/karanikn](https://github.com/karanikn)

---

## AI Assistance

Developed with the assistance of **Claude** (Anthropic) for code generation, architecture decisions, and debugging.

[![Built with Claude](https://img.shields.io/badge/built%20with-Claude%20AI-orange?style=flat-square&logo=anthropic)](https://claude.ai)

---

## Disclaimer

This tool is provided as-is for administrative use in Windows Active Directory environments. Always test in a non-production environment before deploying to production. The author is not responsible for unintended changes to Active Directory. All operations that modify AD (enable/disable accounts, password resets, group membership changes) prompt for confirmation when the relevant setting is enabled. Audit policy changes made via the Settings dialog apply directly to the local machine using `auditpol.exe` and require Administrator privileges.
