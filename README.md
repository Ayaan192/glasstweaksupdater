# Glass Tweaks — updates

This repository does one job: it tells a copy of **Glass Tweaks** that a newer build
exists, and hands it the file. The app checks it on launch, and when the version here is
higher than the one it is running it downloads the new build, closes, swaps its own files
and opens again — with nothing to click.

Everything published is one small file in the repository, and the build it names:

```
updates/appcast.xml                 the manifest: which version is newest, and where the file is
updates/GlassTweaks-<version>.zip   the build an update unpacks (with release.ps1 -Direct)
```

or, when the zip is attached to a release instead of committed:

```
GitHub Release  v0.3.0
  GlassTweaks-0.3.0.zip             the release itself — what the app updates from
  GlassTweaksSetup-0.3.0.msi        the installer for that same build, signed — for a fresh machine
```

The manifest is the part that cannot move. It is tiny, has to be readable by every copy of
the app with no credentials, and it is the one file a release has to change — so it is
committed and served raw from `main`. **Its path is a promise to every copy of the app
already installed**: an installed build was compiled with one URL in it and checks nothing
else, so a manifest published somewhere else is read by nobody, and the release quietly
reaches no machine at all. That is why it stays at `updates/appcast.xml` — the path 0.3.0
was built with — in every flow below. Only the zip's location may differ between releases:
committed beside the manifest (about 60 MB in the repository's history per release, in
exchange for publishing being one push), or attached to a release and served from its own
download URL, which keeps the repository small and can be deleted the day it stops mattering.

You never have to write either by hand. `release.ps1` builds the app and the installer from
that one build, signs both, zips the app, hashes it, stages the two files to attach and
writes the manifest that names them. The app only ever downloads the zip; the MSI is attached
beside it so the release holds the whole build and a link can be handed to somebody who does
not have the app yet.

## How the app uses this

The app reads one file, served raw from the `main` branch:

```
https://raw.githubusercontent.com/Ayaan192/glasstweaksupdater/main/updates/appcast.xml
```

`raw.githubusercontent.com` is deliberate. It needs no release API, no authentication and
no rate-limit token — it is the same URL a browser would fetch — so the check keeps working
on any machine, signed in or not. The zip it names is fetched from the release's own download
URL (`https://github.com/Ayaan192/glasstweaksupdater/releases/download/v0.3.0/GlassTweaks-0.3.0.zip`),
which needs no credentials either: a public repository's release assets are plain downloads.

The whole exchange is two requests: the manifest, and then the zip if the manifest names a
newer version. Nothing else about the app is ever uploaded or shared.

## What happens on the machine

Nobody presses anything. In order:

1. **The app opens.** The window appears first and the check runs behind it, so a slow or
   unreachable GitHub cannot delay startup. A check happens at most once every quarter hour,
   and a launch that could not reach the manifest bypasses that and tries again.
2. **The manifest is read** — one small XML file. Its `<version>` is compared with the
   version inside the running exe. If it is not higher, nothing else happens at all.
3. **The zip is downloaded** behind the app's own update window: the Glass Tweaks card with
   a progress bar, and no buttons.
4. **The zip is hashed.** If the file does not match the `<checksum>` in the manifest, it is
   discarded and the running copy is left exactly as it was.
5. **The app closes itself** and a temporary copy of it takes over — a program cannot
   overwrite its own executable while it is running, so the swap needs a second process.
6. **The new files are unpacked** over the install folder, replacing the old build.
7. **The app opens again**, on the new version. It never touches `%APPDATA%\GlassTweaks`,
   so every setting and saved original stays where it was.

If any step fails, the app is left on the version it started with and the next launch simply
checks again. A failed download is the only case that shows anything, and then only a small
window with a Close button.

Because the comparison is `manifest version > running version`, an older manifest can never
downgrade a machine: publishing 0.4.0 and then re-publishing 0.3.0 leaves every 0.4.0 copy
alone.

## Publishing a release

### Once, to set the repository up

Done: this repository is <https://github.com/Ayaan192/glasstweaksupdater>, public, with
`main` as its branch and `origin` already pointing at it:

```powershell
git remote -v
# origin  https://github.com/Ayaan192/glasstweaksupdater.git (fetch)
# origin  https://github.com/Ayaan192/glasstweaksupdater.git (push)
```

Public matters. The app fetches the manifest and the zip as plain files with no credentials,
so a private repository would answer every check with a 404 — the app would simply never see
a release. `main` is the branch the raw URL names, so the manifest has to be there, and the
file it names has to still be attached to its release: a release whose asset is deleted while
the manifest still points at it is a download that fails on every machine.

### Every release, from then on

Five steps. There is no build server and no deploy step: two files are uploaded and one is
committed.

**1. Raise the version** — in the app project, `windows/app/GlassTweaks.csproj`:

```xml
<Version>0.3.0</Version>
```

That one value is the version the app reports, the version the manifest is compared
against, and the version the zip is named after. It is the only place to change.

**2. Cut the release** — from *this* folder:

```powershell
./release.ps1 -Direct
```

`-Direct` is the flow that publishes with one push: the zip is copied into `updates\` next to
the manifest, and both are committed together. Leave it off to publish the zip as a release
asset instead, which keeps the repository small but needs the asset uploaded by hand (or with
the GitHub CLI) before the manifest is pushed.

One run produces every artifact of the release, from one build:

- the app, self-contained and signed, in `windows\dist`
- the installer built around that same exe, signed, carrying the same version
- `release\GlassTweaks-<version>.zip`, the signed exe on its own, which is what an update unpacks
- `release\GlassTweaksSetup-<version>.msi`, the same installer
- `updates\appcast.xml`, naming the zip under the new version with its SHA256 and the URL
  that carries it, at the one path every released build checks
- `updates\GlassTweaks-<version>.zip`, with `-Direct`, ready to be committed beside the
  manifest

`release\` is ignored by git. The MSI always goes there — it is never fetched by the app and
so never has to be committed — and the zip is copied out of it into `updates\` by `-Direct`,
which is the flow this repository publishes with.

It reads the version straight from the app project, so none of those can be labelled one
version in the manifest and another in the binary. The installer project reads the same
file, so the MSI never has to be raised separately — and if a stale one is ever handed to
the script, it reads the version out of the package's own Property table and refuses the
release rather than publishing an installer for a build the app never had. If you pass
`-Version` it must match the project, and the script refuses the release if it does not —
that mismatch is precisely how you publish an update no copy of the app will ever notice.

The way a release is written down drops trailing zeroes: `<Version>10.0.0</Version>` is
released as **v10**, `10.1.0` as **v10.1**, and `10.1.2` keeps all three parts, so the tag,
the file names and the manifest read the way the release is talked about while every copy of
the app still compares the four-part value. A minor release after 10 is therefore one line —
raise `<Version>` to `10.1.0` and run the script again.

Pass `-SkipBuild` to re-cut a release from the exe and MSI already in `windows\dist`, which
is what you want after fixing a typo in this script.

### Publishing a build that was made somewhere else

When the zip already exists — built on a machine that has the signing certificate, handed
over by somebody else — point this at it and write the manifest from it:

```powershell
./publish-uploaded.ps1 -Zip C:\build\GlassTweaks-0.4.0.zip
```

It does not build anything. It reads the version out of the exe **inside** the zip rather
than trusting the file name, checks that the zip has the one thing an update needs —
`GlassTweaks.exe` at its root, because it is unpacked over the install folder — stages a copy
under the name the URL will use, and writes the SHA256 the app verifies the download against.
Add `-DryRun` to see the manifest it would write and change nothing.

The checksum is the part that has to be right: a manifest with a wrong one makes every copy
of the app download the file and then throw it away, which looks exactly like nothing
happening. That is why both scripts compute it rather than asking anybody to paste it. The
manifest it writes goes to `updates/appcast.xml`, the same path `release.ps1` writes, whatever
it is that serves the zip.

**3. (Optional) attach the installer to a release** — tagged `v0.3.0`, carrying the two files
from `release\`. The app never fetches either of them: the MSI is for a fresh machine, and the
zip is already published under `updates\`. Attaching them anyway is what leaves one release
holding the complete build, and gives a link that can be handed to somebody.

```powershell
# with the GitHub CLI, if you have it
gh release create v0.3.0 "release\GlassTweaks-0.3.0.zip" "release\GlassTweaksSetup-0.3.0.msi" --title "Glass Tweaks 0.3.0"

# or on the web: github.com/Ayaan192/glasstweaksupdater/releases/new
#   tag v0.3.0, then drop the same two files in
```

With `-Direct` the tag and the asset names are only labels, because the manifest points at
`main` rather than at the release. Without it they are not free choices at all: the manifest's
URL is built from the version, so an asset attached under another name is a URL that
downloads nothing.

**4. Push the manifest** — the script prints these lines with the right names filled in:

```powershell
git add updates/appcast.xml updates/GlassTweaks-0.3.0.zip
git commit -m "Release Glass Tweaks 0.3.0"
git push
```

The manifest and the zip it names go in **one** commit and one push, so they are live at the
same moment and no copy of the app can read a version whose download is not there yet. That
is the whole reason `-Direct` exists: the order between an upload and a push cannot be got
wrong when there is nothing to upload.

Without `-Direct` the order matters and the manifest goes second — it is served straight from
`main`, so it goes live the moment the push lands, and every copy of the app that reads it
before the zip is attached downloads nothing and waits for its next launch.

**5. Check what is live** — not by assuming it, by fetching what a device fetches:

```powershell
./release.ps1 -SkipBuild -Verify
```

Add `-Direct` to that line to have it also confirm the zip URL this run would publish is the
one the live manifest names. Without it, a manifest published the other way is reported as a
note rather than a failure — the file it names is checked either way.

That reads the published manifest past GitHub's few-minute raw cache — at
`updates/appcast.xml`, the one path the app itself reads, whichever flow published the zip —
checks that it names this version, fetches the zip it names, and compares that file's size
**and its SHA256** with the zip staged here: the checksum is what the app verifies the
download against, so a release carrying the wrong one is a build every copy of the app
downloads and then throws away. It fails loudly, with what to fix. Any copy of Glass Tweaks
older than the version it names then picks the release up on its next launch; a copy already
on that version or newer does nothing at all.

## What the manifest means

```xml
<item>
  <version>0.3.0.0</version>
  <url>https://github.com/Ayaan192/glasstweaksupdater/releases/download/v0.3.0/GlassTweaks-0.3.0.zip</url>
  <mandatory mode="2">true</mandatory>
  <checksum algorithm="SHA256">…</checksum>
</item>
```

- **version** is compared against the running app's assembly version. It must be strictly
  higher, in `X.X.X.X` form. This is the only thing that decides whether anything happens.
- **url** is the release asset the app downloads itself — a plain https download from the
  release tagged for this version.
- **mandatory mode="2"** is what makes the update run without a dialog. The app also sets
  this in code, so a manifest that asked for buttons could not turn them back on.
- **checksum** is verified before the zip is unpacked, so a half-downloaded or altered file
  is refused rather than applied.

## The zip's shape

The zip contains **`GlassTweaks.exe` at its root**, because it is unpacked straight over the
install folder. A self-contained single-file build is exactly this: one exe, no runtime to
install, nothing beside it. `release.ps1` produces it in that shape, and it is the same file
the MSI attached to the same release carries — so a machine that installed from
`GlassTweaksSetup-0.3.0.msi` and a machine that updated from `GlassTweaks-0.3.0.zip` are
running the same binary, not two builds that happen to share a version number.

An update never touches `%APPDATA%\GlassTweaks`, which is where the app's own records live —
the originals it captured for every setting it changed, the game library, the boost log. The
new build opens with the user's machine exactly as the old one left it.

## Following it on a machine

The app writes one line per check to `%APPDATA%\GlassTweaks\update.log`:

```
2026-10-15 09:51:45  0.3.0.0 is available (this build is 0.2.0.0) · a newer build is published; it is being fetched now
2026-10-15 09:51:46  updating 0.2.0.0 -> 0.3.0.0 · the new build was fetched and is being put in place; the app restarts into it
```

The pass that swaps the files writes its own log to `%TEMP%\GlassTweaks-update.log`, because
by the time it runs the app it belongs to has already closed:

```
helper: unpacked update.zip into C:\Users\you\AppData\Local\Programs\GlassTweaks
helper: started the updated build
```

To try a release without publishing it, point a launch at a local manifest:

```powershell
$env:GLASSTWEAKS_APPCAST = 'http://127.0.0.1:8000/appcast.xml'
& "$env:LOCALAPPDATA\Programs\GlassTweaks\GlassTweaks.exe"
```

## When nothing happens

That is the normal case, and it is meant to be quiet. A machine that is offline, behind a
proxy that blocks GitHub, or already on the newest build opens exactly as it always did —
the check runs in the background, says nothing on screen, and writes one line to the log. A
download that fails partway leaves the running copy untouched and says so once, in the app's
own window, with a Close button.

The check is throttled to once every quarter hour, so opening the app repeatedly does not
hammer GitHub. The timestamp lives in `%APPDATA%\GlassTweaks\update.json`; deleting that file
makes the next launch check immediately.
