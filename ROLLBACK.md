# Rollback

Pick the smallest step that solves the problem.

## 1. Undo one tilted object

The module never undoes rotations by itself. Each spawn's original rotation (before this module first
touched it) is in `acore_characters.gobject_placement_baseline`.

* In game: `.gobject turn <guid> <yaw>` sets the object upright again (pitch and roll 0).
  Note: core `turn` rewrites the whole `gameobject` row (drops ScriptName/Comment/zoneId/areaId).
* Or by SQL, world server stopped, for one guid:
  ```sql
  UPDATE acore_world.gameobject g
    JOIN acore_characters.gobject_placement_baseline b ON b.guid = g.guid AND b.entry = g.id AND b.map = g.map
     SET g.rotation0 = b.rotation0, g.rotation1 = b.rotation1, g.rotation2 = b.rotation2, g.rotation3 = b.rotation3
   WHERE g.guid = <guid>;
  ```

## 2. Remove the module, keep everything else (normal uninstall)

Administrator PowerShell, server stopped, in the extracted package folder:

```powershell
.\Uninstall-GObjectPlacement.ps1            # -CheckOnly first to see the preview
```

* Dumps `acore_characters.gobject_placement_*` to `<install>\Backups\gobject-placement\placements-<time>.sql`.
* Runs AFK Realm `-Mode Modules -RemoveModules mod-gobject-placement`: snapshot, rebuild without the module,
  programs replaced after a successful build, recorded SQL undone (help rows removed; **AFK Realm drops the
  three placement tables** because the module created them).
* Loads the dump back, so the records stay (row counts are checked).
* Gameobject rows are never changed: tilted objects stay tilted.

`-RemovePlacementData` (separate `DELETE` confirmation) leaves the tables removed; the dump is still written.

A rebuild is always required to remove the commands (they are compiled into worldserver.exe).

## 3. Load a placement dump by hand

```powershell
Get-Content "<install>\Backups\gobject-placement\placements-<time>.sql" -Raw |
  & "<install>\DB\mysql\bin\mysql.exe" --defaults-extra-file="<install>\DB\launcher.cnf" acore_characters
```

The dump drops and recreates only the three `gobject_placement_*` tables.

## 4. Return the whole server to the state before installing

AFK Realm made a snapshot (`<install>\Backups\<date_time>`, reason `before module change`) right before it
installed the module. In the AFK Realm app use *Restore* on that snapshot, or (administrator PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File <install>\Builder\AFK-Realm-Engine.ps1 -InstallRoot <install> -Mode Restore -Snapshot <date_time>
```

This restores programs, configs and **all databases** to that moment: anything players did since is lost.
Prefer step 2 unless the server is broken.

## 5. Leftovers you may delete by hand (never deleted automatically)

* `<install>\Dependencies\LocalModules\mod-gobject-placement.git` (staged copy; a reinstall reuses it).
* `<install>\Backups\gobject-placement\*.sql` (placement dumps).
