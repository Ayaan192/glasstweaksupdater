#!/usr/bin/env pwsh
# Publishes one Glass Tweaks release: builds the app, zips it, and rewrites the
# manifest the app reads. Run it from this folder, commit, and push.
#
#   ./release.ps1
#
# It takes the version from the app project itself, so the one place to raise it is
# <Version> in windows/app/GlassTweaks.csproj. The four things that must never disagree —
# the source, the version inside the exe, the name of the zip, and the version in
# appcast.xml — all come from that one value. Doing it by hand is how an update gets
# published that no copy of the app will ever notice.
[CmdletBinding()]
param(
    # Optional. Defaults to the app project's own <Version>. Pass it only to check that a
    # release is being cut under the version the source claims; it must match.
    [string]$Version,

    # The GitHub account that owns this repository. Written into every URL.
    [string]$Owner = 'Ayaan192',

    [string]$Repo = 'glasstweaksupdater',

    # The app project to publish. Defaults to the copy in the main repository.
    [string]$App,

    # Reuse the exe already built into releases\ rather than publishing again.
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

# Resolved here rather than in the parameter block: $PSScriptRoot is not yet populated when
# the defaults are evaluated under Windows PowerShell, so a Join-Path there fails outright.
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $App) { $App = Join-Path $root '..\windows\app' }

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

# ---- The version, read from the project ---------------------------------------------
# The app's own <Version> is the single source of truth: it is what the assembly reports,
# and what every copy of the app compares the manifest against. It is also what the freshly
# built exe will carry, because the publish below passes it through. So the release is named
# from the project rather than the other way round, and the two can never drift apart.
function Normalize([string]$value) {
    $p = $value.Split('.')
    if ($p.Count -lt 2 -or $p.Count -gt 4 -or ($p | Where-Object { $_ -notmatch '^\d+$' })) {
        throw "'$value' is not a version. Use 0.3.0 or 0.3.0.0."
    }

    return (($p + @('0', '0', '0'))[0..3]) -join '.'
}

$projectPath = Join-Path $App 'GlassTweaks.csproj'
$projectVersion = $null
if (Test-Path $projectPath) {
    $project = [xml](Get-Content -Path $projectPath -Raw)
    $projectVersion = @($project.Project.PropertyGroup | ForEach-Object { $_.Version } | Where-Object { $_ }) | Select-Object -First 1
}

if (-not $Version) {
    if (-not $projectVersion) {
        throw "No -Version was given and $projectPath has no <Version> element to read one from."
    }

    $Version = $projectVersion
}

$version4 = Normalize $Version
$version3 = ($version4.Split('.')[0..2]) -join '.'

if ($projectVersion) {
    $project4 = Normalize $projectVersion
    if ($project4 -ne $version4) {
        throw "The app project says version $projectVersion but this release is $version4. Raise <Version> in $projectPath to $version3 first, then run this again: the release has to be cut under the version the source claims, or a build made from that source later would be offered the same update forever."
    }
}

# Where a release lands: one folder, `updates`, holding the manifest and the zip it
# names. It is the only folder in this repository the app reads, and the only one
# anybody has to open to see what has been published.
$updates = Join-Path $root 'updates'
New-Item -ItemType Directory -Force -Path $updates | Out-Null

# Where a build is staged before it is zipped, and where -SkipBuild looks for one.
# Deliberately not `updates`: only the finished zip belongs in there, because that
# folder is committed exactly as it stands.
$build = Join-Path $root 'build'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$zipName = "GlassTweaks-$version3.zip"
$zipPath = Join-Path $updates $zipName
$staging = Join-Path $build "GlassTweaks-$version3"

# ---- Build ---------------------------------------------------------------------------
if (-not $SkipBuild) {
    Step "Publishing Glass Tweaks $version3 from $App"
    if (-not (Test-Path $App)) { throw "The app project is not at $App. Pass -App with the right path." }

    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }

    # Self-contained and single-file, matching package-app.ps1, so the zip is one exe
    # that needs no runtime installed and unpacks over the install folder as one file.
    dotnet publish $App -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:Version=$version3 `
        -o $staging
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }
}
else {
    Step "Skipping the build; packaging the exe already in releases"
    if (-not (Test-Path (Join-Path $build 'GlassTweaks.exe'))) {
        throw "-SkipBuild needs a published GlassTweaks.exe in $build. Run this once without -SkipBuild first."
    }
}

# ---- The exe the update will carry ----------------------------------------------------
$exe = if ($SkipBuild) { Join-Path $build 'GlassTweaks.exe' } else { Join-Path $staging 'GlassTweaks.exe' }
if (-not (Test-Path $exe)) { throw "No GlassTweaks.exe was produced." }

# The exe has to claim the version being released: this is the number the app compares
# the manifest against, and a mismatch here means every copy of the app either ignores the
# release or updates to it forever.
$built = (Get-Item $exe).VersionInfo.FileVersion
if ($built -ne $version4) {
    Write-Warning "The exe reports $built but this release is $version4. The app compares the manifest against $built."
}

# ---- Zip -----------------------------------------------------------------------------
Step "Packaging $zipName"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $exe -DestinationPath $zipPath -Force

$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$size = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)

# ---- Manifest ------------------------------------------------------------------------
Step "Writing appcast.xml"
$url = "https://raw.githubusercontent.com/$Owner/$Repo/main/updates/$zipName"
$changelog = "https://github.com/$Owner/$Repo/releases"

$manifest = @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Written by release.ps1 for Glass Tweaks $version3. Do not edit by hand: run the script
  again so the version, the zip name and this checksum stay in step.
-->
<item>
  <version>$version4</version>
  <url>$url</url>
  <changelog>$changelog</changelog>
  <mandatory mode="2">true</mandatory>
  <checksum algorithm="SHA256">$hash</checksum>
</item>
"@

Set-Content -Path (Join-Path $updates 'appcast.xml') -Value $manifest -Encoding utf8

# The manifest is read with an XML parser, so it is checked with one here. A stray '--'
# inside a comment is enough to make the whole file unparseable, and the app would then
# see no update at all rather than report an error about it — the exact failure that is
# invisible until somebody wonders why a release was never picked up.

$manifestPath = Join-Path $updates 'appcast.xml'
try {
    $parsed = [xml](Get-Content -Path $manifestPath -Raw)
}
catch {
    throw "appcast.xml is not valid XML, so no copy of the app could read it: $($_.Exception.Message)"
}

$node = $parsed.item
if (-not $node) { throw "appcast.xml has no <item> element." }
if ($node.version -ne $version4) { throw "appcast.xml says $($node.version), expected $version4." }
if ($node.url -ne $url) { throw "appcast.xml points at $($node.url), expected $url." }

# ---- What to do next -----------------------------------------------------------------
Step "Done"
Write-Host "  exe      : $exe"
Write-Host "  zip      : $zipPath ($size MB)"
Write-Host "  sha256   : $hash"
Write-Host "  manifest : $manifestPath"
Write-Host ""
Write-Host "  Publish it:" -ForegroundColor Yellow
Write-Host "    git add updates/appcast.xml updates/$zipName"
Write-Host "    git commit -m `"Release Glass Tweaks $version3`""
Write-Host "    git push"
Write-Host ""
Write-Host "  The app reads the manifest from the raw URL on main, so it goes live the moment"
Write-Host "  the push lands. To watch it happen, run the app and look at %APPDATA%\GlassTweaks\update.log."
