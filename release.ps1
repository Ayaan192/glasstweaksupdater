#!/usr/bin/env pwsh
# Publishes one Glass Tweaks release: builds the app, builds the installer from that same
# build, signs both, zips the app for the updater and rewrites the manifest the app reads.
# Run it from this folder, commit, and push.
#
#   ./release.ps1
#
# It takes the version from the app project itself, so the one place to raise it is
# <Version> in windows/app/GlassTweaks.csproj. Everything that must never disagree — the
# source, the version inside the exe, the version inside the MSI, the names of the files in
# updates\, and the version and checksum in appcast.xml — comes from that one value.
# Doing it by hand is how a release gets published that no copy of the app ever notices,
# or an installer that Add or remove programs reads as a different program from the one it
# puts on the disk.
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

    # The installer project. Defaults to the copy in the main repository.
    [string]$Installer,

    # Reuse the exe and the MSI already in windows\dist rather than building them again.
    # For re-cutting a release whose build has not changed, such as after a fix to this
    # script itself.
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

# Resolved here rather than in the parameter block: $PSScriptRoot is not yet populated when
# the defaults are evaluated under Windows PowerShell, so a Join-Path there fails outright.
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$windows = (Resolve-Path (Join-Path $root '..\windows')).Path
if (-not $App) { $App = Join-Path $windows 'app' }
if (-not $Installer) { $Installer = Join-Path $windows 'installer' }

# Where the two built artifacts are handed over from: package-installer.ps1 leaves the
# signed exe and the signed MSI here, and this script only ever copies out of it.
$dist = Join-Path $windows 'dist'

# Where a release lands: one folder, `updates`, holding the manifest and the files it
# names. It is the only folder in this repository the app reads, and the only one anybody
# has to open to see what has been published.
$updates = Join-Path $root 'updates'
New-Item -ItemType Directory -Force -Path $updates | Out-Null

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

# ---- The version, read from the project ---------------------------------------------
# The app's own <Version> is the single source of truth: it is what the assembly reports,
# what the MSI is built under (the installer project reads the same file), and what every
# copy of the app compares the manifest against. So the release is named from the project
# rather than the other way round, and none of them can drift apart.
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

# ---- Build ---------------------------------------------------------------------------
# One build, two artifacts. package-installer.ps1 is what produces the pair for a person to
# hand to somebody else, so it is also what a release is cut from: the exe the updater
# hands out and the exe inside the MSI are then the same binary, signed once, instead of two
# builds that happen to carry the same number. The MSI takes its version from the app
# project, so it is built under this release's version without being told.
if (-not $SkipBuild) {
    Step "Publishing Glass Tweaks $version3 from $App"

    & (Join-Path $Installer 'package-installer.ps1')
    if ($LASTEXITCODE -ne 0) { throw "packaging the app and the installer failed with exit code $LASTEXITCODE." }
}
else {
    Step "Skipping the build; packaging the exe and the MSI already in windows\dist"
}

$exe = Join-Path $dist 'GlassTweaks.exe'
$msi = Join-Path $dist 'GlassTweaksSetup.msi'
if (-not (Test-Path $exe)) { throw "No GlassTweaks.exe in $dist. Run this once without -SkipBuild first." }
if (-not (Test-Path $msi)) { throw "No GlassTweaksSetup.msi in $dist. Run this once without -SkipBuild first." }

# ---- The exe the update will carry ----------------------------------------------------
# The exe has to claim the version being released: this is the number the app compares the
# manifest against, and a mismatch here means every copy of the app either ignores the
# release or updates to it forever.
$built = (Get-Item $exe).VersionInfo.FileVersion
if ($built -ne $version4) {
    throw "The exe reports $built but this release is $version4. Raise <Version> in $projectPath, or publish again, so the app compares the manifest against the same number it is running."
}
Write-Host "  exe   : $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB, reports $built)"

# ---- The MSI ---------------------------------------------------------------------------
# Read out of the package's own Property table, which is what Add or remove programs shows
# and what Windows Installer compares when a newer build replaces an older one. A MSI built
# from a stale project would install a build the updater never published, so it is refused
# here rather than discovered later on somebody's machine.
function MsiVersion([string]$path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($path, 0))
    $view = $database.GetType().InvokeMember(
        'OpenView', 'InvokeMethod', $null, $database,
        @("SELECT `Value` FROM `Property` WHERE `Property`='ProductVersion'"))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if ($null -eq $record) { return '' }
    return $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
}

$msiBuilt = MsiVersion (Resolve-Path $msi).Path
if ($msiBuilt -ne $version3) {
    throw "The installer carries version $msiBuilt but this release is $version3. The installer project reads <Version> from $projectPath, so a different number means it was built against another copy of the app — rebuild it with package-installer.ps1."
}
Write-Host "  msi   : $msi ($([math]::Round((Get-Item $msi).Length / 1MB, 1)) MB, reports $msiBuilt)"

# ---- The two files that go into updates\ ----------------------------------------------
Step "Packaging GlassTweaks-$version3.zip"
$zipName = "GlassTweaks-$version3.zip"
$zipPath = Join-Path $updates $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# The zip is the installer's own exe, zipped on its own: that is what an update unpacks over
# the install folder, and it is why the two artifacts can never be different builds.
Compress-Archive -Path $exe -DestinationPath $zipPath -Force

$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$size = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)

# The installer ships too, under its version, for anybody who wants to put the app on a
# machine properly rather than update a copy that is already there. The app itself never
# fetches this; it is here so the repository holds the complete release rather than half of
# it, and so the file can be handed to somebody as a link.
$msiName = "GlassTweaksSetup-$version3.msi"
$msiPath = Join-Path $updates $msiName
Copy-Item $msi $msiPath -Force
$msiSize = [math]::Round((Get-Item $msiPath).Length / 1MB, 1)

# ---- Manifest ------------------------------------------------------------------------
Step "Writing appcast.xml"
$url = "https://raw.githubusercontent.com/$Owner/$Repo/main/updates/$zipName"
$msiUrl = "https://raw.githubusercontent.com/$Owner/$Repo/main/updates/$msiName"
$changelog = "https://github.com/$Owner/$Repo/releases"

$manifest = @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Written by release.ps1 for Glass Tweaks $version3. Do not edit by hand: run the script
  again so the version, the file names and this checksum stay in step.

  The installer for this release is beside the zip, unchanged for the app's own use:
    $msiUrl
-->
<item>
  <version>$version4</version>
  <url>$url</url>
  <changelog>$changelog</changelog>
  <mandatory mode="2">true</mandatory>
  <checksum algorithm="SHA256">$hash</checksum>
</item>
"@

# No BOM: this file is written by Windows PowerShell on one machine and served raw to
# every copy of the app, and the declaration above already says what the encoding is.
$manifestPath = Join-Path $updates 'appcast.xml'
[System.IO.File]::WriteAllText($manifestPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))

# The manifest is read with an XML parser, so it is checked with one here. A stray '--'
# inside a comment is enough to make the whole file unparseable, and the app would then
# see no update at all rather than report an error about it — the exact failure that is
# invisible until somebody wonders why a release was never picked up.
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

# <checksum> carries an algorithm attribute, so PowerShell hands it back as an element
# rather than as its text — read the text out of it either way, because that is what the
# app hashes against.
$published = if ($node.checksum -is [System.Xml.XmlElement]) { $node.checksum.InnerText } else { [string]$node.checksum }
if ($published -ne $hash) { throw "appcast.xml carries $published, expected $hash." }
if ($node.checksum -is [System.Xml.XmlElement] -and $node.checksum.algorithm -ne 'SHA256') {
    throw "appcast.xml asks for a $($node.checksum.algorithm) hash, which is not the one this script wrote."
}

# ---- What to do next -----------------------------------------------------------------
Step "Done"
Write-Host "  exe      : $exe ($built, signed)"
Write-Host "  msi      : $msiPath ($msiSize MB, $msiBuilt, signed)"
Write-Host "  zip      : $zipPath ($size MB)"
Write-Host "  sha256   : $hash"
Write-Host "  manifest : $manifestPath"
Write-Host ""
Write-Host "  Publish it:" -ForegroundColor Yellow
Write-Host "    git add updates/appcast.xml updates/$zipName updates/$msiName"
Write-Host "    git commit -m `"Release Glass Tweaks $version3`""
Write-Host "    git push"
Write-Host ""
Write-Host "  The app reads the manifest from the raw URL on main, so it goes live the moment"
Write-Host "  the push lands. To watch it happen, run the app and look at %APPDATA%\GlassTweaks\update.log."
