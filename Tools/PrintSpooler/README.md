# Print spooler clear

For a print queue that won't clear, jobs stuck on "Deleting" or "Error", or a spooler that keeps falling over on a bad job.

1. Shows how many jobs are queued and how old the oldest is. It counts the files on disk rather than asking the spooler, which is often the thing that's hung.
2. Stops the Print Spooler and anything that depends on it. If the spooler ignores the stop, it ends `spoolsv.exe`.
3. Deletes the queued job files from the spool folder
4. Starts the Spooler again, plus any dependants that were running

**Every queued job on every printer on this PC is deleted**, so people will need to print again. Printers, drivers and settings aren't touched.

The spool folder is read from the registry in case it's been moved. Only `*.SPL` and `*.SHD` job files are ever deleted, so a mis-set spool folder can't take anything else with it.

## Run

- Menu: **Repair > Print spooler clear**
- Command: `Clear-PrintSpooler`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Clear-PrintSpooler.ps1`

Exit codes: `0` = cleared and the spooler is running. `1` = the spooler isn't running at the end, or some job files stayed locked.
