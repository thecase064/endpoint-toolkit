# Test fixture: records the parameters it was called with, then exits 77 (non-zero "success" code).
param(
    [string] $Name,
    [string] $Path,
    [switch] $Flag,
    [switch] $Other
)
[pscustomobject]@{
    Name  = $Name
    Path  = $Path
    Flag  = [bool]$Flag
    Other = [bool]$Other
} | ConvertTo-Json | Set-Content -LiteralPath $env:ETK_TEST_OUT -Encoding UTF8
exit 77
