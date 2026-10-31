# Compatibility

## CoACore revisions

The module is C++ compiled **into** `worldserver.exe` (AFK Realm builds modules statically). There is no
separate binary to copy: every server compiles it from source, and AFK Realm does that during installation.

| Core revision (jealous-sound/azerothcore-wotlk-coa `main`) | Result |
| --- | --- |
| `3f17c961` (2026-10-20, the AFK Realm install on the development PC) | Full server build with all CoA modules: compiles and links, no warnings from the module. Maths, exporter and database behaviour tested. |
| `3c6e24e4` (2026-10-28, upstream head when packaged; 351 commits later) | Full server build: compiles and links, no warnings from the module. |
| Anything else | Not compiled. The installer checks the 10 core interfaces the module uses and warns; AFK Realm's build is the final check and puts everything back if it fails. |

Between the two tested revisions no file the module depends on changed in a way that affects it (only
additions to `ObjectMgr.h`).

## AFK Realm

* Needs an engine with `-Mode Modules` (module manager with SQL journal). Checked by the installer.
* Both layouts are supported and tested:

  | AFK Realm | Layout | Engine used |
  | --- | --- | --- |
  | 1.0.5 (classic `AFK-Realm.exe`, installed 2026-10-20) | server folder with `Builder\AFK-Realm-Engine.ps1` | that copy |
  | 1.1.6 (`main` of 2026-10-28, run from the program folder, e.g. `C:\!AFK\AFK-Realm-main`) | program folder with `engine\engine.ps1` + separate server folder | the server's `Builder` copy if present (the app extracts its engine there before every run), else the program folder's `engine\engine.ps1` |

  Both app versions start the engine the same way (`-File <engine> -InstallRoot <server folder> -Mode ...`); the
  engine finds `module-journal.sql` next to itself. In 1.1.6 every function this package relies on
  (`Edit-ModuleFolders` aside from a path-separator tweak, `Complete-ModuleChange`, `Invoke-ModuleSql`,
  `Undo-ModuleSql`, `Get-ModuleName`, `Sync-Repository`, `Assert-ServerStopped`, `Read-Password`) is unchanged
  from 1.0.5, `module-journal.sql` is byte-identical, and `-Mode Modules` still builds at the current core
  revision. The changes in `Update-Databases`, `New-Snapshot`, `Find-Updates` and `Invoke-ModulePatches` are
  cross-platform path handling and a safer fast-forward of modules during updates.
* AFK Realm updates keep the module: source syncs run `git clean -ffd -e modules/` and the core's own
  `.gitignore` ignores `modules/*` (verified with a dry run). As an AFK Realm-managed module it is also
  fast-forwarded from its origin (the staged local repository) during *Update*.
* AFK Realm *Rebuild* and *Install* move the core to the newest GitHub revision first; *Modules* (used by
  this package) and *Setup* do not.

## Database

* MySQL 8.x (AFK Realm ships 8.4.9). Schemas `acore_world` and `acore_characters`.
* New tables in `acore_characters` (`CREATE TABLE IF NOT EXISTS`): `gobject_placement_verified`,
  `gobject_placement_history`, `gobject_placement_baseline`.
* `acore_world.command`: 3 rows (`gobject pitch`, `gobject roll`, `gobject save`, level 3).
* No existing table is altered; no `gameobject` row is changed by installing.
* SQL handling, verified:
  * Installed through AFK Realm (this package): AFK Realm applies the files with its journal and records
    them in each database's `updates` table with the same hash the core updater computes, so the world server
    does not apply them again. Removal undoes them (and drops the tables; the uninstaller keeps a dump and
    loads it back).
  * Copied by hand: the world server's own updater applies them at start (state `MODULE`), with no record.

## PowerShell

Windows PowerShell 5.1 (built into Windows 10/11) and PowerShell 7. Scripts are ASCII only.

## Tested how (2026-10-28)

`tests\packaging\Run-PackagingTests.ps1` ran the packaged installer and uninstaller against isolated AFK Realm
copies in **both layouts** - a classic server folder with the real AFK Realm 1.0.5 engine, and a 1.1.6 program
folder (`engine\engine.ps1`) with a separate server folder that has no `Builder` copy - with core checkouts at
`3f17c961` and a disposable MySQL 8.4.9. The engines' own module code ran unchanged (only the backup snapshot and
compile skipped), and each run used the engine the installer resolved: **86 checks, 0 failed**, on Windows
PowerShell 5.1. Layout and selection: menu shows the server paths and their source; choosing by number or typed
path; program folder mapped to its server through AFK Realm's settings (one, several, none known); a folder of
neither kind and a missing engine stop cleanly without exceptions. For each layout: ZIP contents and checksums, no secrets, ASCII, parsing; installation detection
(read only, never enters folders named like a WoW client); check-only; cancellation at every question;
rollback of a failed staging; running server (stages only); not elevated; build failure inside AFK Realm
(module taken out, databases unchanged); install (clone, module list, SQL applied and journaled with the core
updater's hash, core revision unchanged); repeat install refused; uninstall keeping records (AFK Realm drops
the tables, the dump is loaded back, row counts equal, tilted gameobject row untouched, existing snapshots
untouched); reinstall; uninstall after reinstall (AFK Realm keeps pre-existing tables); data removal with its
own confirmation; a module copied in by hand (detected; uninstall keeps tables, removes help rows and update
entries); uninstall when not installed.

Separately verified by running a worldserver built with the module against a disposable database: the core
updater applies a hand-copied module's SQL by itself (state `MODULE`).

Not tested: PowerShell 7 (not installed here; the scripts avoid 7-only syntax), a real AFK Realm
`-Mode Modules` run with snapshot and compile (needs administrator rights and a real install), and the
commands in game.
