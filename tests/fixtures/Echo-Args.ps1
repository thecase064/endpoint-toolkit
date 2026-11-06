# Test fixture: records the parameters it was called with, then exits 77 (non-zero "success" code).
# -Ask asks a question mid-run, like a tool would, to check nothing hangs when nobody can answer.
param(
    [string] $Name,
    [string] $Path,
    [switch] $Flag,
    [switch] $Other,
    [switch] $Ask
)
$answer = $null
if ($Ask) { $answer = Read-Host 'Fixture question [y/N]' }
Write-Host "fixture ran: $Name"
[pscustomobject]@{
    Name   = $Name
    Path   = $Path
    Flag   = [bool]$Flag
    Other  = [bool]$Other
    Answer = $answer
} | ConvertTo-Json | Set-Content -LiteralPath $env:ETK_TEST_OUT -Encoding UTF8
exit 77
