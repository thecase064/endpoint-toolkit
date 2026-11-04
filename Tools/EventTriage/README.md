# Event Triage — Event Viewer triage tool

**Version:** 0.4  **Stack:** Windows PowerShell 5.1 + WPF, single `.ps1`, no dependencies  **Author:** Tom Fuller

Event Triage is a desktop tool for finding what is actually wrong on a Windows machine from its event logs. Event Viewer shows you thousands of individual events; Event Triage groups them into problems, ranks them by severity and frequency, hides the known noise, and lets you pull the surrounding context and a ready-made AI prompt for anything you want to dig into.

It runs against the local machine or any remote machine you can reach with WinRM or RPC.

---

## 1. Requirements

- Windows 10/11 or Server 2016+ with Windows PowerShell 5.1 (also works on PowerShell 7 on Windows)
- Nothing to install — one script file
- **Local:** run as Administrator to read the Security log; everything else works unelevated
- **Remote via WinRM:** PowerShell Remoting enabled on the target (`Enable-PSRemoting`), and you are an admin there
- **Remote via RPC:** the "Remote Event Log Management" firewall rules enabled on the target

## 2. Running it

From a PowerShell window in the script's folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\EventTriage.ps1
```

Or from anywhere, without changing execution policy:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\EventTriage.ps1"
```

Right-click PowerShell → Run as administrator if you need the Security log. The window title tells you when you are not elevated.

Files the tool creates, in `%APPDATA%\EventTriage` (seeded on first run from the `EventTriage.mutes.json` shipped beside the script):

| File | Purpose |
|---|---|
| `EventTriage.mutes.json` | Your mute list — known-noise Provider + Event ID pairs. Plain JSON, editable by hand. |

## 3. The window

```
+--------------------------------------------------------------------------------------+
| Computer [        ] Method [WinRM] [ ] Creds   Logs [x]System [x]Application [ ]Sec |
| Preset [          ] Range [24h] Levels [x]Crit [x]Err [x]Warn [ ]Info  Provider  IDs |
|                                                              Max [5000] [Run query] |
+--------------------------------------------------------------------------------------+
| status line ....................................................... [progress bar]   |
+---------------------------------------+----------------------------------------------+
| TRIAGE                                | EVENTS | CONTEXT                             |
| one row per Provider + Event ID       | the individual events in the selected group, |
| Level  Log  Provider  ID  Count       | or everything around one event in time order |
| First seen  Last seen  Muted  Message |                                              |
|                                       +----------------------------------------------+
|                                       | DETAILS                                      |
|                                       | full message, event data, XML on request     |
+---------------------------------------+----------------------------------------------+
```

### Query bar

| Control | What it does |
|---|---|
| **Computer** | Blank, `.` or `localhost` = this machine. Anything else = remote. |
| **Remote method** | WinRM (Invoke-Command) or RPC (`Get-WinEvent -ComputerName`). Try the other one if the first fails — the status line tells you which to try. |
| **Prompt for credentials** | Asks for a different account when you run a remote query. Remembered for context/XML fetches in the same session. |
| **Logs** | System, Application, Security, Setup, plus any other log names comma-separated (e.g. `Microsoft-Windows-GroupPolicy/Operational`). |
| **Preset** | One-click query definitions — fills logs, levels, providers and IDs, then runs. See §5. |
| **Time range** | Last hour / 24 hours / 7 days / 30 days / All. |
| **Levels** | Critical, Error, Warning, Information. Security audit events count as Information. None ticked = no level filter. |
| **Providers** | Comma-separated, wildcards allowed: `*Kernel-Power*, Schannel`. |
| **Event IDs** | Comma-separated: `41,1001,7034`. |
| **Max events** | Newest N events fetched. Default 5000. 0 = no limit (slow on busy servers). |
| **Run query / Cancel** | Queries run in the background; the window stays responsive and Cancel stops a slow one. |

### Status line

Always says what just happened: `4,120 events in 63 groups on SRV01 - 2 critical, 14 error, 31 warning - 3 muted - 2.4 s`. If a query fails, the reason and a tip (enable WinRM, run elevated, try RPC) appear here.

## 4. Workflow

**1. Triage grid (left).** One row per Log + Provider + Event ID, sorted most-severe first, then by count. Columns: Level, Log, Provider, ID, Count, First seen, Last seen, Muted, Latest message. Click headers to re-sort. The filter box matches provider, ID, log or message text as you type. Muted groups are hidden by default — untick **Hide muted** to see them.

**2. Events tab (top right).** Click a triage row to see its individual events, newest first. The first one is selected automatically.

**3. Details (bottom right).** Time, computer, log, provider, ID, level, task, user, record number, the full message and every EventData value. Buttons: **Copy**, **Show XML** (fetches the raw record, appended below the details), **Search the web** (searches `"<provider>" "event id <n>"`), and **Show context**.

**4. Context tab.** Pick a window (1 / 5 / 15 / 60 minutes) and press **Show context**. The tool runs a fresh query for *everything* in all queried logs (plus System and Application) either side of the selected event, with no level filter, and lists it in time order. The event you asked about is tinted amber with offset `+0:00`; everything else shows its offset (`-1:23`, `+0:07`). This is where you see the story: disk errors three minutes before the unexpected reboot, the service that stopped just before the app crashed. Click any context row for its details, or select one and press Show context again to re-centre.

**5. Right-click menu** on any grid:

| Item | Where | What it does |
|---|---|---|
| Copy AI prompt | all grids | Builds a troubleshooting prompt with the event details, how often it happens, and (if loaded) the surrounding context. Paste into any AI assistant. On the triage grid it uses the latest event in the group. |
| Copy AI prompt (redacted) | all grids | Same, with hostname → `HOST01`, domain → `example.local`, user → `DOMAIN\USER`, IPv4 → `x.x.x.x`, emails → `user@example.com`, domain SIDs → `S-1-5-21-REDACTED`. Best-effort — skim before pasting client data into a public tool. |
| Mute / Unmute this event ID | triage | Adds or removes the Provider + ID from the mute list and saves the JSON immediately. |
| Copy provider and ID | triage | `Service Control Manager (Event ID 7034)` to the clipboard. |
| Show context / Show XML / Search the web / Copy details | events, context | Same as the Details buttons. |

**6. Export CSV** on each grid: triage summary, the events currently shown (or all events if no group is selected), or the context list.

## 5. Presets

| Preset | Logs | Levels | Filter |
|---|---|---|---|
| Crashes and reboots | System | all | IDs 12, 13, 41, 1001, 1074, 6005, 6006, 6008 |
| Hardware errors (WHEA) | System | all | Provider Microsoft-Windows-WHEA-Logger |
| Disk and storage | System | Crit/Err/Warn | IDs 7, 11, 51, 55, 98, 129, 137, 140, 153, 157 |
| Service failures | System | all | Service Control Manager, IDs 7000–7045 (failures, hangs, crashes, new service installed) |
| Application crashes | Application | all | Application Error / Application Hang / .NET Runtime, IDs 1000, 1002, 1026 |
| Logon failures and lockouts | Security | all | IDs 4625, 4740, 4771, 4776 (needs elevation) |
| Windows Update | System, Setup | all | WindowsUpdateClient + Servicing providers |
| TLS, certificates and Kerberos | System, Application | Crit/Err/Warn | Schannel, Security-Kerberos, KDC, CAPI2 |
| Group Policy | System, GroupPolicy/Operational | Crit/Err/Warn | Provider Microsoft-Windows-GroupPolicy |

Presets live in the `$Presets` array near the top of the script. One line each — copy an existing one to add your own.

## 6. Mute list

`EventTriage.mutes.json` is created on first run with five known-noise entries:

```json
[
  { "provider": "Microsoft-Windows-DistributedCOM",        "id": 10016, "note": "DCOM permission noise - harmless" },
  { "provider": "Microsoft-Windows-Perflib",               "id": 1008,  "note": "Perf counter failed to load - cosmetic" },
  { "provider": "Microsoft-Windows-User Profiles Service", "id": 1534,  "note": "Profile notification failure - cosmetic" },
  { "provider": "Microsoft-Windows-Kernel-EventTracing",   "id": 2,     "note": "ETW session stopped - cosmetic" },
  { "provider": "Microsoft-Windows-Kernel-EventTracing",   "id": 3,     "note": "ETW session failed to start - cosmetic" }
]
```

Matching is on provider name (case-insensitive) + event ID across every log. Muted groups are still counted in the status line (`3 muted`) but excluded from the critical/error/warning totals, so those numbers reflect what actually needs attention. Right-click to mute or unmute from the grid; edit the file directly for bulk changes. Copy the file between machines to share a team-wide noise list.

## 7. Remote machines

| Method | How it works | Needs | Notes |
|---|---|---|---|
| WinRM | `Invoke-Command` runs the query on the target and returns flattened results | PS Remoting enabled, TCP 5985/5986, admin rights on target | Messages are rendered on the target, so they are always complete. Preferred. |
| RPC | `Get-WinEvent -ComputerName` reads the log over RPC | "Remote Event Log Management" firewall rules on target | Messages are rendered on *your* machine — providers not installed locally show a "message not available" placeholder. |

Tick **Prompt for credentials** to use a different account (e.g. a client domain admin). The credential is reused for context and XML fetches until you run a new query.

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Query failed: ... WinRM cannot complete the operation` | Remoting not enabled or blocked. Run `Enable-PSRemoting -Force` on the target, or switch to RPC. |
| `Query failed: The RPC server is unavailable` | Firewall. Enable the "Remote Event Log Management" rule group on the target, or switch to WinRM. |
| `Query failed: Attempted to perform an unauthorized operation` | Security log needs elevation. Run as Administrator, or use Prompt for credentials with an admin account. |
| `No events matched` | Widen the time range or levels, or check the log name spelling (custom logs are `Provider/Channel`, e.g. `Microsoft-Windows-GroupPolicy/Operational`). |
| Note: `There is not an event log on ... that matches "X"` | One of the logs you listed doesn't exist on that machine. Results from the others are still shown. |
| `(message not available ...)` in the message column | RPC method on a provider the querying machine doesn't have. Use WinRM instead. |
| Window doesn't open / XAML error | Script must run in an STA host — `powershell.exe` and the ISE are fine. Check the file wasn't mangled on copy. |
| Query seems stuck | Press Cancel. Large "All" queries against busy servers can take minutes; set Max events or a shorter range. |

## 9. How it works (for maintainers)

Everything is in one file, top to bottom:

1. **`$sync`** — a synchronized hashtable shared between the UI and background work. Workers only ever *write* to it; the UI only ever *reads* it.
2. **Mute list and presets** — JSON load/save helpers and the `$Presets` array.
3. **XAML** — the whole window as a here-string, loaded with `XamlReader`. Every `Name="..."` control is collected into `$c` so handlers can reference `$c.dgTriage`, `$c.txtStatus`, etc.
4. **`$WorkerText`** — the per-event shaping script, kept as text so each background runspace can rebuild it with `[scriptblock]::Create`. It runs on the target (locally, or inside `Invoke-Command`) and turns each `EventLogRecord` into a flat object with a numeric severity, level name, one-line summary, resolved user and the EventData values — same shape whether it comes back live or deserialized.
5. **Worker scripts** — `$QueryScript` (fetch → group → sort), `$ContextScript` (fetch around an anchor → offsets), `$XmlScript` (one record's XML). Each runs in its own runspace via `Start-Worker`, which passes `$sync`, `$WorkerText` and the query parameters in. Errors are merged into the output stream (`2>&1`) and split from the events so a bad log name or a connection failure becomes a status note rather than a crash.
6. **UI helpers and handlers** — filter predicate, detail rendering, preset application, the AI prompt builder (`New-AiPrompt`) and redaction (`Protect-Text`), right-click menus built in code.
7. **DispatcherTimer (200 ms)** — the only place background results touch controls. It checks flags on `$sync` (`StatusDirty`, `ResultReady`, `ContextReady`, `XmlReady`), applies them, and disposes finished runspaces. This avoids cross-runspace delegates entirely, which is what makes the tool stable.

Key design choices:

- **Grouping key** is `Log|Provider|ID`. Mute key is `provider|id` (lowercased) so a mute applies across logs.
- **Severity**: Level 1–5 as reported; Level 0 (LogAlways, used by Security audits) is treated as Information.
- **Sorting**: severity ascending (Critical first), then count descending.
- **Cancel** calls `BeginStop` on the running pipeline; `EndInvoke` then throws a stopped-pipeline exception which the timer reports as "Query cancelled".

## 10. Extending it

- **Add a preset:** add a line to `$Presets`. `Logs`, `Provider` and `Ids` are comma-separated strings; `Levels` is `all` or `cew`.
- **Change the AI prompt wording:** edit `New-AiPrompt`. The five-point ask and the framing sentence are the first block.
- **Add redaction rules:** add a `[regex]::Replace` line to `Protect-Text`.
- **Share a mute list:** distribute `EventTriage.mutes.json` alongside the script. It seeds `%APPDATA%\EventTriage` the first time each user runs the tool.
- **Package as an exe:** `Install-Module ps2exe; Invoke-ps2exe .\EventTriage.ps1 .\EventTriage.exe -noConsole` — the mute file still lives in `%APPDATA%\EventTriage`.

## 11. Version history

| Version | Changes |
|---|---|
| 0.1 | WPF shell, local `Get-WinEvent` query, triage grid |
| 0.2 | Background runspace + timer, events and detail panes, remote (WinRM/RPC), credentials, XML fetch, CSV export, web search, error surfacing with tips |
| 0.3 | Context view with offsets and anchor highlight, mute list (JSON + right-click), nine presets, comma-separated providers, single-pass event shaping |
| 0.4 | Copy AI prompt (plain and redacted) on all grids, shared right-click menus on Events and Context |

## 12. Roadmap

- Boot/crash markers strip (6005/6006/6008/41/1001)
- New vs recurring flags (first seen inside the window; spiking vs previous period)
- Ticket-ready HTML/Markdown export and "Copy as ticket note"
- Multi-machine query with fleet-wide grouping
- Code decoders (4625 status codes, logon types, BugCheck codes, Schannel alerts)
- Remembered settings and recent computers
- Knowledge JSON: per-ID meaning / causes / fix, maintained from resolved tickets
