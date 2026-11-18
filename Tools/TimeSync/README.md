# Time sync fix

For "the clock's wrong", and for sign-ins, Teams, Outlook or VPNs failing because of it (Kerberos stops working once a clock is 5 minutes out). It checks how the PC keeps time, resyncs it, and measures again.

| Step | What happens |
|---|---|
| **Check** | Domain member, domain controller or neither (Entra / workgroup). Where the time is meant to come from (the domain, or a time server) and whether **automatic time** is on. Whether Group Policy / Intune sets it. The **Windows Time service** (disabled is a FAIL). The source actually in use ("Local CMOS Clock" means it isn't syncing from anything). The **last good sync**. "Can't reach the time source" events in the last 7 days (36, 47, 129, 134). **How far out the clock is** against its own time server, and whether that's beyond the **largest jump Windows makes by itself**. The time zone, and whether it's set automatically. |
| **Fix** | Sets a disabled Windows Time service back to Manual and starts it. Turns automatic time back on if it's off (following the domain on domain PCs, otherwise the time server it already had, or `time.windows.com`). Resyncs, rediscovering the source when it wasn't syncing from anything or the settings changed. **Every config change prints the command that undoes it.** |
| **Check again** | Measures the offset and reads the source again. |

## Run

- Menu: **Repair > Time sync fix**
- Command: `Repair-TimeSync`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Repair-TimeSync.ps1`

| Parameter | Effect |
|---|---|
| `-CheckOnly` | Check and measure, change nothing. Works unelevated, with less detail. |
| `-SetPeer` | Point a non-domain PC at `-Peer` as its time server, then resync. Refused on domain members, DCs and policy-managed PCs. |
| `-Peer` | Time server for `-SetPeer`, default `time.windows.com` |
| `-Reference` | Server to measure against, default the PC's own time server (or `time.windows.com` when it isn't using one) |
| `-Quiet` | One summary line, for the RMM |
| `-PassThru` | Return the findings, actions and offsets as objects |

## What it won't do

- **Change where the time comes from** unless you ask with `-SetPeer`. Some time-fix scripts point every PC at `pool.ntp.org`. On a domain member that pulls it off the domain's time, and this tool flags that instead (with the command to put it back).
- **Touch a domain controller.** It reports, nothing more: a DC's time is the domain's time.
- **Change the time zone, or set the time by hand.** If the clock is further out than Windows will correct by itself, it says so: set the time in Settings first, then run it again.
- **Restart anything.**

## Good to know

- **The offset is shown as a size, not a direction** ("out by 3m 12s"). Microsoft doesn't document which way round `w32tm`'s sign is.
- **The time check needs NTP: UDP 123 out** to the time server. If it can't measure, the firewall, proxy or web filter is the usual reason, and the resync will fail the same way.
- **On a non-domain PC the Windows Time service stopping between syncs is normal.** It starts when it's needed (Windows syncs about once a week there).
- **Labels from `w32tm /query /status` are read in English.** On other languages the last-sync time comes from the event log instead and is shown as INFO.
- Exit codes: `0` = in time (within 30 seconds) or a clean check, `1` = still out, a step failed, or a FAIL with `-CheckOnly`.
- Console only, no log file: keep a transcript if you need one.
