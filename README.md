# Glass Tweaks — updates

This repository does one job: it tells a copy of **Glass Tweaks** that a newer build
exists, and hands it the file. The app checks it on launch, and when the version here is
higher than the one it is running it downloads the new build, closes, swaps its own files
and opens again — with nothing to click.

Everything published lives in one folder:

```
updates/
  appcast.xml                  the manifest: which version is newest, and where the file is
  GlassTweaks-0.3.0.zip        the release itself, one per version
```

You never have to touch `updates/` by hand. `release.ps1` builds the app, zips it, hashes
it and writes the manifest next to it.

## How the app uses this

The app reads one file, served raw from the `main` branch:

```
https://raw.githubusercontent.com/Ayaan192/glasstweaksupdater/main/updates/appcast.xml
```

`raw.githubusercontent.com` is deliberate. It needs no release API, no authentication and
no rate-limit token — it is the same URL a browser would fetch — so the check keeps working
on any machine, signed in or not.

The whole exchange is two requests: the manifest, and then the zip if the manifest names a
newer version. Nothing else about the app is ever uploaded or shared.

## What happens on the machine

Nobody presses anything. In order:

1. **The app opens.** The window appears first and the check runs behind it, so a slow or
   unreachable GitHub cannot delay startup. A check happens at most once every six hours.
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

Create an empty **public** repository called `glasstweaksupdater` on GitHub — the one-click
link is <https://github.com/new?name=glasstweaksupdater&visibility=public> — then put this
folder into it:

```powershell
cd glasstweaksupdater
git init -b main
git add .
git commit -m "Add the Glass Tweaks update manifest"
git remote add origin https://github.com/Ayaan192/glasstweaksupdater.git
git push -u origin main
```

Public matters. The app fetches the manifest and the zip as plain files with no credentials,
so a private repository would answer every check with a 404.

That first push ships the placeholder manifest, which is fine but pointless on its own: it
names a zip that is not in the repository yet. For a repository that starts out complete,
raise the version and cut a release **before** pushing, so the first thing on `main` is a
manifest and the zip it points at, ready to hand older copies their update.

### Every release, from then on

Three steps. There is no build server, no upload form and no deploy step.

**1. Raise the version** — in the app project, `windows/app/GlassTweaks.csproj`:

```xml
<Version>0.3.0</Version>
```

That one value is the version the app reports, the version the manifest is compared
against, and the version the zip is named after. It is the only place to change.

**2. Cut the release** — from *this* folder:

```powershell
./release.ps1
```

It publishes the app, wraps the exe in a zip, hashes it, and writes `updates/appcast.xml`
so it names that zip under the new version. It reads the version straight from the project
file, so the release cannot be labelled one version in the manifest and another in the exe.
If you pass `-Version` it must match the project, and the script refuses the release if it
does not — that mismatch is precisely how you publish an update no copy of the app will
ever notice.

The build is staged in `build/`, which is ignored; only the finished zip is written into
`updates/`.

**3. Push it** — the script prints these lines with the right names filled in:

```powershell
git add updates/appcast.xml updates/GlassTweaks-0.3.0.zip
git commit -m "Release Glass Tweaks 0.3.0"
git push
```

The release is live the moment the push lands, because the manifest is served straight from
the `main` branch. Any copy of Glass Tweaks older than 0.3.0 picks it up on its next launch.

> The zip is around 60 MB, and it is committed on purpose: the app downloads it from the raw
> URL, so it has to be in the repository. Expect the repository to grow by that much per
> release.

## What the manifest means

```xml
<item>
  <version>0.3.0.0</version>
  <url>.../updates/GlassTweaks-0.3.0.zip</url>
  <mandatory mode="2">true</mandatory>
  <checksum algorithm="SHA256">…</checksum>
</item>
```

- **version** is compared against the running app's assembly version. It must be strictly
  higher, in `X.X.X.X` form. This is the only thing that decides whether anything happens.
- **url** is the zip the app downloads itself.
- **mandatory mode="2"** is what makes the update run without a dialog. The app also sets
  this in code, so a manifest that asked for buttons could not turn them back on.
- **checksum** is verified before the zip is unpacked, so a half-downloaded or altered file
  is refused rather than applied.

## The zip's shape

The zip contains **`GlassTweaks.exe` at its root**, because it is unpacked straight over the
install folder. A self-contained single-file build is exactly this: one exe, no runtime to
install, nothing beside it. `release.ps1` produces it in that shape.

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
$env:GLASSTWEAKS_APPCAST = 'http://127.0.0.1:8000/updates/appcast.xml'
& "$env:LOCALAPPDATA\Programs\GlassTweaks\GlassTweaks.exe"
```

## When nothing happens

That is the normal case, and it is meant to be quiet. A machine that is offline, behind a
proxy that blocks GitHub, or already on the newest build opens exactly as it always did —
the check runs in the background, says nothing on screen, and writes one line to the log. A
download that fails partway leaves the running copy untouched and says so once, in the app's
own window, with a Close button.

The check is throttled to once every six hours, so opening the app repeatedly does not hammer
GitHub. The timestamp lives in `%APPDATA%\GlassTweaks\update.json`; deleting that file makes
the next launch check immediately.
