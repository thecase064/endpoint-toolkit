# Compiled to EndpointToolkit.exe by Build-Exe.ps1.
# Holds no tools: it opens a PowerShell window that fetches the current launcher from GitHub,
# so the exe never needs rebuilding when the scripts change.
$url = 'https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1'
$cmd = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm '$url' | iex"
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', "`"$cmd`"")
