#!/usr/bin/env pwsh
# Writes the manifest for a release that is already in updates/, without building anything.
#
#   ./publish-uploaded.ps1 -Zip updates/GlassTweaks-0.4.0.zip
#
# release.ps1 is the normal way to publish: it builds, signs, zips and writes the manifest in
# one go. This script is for the other way, which is what you want when a build was made
# somewhere else -- a machine that has the signing certificate, a build server, or a zip
# somebody handed you. Drop the zip into updates/, run this, commit and push.
#
# It does the three things that must be right or the release is invisible: it reads the
# version the app will compare against out of the zip's own exe rather than out of the file
# name alone, it checks that the zip has the shape an update can unpack, and it writes the
# SHA256 the app verifies the download against. A manifest whose checksum is wrong is worse
# than no manifest: every copy of the app downloads the file and then throws it away.
[CmdletBinding()]
param(
    # The zip to publish: a path, or just a name and it is looked for in updates/.
    [Parameter(Mandatory = $true)]
    [string]$Zip,

    [string]$Owner = 'Ayaan192',

    [string]$Repo = 'glasstweaksupdater',

    # Write the manifest but do not touch the zip: for checking a release before publishing it.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$updates = Join-Path $root 'updates'

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

# ---- The zip --------------------------------------------------------------------------
if (-not (Test-Path $Zip)) {
    $inUpdates = Join-Path $updates (Split-Path $Zip -Leaf)
    if (-not (Test-Path $inUpdates)) {
        throw "There is no $Zip and no $inUpdates either. Put the release zip in updates\ and name it there."
    }

    $Zip = $inUpdates
}

$Zip = (Resolve-Path $Zip).Path
$name = Split-Path $Zip -Leaf
if ([System.IO.Path]::GetExtension($name) -ne '.zip') { throw "$name is not a zip." }

Step "Reading $name"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName })
    $exeEntry = $archive.Entries | Where-Object { $_.FullName -ieq 'GlassTweaks.exe' } | Select-Object -First 1
    if (-not $exeEntry) {
        throw "The zip has no GlassTweaks.exe at its root, so an update could not unpack it over the install folder. It holds: $($entries -join ', ')"
    }

    if ($entries.Count -gt 1) {
        Write-Warning "The zip also holds $($entries.Count - 1) other entry(s): $((($entries | Where-Object { $_ -ine 'GlassTweaks.exe' }) -join ', ')). An update unpacks all of them over the install folder."
    }

    # The version is taken out of the exe itself, which is the number every copy of the app
    # compares the manifest against. The file name is only checked against it afterwards,
    # because a release whose name and build disagree is published under a version no machine
    # will ever act on.
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("gltw-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($exeEntry, (Join-Path $staging 'GlassTweaks.exe'), $true)
}
finally {
    $archive.Dispose()
}

$extracted = Join-Path $staging 'GlassTweaks.exe'
$built = (Get-Item $extracted).VersionInfo.FileVersion
if (-not $built -or $built -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "The exe in the zip reports '$built', which is not a version the app can compare."
}

Write-Host "  exe           : $built"
Write-Host "  size          : $([math]::Round((Get-Item $Zip).Length / 1MB, 1)) MB"

if ($name -notmatch [regex]::Escape(($built.Split('.')[0..2] -join '.'))) {
    Write-Warning "The zip is named $name but the build inside it is $built. The manifest is written from the build, so the app will still compare the right number -- the name is only for whoever reads this folder."
}

# ---- The manifest ---------------------------------------------------------------------
Step 'Writing appcast.xml'
$hash = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
$url = "https://raw.githubusercontent.com/$Owner/$Repo/main/updates/$name"
$changelog = "https://github.com/$Owner/$Repo/releases"

$manifest = @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Written by publish-uploaded.ps1 for the build in $name. Do not edit by hand: run the
  script again so the version and this checksum stay in step. release.ps1 writes this file
  too, when a release is cut from source rather than uploaded.
-->
<item>
  <version>$built</version>
  <url>$url</url>
  <changelog>$changelog</changelog>
  <mandatory mode="2">true</mandatory>
  <checksum algorithm="SHA256">$hash</checksum>
</item>
"@

# No BOM: this file is written on one machine and served raw to every copy of the app, and
# the declaration above already says what the encoding is.
$manifestPath = Join-Path $updates 'appcast.xml'
if ($DryRun) {
    Write-Host $manifest
    Write-Host "(dry run: $manifestPath was left as it is)"
}
else {
    [System.IO.File]::WriteAllText($manifestPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))

    $parsed = [xml](Get-Content -Path $manifestPath -Raw)
    if ($parsed.item.version -ne $built) { throw "appcast.xml says $($parsed.item.version), expected $built." }
    if ($parsed.item.url -ne $url) { throw "appcast.xml points at $($parsed.item.url), expected $url." }
}

# ---- What to do next ------------------------------------------------------------------
Step 'Done'
Write-Host "  zip          : $Zip"
Write-Host "  version      : $built"
Write-Host "  sha256       : $hash"
Write-Host "  manifest     : $manifestPath"
Write-Host ''
Write-Host '  Publish it:' -ForegroundColor Yellow
Write-Host "    git add updates/appcast.xml updates/$name"
Write-Host "    git commit -m `"Release Glass Tweaks $built`""
Write-Host '    git push'
Write-Host ''
Write-Host "  Every copy of the app older than $built picks it up on its next launch. A copy"
Write-Host '  already on that version, or newer, does nothing at all.'

Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
