<#
.SYNOPSIS
    Publishes a GitHub release for every version tag that hasn't got one, using that version's
    CHANGELOG.md section as the release notes.

.DESCRIPTION
    Run it after pushing a tag. It reads the tags and releases from GitHub, skips tags that already
    have a release (so it's safe to run again), and creates the rest oldest first. The newest tag is
    marked Latest. It never creates or moves a tag: a tag must already be on GitHub.

    Release titles come from the tag's message (or its commit's first line), with a few overrides
    below where that line doesn't sum the release up. Tags whose CI failed get a note at the top.

    Needs the GitHub CLI, signed in as someone who can write to the repo:
        winget install GitHub.cli
        gh auth login

.PARAMETER Repo
    owner/repo on GitHub. Default thecase064/endpoint-toolkit.

.EXAMPLE
    .\build\Publish-Releases.ps1 -WhatIf     # list what it would publish

.EXAMPLE
    .\build\Publish-Releases.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repo = 'thecase064/endpoint-toolkit'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) not found. Install it with: winget install GitHub.cli   then sign in with: gh auth login'
}

function Invoke-Gh {
    # Runs gh and stops on failure, so a half-finished run is obvious.
    $out = & gh @args
    if ($LASTEXITCODE) { throw "gh $($args -join ' ') failed (exit $LASTEXITCODE)" }
    $out
}

# Titles where the tag's own message undersells or overstates the release.
$titleOverride = @{
    'v1.0.0' = 'v1.0.0: First release'
    'v1.3.0' = 'v1.3.0: Teams cache, print spooler, Office activation, Teams add-in, BitLocker check, triage reports'
    'v1.7.0' = 'v1.7.0: Build report, Intune primary user, drivers in the build, signed installers'
    'v1.7.1' = 'v1.7.1: First attempt at the 5.1 blank-answer fix (superseded by v1.7.2)'
}
# Tags with a red CI job, so nobody pins them by accident.
$ciNote = @{
    'v1.6.0' = '> **Note:** the Windows PowerShell 5.1 CI job failed on this tag (a remote-session test, fixed in v1.7.2). Pin v1.7.2 or later.'
    'v1.7.0' = '> **Note:** the Windows PowerShell 5.1 CI job failed on this tag (a remote-session test, fixed in v1.7.2). Pin v1.7.2 or later.'
    'v1.7.1' = '> **Note:** this fix didn''t work, and the Windows PowerShell 5.1 CI job failed on this tag. Use v1.7.2 or later.'
}

# CHANGELOG sections: "## 1.10.0 - 2026-11-10" up to the next "## ".
$changelogPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'CHANGELOG.md'
$changelog = [IO.File]::ReadAllText($changelogPath, [Text.Encoding]::UTF8)
$sections = @{}
foreach ($m in [regex]::Matches($changelog, '(?ms)^## (\d+\.\d+\.\d+) - (\S+)[ \t]*\r?\n(.*?)(?=^## |\z)')) {
    $sections["v$($m.Groups[1].Value)"] = [pscustomobject]@{ Date = $m.Groups[2].Value; Body = $m.Groups[3].Value.Trim() }
}

$tags = @(Invoke-Gh api "repos/$Repo/tags" --paginate --jq '.[].name' |
    Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Substring(1) })
$released = @(Invoke-Gh api "repos/$Repo/releases" --paginate --jq '.[].tag_name')
if (-not $tags) { Write-Host 'No version tags on GitHub.'; return }
$newest = $tags[-1]

$todo = @($tags | Where-Object { $released -notcontains $_ })
Write-Host ("{0} version tags, {1} already released, {2} to publish." -f $tags.Count, ($tags.Count - $todo.Count), $todo.Count) -ForegroundColor Cyan

foreach ($tag in $todo) {
    $section = $sections[$tag]
    if (-not $section) { Write-Warning "$tag has no CHANGELOG.md section - skipped."; continue }

    $title = $titleOverride[$tag]
    if (-not $title) {
        # Two lines back (type, sha): no quotes in the jq, which Windows PowerShell 5.1 would mangle.
        $type, $sha = @(Invoke-Gh api "repos/$Repo/git/ref/tags/$tag" --jq '.object.type, .object.sha')
        $title = if ($type -eq 'tag') { Invoke-Gh api "repos/$Repo/git/tags/$sha" --jq '.message' }
                 else { Invoke-Gh api "repos/$Repo/git/commits/$sha" --jq '.message' }
        $title = (@($title) | Where-Object { $_ } | Select-Object -First 1)
        if (-not $title) { $title = $tag }
    }

    $notes = @(
        $(if ($ciNote[$tag]) { $ciNote[$tag]; '' })
        $section.Body
        ''
        "_Released $($section.Date). Full history in [CHANGELOG.md](https://github.com/$Repo/blob/main/CHANGELOG.md)._"
    ) -join "`n"
    $latest = if ($tag -eq $newest) { '--latest' } else { '--latest=false' }

    if ($PSCmdlet.ShouldProcess($tag, "publish release '$title'$(if ($tag -eq $newest) { ' (Latest)' })")) {
        $file = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($file, $notes, (New-Object Text.UTF8Encoding $false))
            $null = Invoke-Gh release create $tag --repo $Repo --verify-tag --title $title --notes-file $file $latest
            Write-Host "  [OK] $tag  $title" -ForegroundColor Green
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}
