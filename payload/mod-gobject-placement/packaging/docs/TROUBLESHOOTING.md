# Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `running scripts is disabled on this system` | Run `Set-ExecutionPolicy -Scope Process Bypass` in that PowerShell window first (affects only that window). |
| `No AFK Realm server folder found` | The installer reads AFK Realm's settings (`%APPDATA%\AFK-Realm\servers.txt`) and searches two folder levels on fixed drives. Type the server folder (with `Dependencies`, `Server`, `DB`) or the AFK Realm program folder (with `engine\engine.ps1`), or pass `-InstallRoot`. |
| `... is the AFK Realm program folder, and AFK Realm's settings name no server folder` | You gave the program folder (e.g. `C:\!AFK\AFK-Realm-main`). Type the server folder AFK Realm installed into (AFK Realm shows it on its server page; default `C:\CoA-Server`). |
| `... is not an AFK Realm server folder` | The folder lacks `Dependencies\Source` or `Server`. Pick the server folder, not the game client or a backup. |
| `No AFK Realm engine found for this server` | Neither `<server>\Builder\AFK-Realm-Engine.ps1` nor an AFK Realm program folder was found. Open the server once in AFK Realm (it extracts its engine there), or pass `-EnginePath "<AFK Realm folder>\engine\engine.ps1"`. |
| `Several AFK Realm program folders were found` | Pass `-EnginePath` with the `engine\engine.ps1` of the AFK Realm you use. |
| `This AFK Realm engine has no module mode` | Your AFK Realm is too old. Update AFK Realm, or install by hand (below). |
| `Incompatible core: '...' not found` | The core changed an interface the module uses. Do not install; report the line. |
| `Another command already uses .gobject pitch/roll/save` | Another module or core change registers the same command. Installing would make the server stop at start. Remove one of them. |
| `already installed` | The folder `Dependencies\Source\modules\mod-gobject-placement` exists or AFK Realm lists the module. Uninstall first. |
| `... exists but holds a different commit` | A staged copy from another package version. Move `Dependencies\LocalModules\mod-gobject-placement.git` elsewhere, run again. |
| `The server is running` | Stop worldserver and authserver (AFK Realm app, or close their windows), run the installer again. It reuses the staged copy. |
| `AFK Realm needs administrator rights` | Start PowerShell with *Run as administrator* and run again. |
| `Revision ... was not compiled with this package` | Only a warning. AFK Realm's build decides: if it fails, AFK Realm takes the module out again and keeps your server as it was. |
| AFK Realm: `The server could not be built with mod-gobject-placement` | Compile error with your core version. Nothing was installed. Send the first `error C` line of `<install>\logs\install.log`. |
| AFK Realm: `The backup before the module change failed` | Usually disk space (3 GB minimum). Nothing was changed. |
| AFK Realm: `A database file of the module ... failed` | SQL error; AFK Realm recorded what it did. Run the uninstaller to undo it, then report `logs\install.log`. |
| After installing, `.gobject pitch` says *There is no such command* | The worldserver running is not the newly built one (started too early, or another install). Restart the server; check `Server\worldserver.exe` date. |
| `.gobject pitch` says *object not found* | Stand near the object: it must be loaded on your current map. Use the spawn guid from `.gobject near`, not the entry id. |
| Tilt not visible | Make sure the reply says *Pitched*/*Rolled*. Move away and back. The object is respawned with a new GUID like `.gobject turn` does. |
| Server log: `Table command contains data for non-existant command 'gobject pitch'` | Help rows left after a hand removal. Harmless; the uninstaller removes them. |
| Uninstaller: `Database part skipped` | You declined starting the database. Run the uninstaller again later, or load the dump by hand (ROLLBACK.md, step 3). |

## Manual installation (only if the installer cannot be used)

1. Stop the server. Make a backup in the AFK Realm app (*Backup*).
2. Copy `payload\mod-gobject-placement` to `<install>\Dependencies\Source\modules\mod-gobject-placement`.
3. Build at your current revision **without** updating the core:
   ```powershell
   & "<install>\Dependencies\CMake\bin\cmake.exe" -S "<install>\Dependencies\Source" -B "<install>\Dependencies\Build"
   & "<install>\Dependencies\CMake\bin\cmake.exe" --build "<install>\Dependencies\Build" --config RelWithDebInfo --target INSTALL --parallel 2
   ```
   (Do not use AFK Realm *Rebuild* or *Install* for this: they first move the core to the newest GitHub version.)
4. Start the server. The world server's updater applies the module SQL by itself (verified), but AFK Realm
   does not record it: the uninstaller will leave the placement tables in place and remove the help rows.
5. AFK Realm *Update* keeps the folder (its `git clean` excludes `modules/`, and the core's `.gitignore`
   ignores `modules/*`), and rebuilds it with each update.

## Logs

* Installer/uninstaller: printed in the window only.
* AFK Realm: `<install>\logs\install.log`.
* World server: `<install>\Server\Server.log`, `Errors.log`, `DBErrors.log`.
