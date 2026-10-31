# mod-gobject-placement 1.0.0 - installation package

Adds three GM commands (level 3, like `.gobject turn`) to an AFK Realm / CoACore server:

```
.gobject pitch <guid> <degrees>   tilt about the object's own Y axis (positive = front down)
.gobject roll  <guid> <degrees>   tilt about the object's own X (forward) axis
.gobject save  <guid>             record the spawn's current placement as verified
```

Full command reference and design: `payload\mod-gobject-placement\README.md`.

## What is in this folder

| Path | Purpose |
| --- | --- |
| `Install-GObjectPlacement.ps1` | Checks, preview, then installs through AFK Realm's module system |
| `Uninstall-GObjectPlacement.ps1` | Removes it again; keeps placement records by default |
| `lib\` | Helpers used by both scripts |
| `payload\mod-gobject-placement.bundle` | The module as a Git repository (what AFK Realm installs) |
| `payload\mod-gobject-placement\` | The same module as plain files (source, SQL, tests) to read |
| `payload\COMMIT.txt` | The exact module commit |
| `tools\export_placements.py` | Read-only exporter of saved placements (never applies anything) |
| `COMPATIBILITY.md`, `TROUBLESHOOTING.md`, `ROLLBACK.md` | Details |
| `SHA256SUMS.txt` | Checksums of every file |

## How it installs (and why this way)

AFK Realm has its own module manager (`AFK-Realm-Engine.ps1 -Mode Modules`). It is the safest route:

* it takes a **backup snapshot** (server programs, configs, all databases) in `<install>\Backups\` first;
* it builds at the **current** core revision (it does not update the core from GitHub);
* it replaces `Server\worldserver.exe` **only if the build succeeds**; on failure it takes the module out
  again and the server stays as it was;
* it applies the module's SQL and **records** every change, so removing the module undoes it.

Its GUI only accepts `https://` module addresses, so the installer stages the module as a local Git
repository (`<install>\Dependencies\LocalModules\mod-gobject-placement.git`) and starts the engine with
`-AddModules file:///.../mod-gobject-placement.git`. Nothing is published anywhere.

A module folder copied in by hand would also work (its SQL is applied by the core's own updater, verified),
but AFK Realm would neither back up first nor record or undo its database changes.

## Installation steps (on the server PC)

1. Copy the ZIP to the server PC and extract it anywhere (e.g. `Downloads`).
2. Open **PowerShell as administrator** (Start menu, right-click PowerShell, *Run as administrator*).
3. Allow the script for this window and run it:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   cd "$env:USERPROFILE\Downloads\GObjectPlacement-1.0.0-xxxxxxxx"
   .\Install-GObjectPlacement.ps1
   ```
   Optional first: `.\Install-GObjectPlacement.ps1 -CheckOnly` (checks and preview only, changes nothing).
4. Pick your AFK Realm **server** from the list. The list comes from AFK Realm's own settings
   (`%APPDATA%\AFK-Realm\servers.txt`) plus a search of your drives. You can also type a path:
   * the **server folder** (the one with `Dependencies`, `Server`, `DB`; AFK Realm's default is `C:\CoA-Server`), or
   * the **AFK Realm program folder**, e.g. `C:\!AFK\AFK-Realm-main` (the one with `engine\engine.ps1`). The
     installer then takes the server folder from AFK Realm's settings, asking if there are several.

   Or pass it directly: `.\Install-GObjectPlacement.ps1 -InstallRoot "C:\!AFK\AFK-Realm-main"`.

   The AFK Realm engine it uses, shown in the checks: the copy AFK Realm keeps in `<server>\Builder` (the version
   that last ran on this server); otherwise `engine\engine.ps1` of the program folder. Force one with
   `-EnginePath "C:\!AFK\AFK-Realm-main\engine\engine.ps1"`.
5. Read the checks and the preview. Any `[FAIL]` stops the installer with nothing changed.
6. Answer `y` to stage the module (creates only `Dependencies\LocalModules\mod-gobject-placement.git`).
7. **Stop the server when you are ready** (AFK Realm app, or close the worldserver and authserver windows).
   If it is still running, the installer stops here, leaves it running, and tells you to come back;
   running it again reuses the staged copy.
8. Type `INSTALL` to let AFK Realm back up, build (10-40 minutes) and install. AFK Realm asks for your
   **database password** itself; this package never sees, stores or logs it.
9. When it says `Installed.`, start the server when you choose (AFK Realm app or `START-SERVER.cmd`).
10. In game: `.help gobject pitch`, then the checks below.

Installing **requires recompiling** the server (AFK Realm does it) and **the server must be stopped** for
step 8. Steps 1-7 do not touch the running server.

### Watch out: AFK Realm prunes old snapshots

AFK Realm keeps only the newest N snapshots (default 3; `keep=` in `Dependencies\backup-settings.txt`).
The snapshot it makes before installing can remove the oldest one. The installer's preview names the
snapshot that would go; copy it elsewhere first if you want to keep it.

## In-game check

1. `.help gobject pitch|roll|save` print syntax.
2. Near an object: `.gobject near` -> guid G. `.gobject pitch G 15` -> tilts at once. `.gobject pitch G -15` -> back.
3. `.gobject roll G 10` / `.gobject roll G -10`.
4. `.gobject turn G`, then `.gobject pitch G 10`, `.gobject roll G 20` -> reply shows pitch 10, roll 20.
   (`.gobject turn G` alone resets pitch and roll: core behaviour.)
5. `.gobject save G` twice -> `acore_characters.gobject_placement_history` has 2 rows for G.
6. Restart the server -> G is still tilted.
7. `.gobject pitch 999999999 5`, `.gobject pitch G 0`, `.gobject pitch G 400` -> rejected with a message.

These commands have **not yet been tested in game**; the package was compiled and its install/uninstall
flow was tested against an isolated copy (see COMPATIBILITY.md).

## Exporting saved placements (optional, never automatic)

```powershell
python tools\export_placements.py --mysql <install>\DB\mysql\bin\mysql.exe --defaults-file <install>\DB\launcher.cnf `
    --database acore_characters --sql placements.sql --toml placements.toml
```

Writes review files only (SQL guarded by guid + entry + map; Worldforged Placement Fixes manifest entries, all
disabled). It never executes SQL against the world database.

## Uninstalling

Administrator PowerShell, server stopped: `.\Uninstall-GObjectPlacement.ps1`. See ROLLBACK.md.
