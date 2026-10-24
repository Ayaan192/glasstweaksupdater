#!/usr/bin/env pwsh
# Publishes one Glass Tweaks release: builds the app, builds the installer from that same
# build, signs both, zips the app for the updater and rewrites the manifest the app reads.
# Run it from this folder, publish the two files it staged as a GitHub Release, then commit
# and push the manifest.
#
#   ./release.ps1                    build, stage and write appcast.xml
#   ./release.ps1 -SkipBuild         re-cut it from the exe and MSI already in windows\dist
#   ./release.ps1 -Verify            check the published release and manifest, change nothing
#
# It takes the version from the app project itself, so the one place to raise it is
# <Version> in windows/app/GlassTweaks.csproj. Everything that must never disagree — the
# source, the version inside the exe, the version inside the MSI, the names of the files
# attached to the release, the tag that release carries, and the version and checksum in
# appcast.xml — comes from that one value. Doing it by hand is how a release gets published
# that no copy of the app ever notices, or an installer that Add or remove programs reads
# as a different program from the one it puts on the disk.
[CmdletBinding()]
param(
    # Check what is published — the manifest on main and the zip it names — against this
    # release, and stop. Nothing is built, nothing is written, no file is touched.
    [switch]$Verify,
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
    [switch]$SkipBuild,

    # Serve the update from this repository instead of from a GitHub Release: the manifest
    # points at the zip where it sits on main, and the zip is copied into updates\ ready to
    # be committed beside the manifest.
    #
    # Publishing is then one push and nothing else — no release to create, no web page to
    # open, no asset to attach — which is what makes a release land on every machine the
    # next time somebody opens the app. The cost is that the zip lives in the repository's
    # history for good: about 60 MB a release, which is fine for a handful of releases and
    # not fine forever. The MSI is still built and still signed; only the zip an update
    # unpacks has to be reachable by URL, so the installer is left in release\ for whoever
    # wants it and can be attached to a release without being committed.
    [switch]$Direct
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

# Where the two files an update is served from are staged: `release\`, which git ignores.
# They are attached to a GitHub Release rather than committed, because the app fetches them
# over https by URL and a 60 MB zip committed to git is a 60 MB zip in every clone of this
# repository forever. The one file that does have to be in the repository is the manifest,
# and it sits at the root so the app can read it raw.
$release = Join-Path $root 'release'
New-Item -ItemType Directory -Force -Path $release | Out-Null

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

# ---- The version, read from the project ---------------------------------------------
# The app's own <Version> is the single source of truth: it is what the assembly reports,
# what the MSI is built under (the installer project reads the same file), and what every
# copy of the app compares the manifest against. So the release is named from the project
# rather than the other way round, and none of them can drift apart.
function Normalize([string]$value) {
    $p = $value.Split('.')
    # One number is a version: a release named 8 is built, installed and compared as
    # 8.0.0.0, and that is what this pads it to.
    if ($p.Count -lt 1 -or $p.Count -gt 4 -or ($p | Where-Object { $_ -notmatch '^\d+$' })) {
        throw "'$value' is not a version. Use 8, 0.3.0 or 0.3.0.0."
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

# What the release is called on the page, in the tag and in the file names. Trailing
# zeroes are dropped, so the labels read the way releases are talked about: 10.0.0 is 10,
# 10.1.0 is 10.1, and 10.1.2 keeps all three parts. The exe, the installer and the manifest
# keep the four-part value they are compared by. The two are the same release; only the way
# it is written down differs, so a minor release after 10 is simply v10.1 and every copy
# already out there still compares it as 10.1.0.0.
$parts = $version4.Split('.')
$label = if ($parts[2] -ne '0') {
    $version3
} elseif ($parts[1] -ne '0') {
    "$($parts[0]).$($parts[1])"
} else {
    $parts[0]
}

# The tag the assets are published under, and the URLs that follow from the version. Written
# into the manifest, so the release's name, the name of the file attached to it and the URL
# the app fetches are all the same release rather than three things kept in step by hand.
$tag = "v$label"
$zipName = "GlassTweaks-$label.zip"

# Where the zip an update downloads is reached from. A release asset is the tidy answer and
# the default; -Direct puts it on main and takes the release out of the loop entirely.
$updates = Join-Path $root 'updates'
$msiName = "GlassTweaksSetup-$label.msi"
$url = if ($Direct) {
    # raw.githubusercontent serves this straight out of the repository, so the zip has to be
    # committed — see the -Direct note in the parameter block.
    "https://raw.githubusercontent.com/$Owner/$Repo/main/updates/$zipName"
}
else {
    "https://github.com/$Owner/$Repo/releases/download/$tag/$zipName"
}
$msiUrl = "https://github.com/$Owner/$Repo/releases/download/$tag/$msiName"

# Where the manifest is published, which is not a free choice and not where the zip lives.
# Every copy of the app already installed was compiled with this URL and checks it on launch,
# so a manifest written anywhere else is read by nobody: the release lands, the log on every
# machine still says the update file could not be reached, and it looks exactly like nothing
# was published. Shipped builds read updates/appcast.xml, so that is where the manifest goes
# in both flows — what changes between them is only where the zip it names is served from.
# One path, one URL, one verification: -Verify then means the same thing after either flow.
$manifestUrl = "https://raw.githubusercontent.com/$Owner/$Repo/main/updates/appcast.xml"
$manifestRepoPath = 'updates/appcast.xml'

# The two things a device actually fetches: the manifest on main, and the zip it names.
# Checked with the same plain, unsigned-in https requests the app makes, because a manifest
# that names a file nobody attached is the one failure that looks like nothing happening, on
# every machine at once.
function Assert-Published {
    $problems = New-Object System.Collections.Generic.List[string]
    $publishedUrl = $null
    $liveChecksum = $null

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # Windows PowerShell on an old .NET leaves the default alone; GitHub refuses that
        # handshake, which the request below then reports.
    }

    Write-Host "  manifest : $manifestUrl"
    try {
        # raw.githubusercontent.com serves a cached copy for a few minutes, so the check asks
        # past it rather than reporting the release before this one as current.
        $response = Invoke-WebRequest -Uri "$manifestUrl`?release-check=$([DateTime]::UtcNow.Ticks)" -UseBasicParsing -TimeoutSec 30
        $published = ([xml]$response.Content).item
        Write-Host "    names $($published.version)" -ForegroundColor Green
        $publishedUrl = $published.url
        $liveChecksum = ($(if ($published.checksum -is [System.Xml.XmlElement]) { $published.checksum.InnerText } else { [string]$published.checksum })).ToLowerInvariant()

        if ($published.version -ne $version4) {
            $problems.Add("the published manifest names $($published.version) and this release is $version4; push $manifestRepoPath, or raise <Version> to $(($published.version.Split('.')[0..2]) -join '.')")
        }

        # Not a failure: the live manifest naming the other flow's URL is a release cut the
        # other way, and the zip it names is checked below whether or not this run would have
        # written that URL. A manifest left over from the release *before* this one cannot get
        # past the version check above, so a mismatch here is only ever the flow.
        if ($published.url -ne $url) {
            Write-Host "    served as  : $($published.url)" -ForegroundColor Gray
            Write-Host "    this run   : $url ($(if ($Direct) { '-Direct' } else { 'release asset' }))" -ForegroundColor Gray
        }
    }
    catch {
        $problems.Add("the manifest could not be read at all: $($_.Exception.Message)")
        Write-Host "    could not be read" -ForegroundColor Yellow
    }

    # The file a device will fetch is the one named by the manifest that is live — not the one
    # this run would write. A manifest left over from the release before names the build before,
    # and checking our own URL against it would report a release that is not there.
    $live = if ($publishedUrl) { $publishedUrl } else { $url }
    Write-Host "  zip      : $live"
    try {
        $head = Invoke-WebRequest -Uri $live -Method Head -UseBasicParsing -TimeoutSec 30
        $publishedSize = [long]$head.Headers['Content-Length']
        Write-Host "    $([math]::Round($publishedSize / 1MB, 1)) MB" -ForegroundColor Green

        $staged = Join-Path $release $zipName
        if (Test-Path $staged) {
            $localSize = (Get-Item $staged).Length
            $localHash = (Get-FileHash $staged -Algorithm SHA256).Hash.ToLowerInvariant()

            if ($publishedSize -ne $localSize) {
                $problems.Add("the published zip is $publishedSize bytes and $zipName here is $localSize, so they are not the same build")
            }

            # The checksum is what the app hashes the download against: a manifest that names
            # this version and a different file is a release every copy of the app fetches and
            # then quietly throws away, which looks exactly like nothing happening.
            if ($liveChecksum -and $liveChecksum -ne $localHash) {
                $problems.Add("the published manifest carries $liveChecksum and $zipName here hashes to $localHash, so every copy of the app would download this build and throw it away")
            }
        }
    }
    catch {
        $problems.Add("the zip could not be fetched: $($_.Exception.Message). Publish the file $zipName is served from before the manifest that names it: a manifest that is live without it is a download that fails on every machine")
        Write-Host "    could not be fetched" -ForegroundColor Yellow
    }

    Write-Host ''
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) { Write-Host "  ! $problem" -ForegroundColor Yellow }
        throw "$($problems.Count) thing(s) about the published release for $version3 are not right."
    }

    Write-Host "  The release and the manifest are both live, and a copy of the app older than $version4 picks it up on its next launch." -ForegroundColor Green
}

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
if ($Verify) {
    Step "Verifying the published release for $label"
    Assert-Published
    return
}

if (-not $SkipBuild) {
    Step "Publishing Glass Tweaks $label from $App"

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
# Both questions below are asked of the package's own tables, which is what Add or remove
# programs reads and what Windows Installer compares when a newer build replaces an older
# one. An installer built around a different build than the exe being published is refused
# here rather than discovered later on somebody's machine.
function MsiValue([string]$path, [string]$sql, [int]$field, [switch]$AsInteger) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($path, 0))
    $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($sql))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if ($null -eq $record) { return $null }

    $kind = if ($AsInteger) { 'IntegerData' } else { 'StringData' }
    return $record.GetType().InvokeMember($kind, 'GetProperty', $null, $record, @($field))
}

$msiBuilt = MsiValue (Resolve-Path $msi).Path 'SELECT `Value` FROM `Property` WHERE `Property`=''ProductVersion''' 1
if ($msiBuilt -ne $version3) {
    throw "The installer carries version $msiBuilt but this release is $version3. The installer project reads <Version> from $projectPath, so a different number means it was built against another copy of the app — rebuild it with package-installer.ps1."
}

# The installer carries a copy of the exe, and it records exactly how large that copy is, so
# the copy can be checked against the exe being handed to the updater. A signature is
# appended to a file, which means signing the exe after building the installer leaves the
# installer holding the unsigned build — the same version number on two different binaries,
# which is the failure this comparison exists to catch. Sizes rather than a hash because the
# package stores the file compressed; equal length and equal version is what can be checked
# without unpacking 150 MB out of a cabinet that expand.exe will not open.
$payload = MsiValue (Resolve-Path $msi).Path 'SELECT `FileSize` FROM `File` WHERE `File`=''GlassTweaksExe''' 1 -AsInteger
$exeSize = (Get-Item $exe).Length
if ($payload -ne $exeSize) {
    throw "The installer carries a $payload-byte exe but the release publishes a $exeSize-byte one, so the two builds differ. The usual cause is the installer being built before the exe was signed; run package-installer.ps1, which signs the exe first."
}

Write-Host "  msi   : $msi ($([math]::Round((Get-Item $msi).Length / 1MB, 1)) MB, reports $msiBuilt, carries the $payload-byte exe this release publishes)"

# ---- The two files that get attached to the release ------------------------------------
Step "Packaging $zipName"
$zipPath = Join-Path $release $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# The zip is the installer's own exe, zipped on its own: that is what an update unpacks over
# the install folder, and it is why the two artifacts can never be different builds.
Compress-Archive -Path $exe -DestinationPath $zipPath -Force

$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$size = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)

# -Direct: the same zip, put where the manifest says it is. It is copied rather than moved
# so `release\` still holds the whole build, which is what gets attached to a release later
# if somebody wants the installer and the zip from one download.
if ($Direct) {
    Step "Staging $zipName in updates\"
    New-Item -ItemType Directory -Force -Path $updates | Out-Null
    Copy-Item $zipPath (Join-Path $updates $zipName) -Force
    Write-Host "  updates : $(Join-Path $updates $zipName) ($size MB) - commit this file with the manifest"
}

# The installer ships too, under its version, for anybody who wants to put the app on a
# machine properly rather than update a copy that is already there. The app itself never
# fetches this; it is attached so the release holds the complete build rather than half of
# it, and so the file can be handed to somebody as a link.
$msiPath = Join-Path $release $msiName
Copy-Item $msi $msiPath -Force
$msiSize = [math]::Round((Get-Item $msiPath).Length / 1MB, 1)

# ---- Manifest ------------------------------------------------------------------------
Step "Writing appcast.xml"
$changelog = "https://github.com/$Owner/$Repo/releases"

$where = if ($Direct) {
    @"
  The zip this names is committed in this repository, at updates\$zipName, and served raw
  from main. Pushing this file and that one together is the whole release: the manifest and
  the build it points at go live at the same moment, so no copy of the app can read a
  version whose download is not there yet.

  This manifest lives at updates\appcast.xml, which is the URL every released build checks
  for it and the one path that flow has to keep: an installed copy cannot be told that the
  manifest moved.
"@
}
else {
    @"
  The zip is attached to the release tagged $tag in this repository. The manifest is served
  raw from main, so this file and the release it names have to be published together, the
  release first — every copy of the app that reads this URL before the asset is there
  downloads nothing and waits for the next launch.

  It lives at updates\appcast.xml, the path every released build checks for it. The zip is
  free to be attached rather than committed; the manifest's path is not free to change.

  The installer for this release is attached beside the zip, unchanged for the app's own use:
    $msiUrl
"@
}

$manifest = @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Written by release.ps1 for Glass Tweaks $label. Do not edit by hand: run the script
  again so the version, the file names and this checksum stay in step.

$where
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
# It goes to updates\appcast.xml in both flows: that is the URL the app reads, and the zip
# it names is free to be committed beside it or attached to a release.
$manifestPath = Join-Path $updates 'appcast.xml'
New-Item -ItemType Directory -Force -Path $updates | Out-Null
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
if ($Direct) {
    Write-Host "  Publish it - one push, and every copy of the app picks it up on its next open:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "       git add updates/appcast.xml updates/$zipName"
    Write-Host "       git commit -m `"Release Glass Tweaks $label`""
    Write-Host "       git push"
    Write-Host ""
    Write-Host "  Both files go in one commit on purpose: the manifest is served raw from main, so it"
    Write-Host "  is live the moment the push lands, and it must never be live before the zip it names."
    Write-Host ""
    Write-Host "  The installer is staged but not committed - attach it to a release tagged $tag"
    Write-Host "  if you want the complete build in one place:" -ForegroundColor Gray
    Write-Host "       gh release create $tag `"$zipPath`" `"$msiPath`" --title `"Glass Tweaks $label`"" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Check what is live, from this folder:  ./release.ps1 -SkipBuild -Verify"
    Write-Host ""
}
else {
    Write-Host "  Publish it - in this order, the attachments first:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Attach both files to a release tagged $tag."
    Write-Host "     On the web:   github.com/$Owner/$Repo/releases/new"
    Write-Host "                   tag: $tag      title: Glass Tweaks $label"
    Write-Host "                   drop in: $release\$zipName"
    Write-Host "                            $release\$msiName"
    Write-Host "     With the CLI: gh release create $tag `"$zipPath`" `"$msiPath`" --title `"Glass Tweaks $label`""
    Write-Host ""
    Write-Host "  2. Publish the manifest that names it:"
    Write-Host "       git add $manifestRepoPath"
    Write-Host "       git commit -m `"Release Glass Tweaks $label`""
    Write-Host "       git push"
    Write-Host ""
    Write-Host "  3. Check what is live, from this folder:"
    Write-Host "       ./release.ps1 -SkipBuild -Verify"
    Write-Host ""
    Write-Host "  The order matters. The manifest is served raw from main, so it goes live the moment"
    Write-Host "  the push lands, and every copy of the app that reads it before the zip is attached"
    Write-Host "  downloads nothing and waits for its next launch."
    Write-Host ""
}
Write-Host "  To watch it happen on a machine, run the app and look at %APPDATA%\GlassTweaks\update.log."
