# Driver export / import

Back up a machine's drivers before you wipe it, and put them back afterwards. Worth it for the odd model whose vendor driver pack is a nightmare to find.

## Export

- Menu: **Build > Driver export**
- Command: `Export-DeviceDriver -Destination E:\Drivers -Zip`

Exports every third-party driver (inbox Windows drivers come back with Windows anyway) to `C:\DriverExport\<PC>_<make>_<model>_<date>\` by default, plus:

| File | Contents |
|---|---|
| `drivers.csv` | Class, provider, version, date and original .inf of each driver |
| `device.json` | Make, model, serial and OS of the source machine |
| `RESTORE.txt` | The command that puts them back |

`-Zip` adds a single `.zip` next to the folder for the USB stick. `-OfflineImagePath D:\` exports from an offline Windows install (another drive or a mounted image) instead of the running OS.

If the export lands on the machine's own system drive, the script reminds you to copy it off before the wipe.

## Import

- Menu: **Build > Driver import**
- Command: `Export-DeviceDriver -ImportFrom E:\Drivers\PC-1234_Dell_Latitude-5440_20261104.zip`

Takes the folder or the zip and installs everything with `pnputil /add-driver /subdirs /install`.

## Exit codes

`0` = OK, `3010` = imported, reboot to finish, `1` = failed. Needs admin.
