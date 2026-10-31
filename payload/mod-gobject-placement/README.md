# mod-gobject-placement

Three GM commands for AFK Realm / CoACore that tilt any database-spawned gameobject and record its
verified placement:

```
.gobject pitch <guid> <degrees>
.gobject roll  <guid> <degrees>
.gobject save  <guid>
```

Built and tested against core `jealous-sound/azerothcore-wotlk-coa` `3f17c961` (the revision in
`H:\CoA-Server\Dependencies\Source`). Standalone module; no core file is changed.

## Command reference

| Command | Effect |
| --- | --- |
| `.gobject pitch <guid> <deg>` | Rotates the object about **its own Y axis** by `deg` (positive = front tips down). Adds to the current rotation. |
| `.gobject roll <guid> <deg>` | Rotates the object about **its own X (forward) axis** by `deg`. Adds to the current rotation. |
| `.gobject save <guid>` | Records the spawn's current placement as verified. Moves nothing. |

* `<guid>` is the spawn guid (`gameobject.guid`, as shown by `.gobject near` / `.gobject target`) or a
  shift-clicked gameobject link. `<deg>`: non-zero, finite, at most ±360.
* Pitch/roll: the object must be loaded on your current map (stand near it). Each step is applied to the
  object's current rotation, renormalised, written to the four `rotation0-3` columns of that one
  `gameobject` row, and the object is respawned at once so the client shows it (same mechanism as
  `.gobject turn`). The reply shows the new quaternion and the resulting yaw/pitch/roll.
* Save: works for any loaded spawn data (you need not stand near it). The reply shows what was stored.
* GM level 3, the effective level of `.gobject turn` on this server. `.help gobject pitch|roll|save` works.

Typical use: `.gobject turn` (or move) first to set facing, then `pitch`/`roll` to tilt, then `save`.

## Design decisions

**Standalone module.** The core builds its command tree by merging every `CommandScript`'s table
(`ChatCommandNode::LoadCommandsIntoMap`, `src/server/game/Chat/ChatCommands/ChatCommand.cpp:47`), so a module
can register `pitch`/`roll`/`save` under the existing `gobject` node without touching `cs_gobject.cpp`.
The names do not collide with existing subcommands.

**Rotation maths.** A gameobject's rotation is the quaternion `GameObject::WorldRotation`, stored as
`gameobject.rotation0..3` (x, y, z, w). `.gobject turn z y x` builds it from Euler angles Z-Y-X
(`G3D::Matrix3::fromEulerAnglesZYX`). Pitch/roll post-multiply a local axis-angle step: `q' = q · R(axis, θ)`.
This is exactly "rotate about the object's own axis", never resets an earlier yaw, pitch or roll, and for
yaw → pitch → roll gives the same result as `.gobject turn yaw pitch roll`. Results are unit length with w ≥ 0
(q and -q are the same rotation; one sign keeps stored values comparable). An all-zero stored rotation
is treated as the orientation, as the server itself does (`GameObject::SetWorldRotation`).

**Persistence.** `.gobject move/turn` persist via `GameObject::SaveToDB`, which **deletes and re-inserts**
the row with only 16 columns, so `ScriptName`, `Comment`, `VerifiedBuild`, `zoneId` and `areaId` are lost.
Pitch/roll instead update the in-memory spawn data and run
`UPDATE gameobject SET rotation0..3 WHERE guid = ?`: only that spawn's rotation changes. Orientation,
position, template and other spawns of the same entry are untouched.

**Visible refresh.** The 3.3.5a client ignores new rotation for a GUID it has cached, so the object is
despawned and recreated from the updated spawn data under a new GUID, the same approach as core
`.gobject turn`.

**Saved placements live in the characters database**, not the world database, so a rebuilt or re-imported
world database (an AFK Realm update or restore) cannot erase them. Three tables:

| Table | Content |
| --- | --- |
| `gobject_placement_verified` | Latest save per guid: guid, entry, map, `ScriptName` (the row's own column), x, y, z, orientation, rotation0-3, account, timestamp, revision (save count). |
| `gobject_placement_history` | Every save ever made (append only): the recovery path for a mistaken resave. |
| `gobject_placement_baseline` | The placement as it was the first time this module touched the guid (first pitch, roll or save). Never overwritten. Becomes the "expected" state when exporting. |

Spawn guids are not trusted alone: entry, map and script name are stored with every record, and exports
match on guid + entry + map.

## Export (explicit, read only)

`tools/export_placements.py` (Python 3.11+, stdlib only) runs one `SELECT` on the characters database
through the mysql client, or reads a saved `mysql --batch` result, and writes review files. It never
executes anything against the world database and refuses to overwrite existing files.

```bat
python tools\export_placements.py --mysql H:\CoA-Server\DB\mysql\bin\mysql.exe ^
    --defaults-file <your option file> --database acore_characters ^
    --sql placements.sql --toml placements.toml [--guid 6940236 ...]
```

* `--sql`: one `UPDATE gameobject SET position, orientation, rotation0-3 WHERE guid AND id AND map` per
  saved spawn. Apply only by hand, with the world server stopped and a backup taken.
* `--toml`: `move` corrections in the Worldforged Placement Fixes manifest format
  (`format_version = 1`, `acore-gameobject-v1`), **all `enabled = false`**, id `GP-<guid>-r<revision>`,
  `expected` = baseline, `final` = verified, `script_name` when the row has one. Spawns without a baseline
  or with no change are skipped (reported on stderr). Validated with that runner's own `parse_document`.
  Before enabling one, confirm its `expected` block is the upstream placement: if you used
  `.gobject move/turn` on a spawn before this module first touched it, that change is already in the baseline.

The Worldforged correction module itself was not modified.

## Installation

**Use the installation package** (built by `packaging\Build-Package.ps1`; instructions in
`packaging\docs\README.md`). It installs through AFK Realm's own module manager: backup snapshot first, build
at the current core revision, rollback on build failure, recorded and undoable SQL. The manual steps below
remain as a fallback; they bypass AFK Realm's backup and SQL record.

Manual fallback, with the world server **stopped**:

1. Copy this folder (without `tests/`, `tools/` if you like) to
   `H:\CoA-Server\Dependencies\Source\modules\mod-gobject-placement`.
   The AFK Realm launcher's source sync runs `git clean` with `-e modules/`, so it keeps this folder;
   keep your own master copy anyway.
2. Rebuild **without** AFK Realm *Rebuild*/*Install* (those first move the core to the newest GitHub revision):
   re-run CMake on the existing build folder, then
   `cmake --build H:\CoA-Server\Dependencies\Build --config RelWithDebInfo --target INSTALL`.
3. Start the server. With `Updates.EnableDatabases = 7` (your setting) the world server's updater applies,
   once each:
   * `data/sql/db-characters/2026_10_28_00_gobject_placement.sql`: creates the three tables
     (`CREATE TABLE IF NOT EXISTS`).
   * `data/sql/db-world/2026_10_28_00_gobject_placement_commands.sql`: help text, 3 rows in `command`
     (deletes/inserts only those three names).
4. In game: `.help gobject pitch` should print the syntax.

## Database migration

Only the two files above. No existing table or row is altered; `gameobject` rows change only when you run
`pitch`/`roll` on them.

## Rollback

1. Undo tilts: each touched spawn's original rotation is in `gobject_placement_baseline`. For one spawn,
   in game: `.gobject turn <guid> <yaw> 0 0` restores an untilted object (note that `turn` rewrites the whole
   row; see limitations), or by SQL with the server stopped:
   `UPDATE acore_world.gameobject g JOIN acore_characters.gobject_placement_baseline b ON b.guid = g.guid AND b.entry = g.id AND b.map = g.map SET g.rotation0 = b.rotation0, g.rotation1 = b.rotation1, g.rotation2 = b.rotation2, g.rotation3 = b.rotation3 WHERE g.guid = <guid>;`
2. Remove the module: delete `modules\mod-gobject-placement` from the core source and rebuild.
3. Optionally remove its data: `data/sql/manual/uninstall.sql` lists the statements (help rows, the three
   tables, their `updates` entries). Dump the tables first; dropping them deletes all saved placements.

## Testing

| Suite | How | Result (2026-10-28) |
| --- | --- | --- |
| Compile | Full RelWithDebInfo builds of core `3f17c961` and of upstream `3c6e24e4` (2026-10-28) + all their modules + this module, same toolchain/flags as AFK Realm (`I:\gobject-placement-dev`) | `worldserver.exe` linked both times; no warnings or errors from this module |
| SQL route | Worldserver built with the module, started against a disposable database | Core updater applies the module SQL by itself (state `MODULE`) |
| Package | `tests\packaging\Run-PackagingTests.ps1` (isolated AFK Realm copy, real engine module code) | 86 checks pass in both AFK Realm layouts (1.0.5 server folder, 1.1.6 program folder); see `packaging\docs\COMPATIBILITY.md` |
| Quaternion maths | `tests\run_math_test.cmd` (links the core's own `g3dlib`) | 24 checks pass: ± pitch, ± roll, inverse steps, 5×1° = 5°, 72×5° = 360°, 10 000 mixed steps stay unit length, yaw→pitch→roll = `.gobject turn` Z-Y-X, roll keeps the forward axis, pitch keeps an existing roll, normalisation, sign, zero-rotation fallback, invalid degree values |
| Exporter | `python -B -m unittest discover -s tests -p "test_export.py"` | 9 pass on Python 3.11 and AFK Realm's embedded 3.13.15, including validation by the Worldforged runner's parser |
| Database | `tests/test_sql.py` against a disposable MySQL 8.4.9 (port 3398, own data dir) with the core's real `gameobject` and `command` schemas | 6 pass: migrations re-run cleanly; the rotation UPDATE changes only the 4 rotation columns of one row (ScriptName/Comment kept; same-entry spawn and every other row unchanged); baseline written once; resave → revision 2 with both saves in history; script-name escaping; exporter reads the tables and its SQL applies correctly |

```bat
set GP_TEST_MYSQL=H:\CoA-Server\DB\mysql\bin\mysql.exe
set GP_TEST_PORT=3398
python -B -m unittest discover -s tests -v
```

**Not tested: running the commands in a live worldserver.** CoA's worldserver needs the CoA client's own
DBC files, which can only be extracted from the game client. The only client on this PC is your protected
play client, so no worldserver was started. Unverified until you test in game: command registration and
help, the respawn after pitch/roll (same code path as `.gobject turn`), the in-game error messages,
and that the client shows the tilt.

### In-game acceptance checklist (after installing on a test copy, or the real server when you choose)

1. `.help gobject pitch`, `.help gobject roll`, `.help gobject save` print syntax.
2. Near a pickup: `.gobject near` → guid G. `.gobject pitch G 15` → object tilts at once; reply shows pitch 15.
3. `.gobject pitch G -15` → back upright. `.gobject roll G 10`, `.gobject roll G -10` likewise.
4. `.gobject turn G` then `.gobject pitch G 10` then `.gobject roll G 20` → reply shows yaw from the turn,
   pitch 10, roll 20.
5. `.gobject save G` twice → `SELECT * FROM acore_characters.gobject_placement_history WHERE guid = G` has 2 rows;
   `..._verified` has revision 2.
6. Restart the world server → G is still tilted.
7. `.gobject pitch 999999999 5` → "object not found"; `.gobject pitch G 0` / `G abc` / `G 400` → rejected.
8. Another spawn of the same entry is unchanged.

## Known limitations

* Core `.gobject turn <guid>` with only a yaw **resets pitch and roll to 0** (it rebuilds the rotation from
  the three angles it is given). Turn first, then pitch/roll; or pass all three: `.gobject turn G yaw pitch roll`
  (radians). Also, `turn`/`move` rewrite the whole row and drop `ScriptName`, `Comment`, `VerifiedBuild`,
  `zoneId`, `areaId` (core behaviour, unchanged by this module).
* Pitch/roll leave the `orientation` column as it was (it is the heading used for server-side facing; the
  client draws the quaternion).
* Refused: transports (types 11, 15), destructible buildings (respawning would reset their damage state),
  objects riding a transport, temporary/summoned objects (no spawn row).
* Pooled and game-event objects are respawned the same way `.gobject turn` respawns them.
* The change applies to the spawn's data, so every instance copy of an instanced spawn gets it on next load.
* An upstream SQL update can rewrite a spawn's rotation later; that is what `save` + export are for.
* The baseline is captured only when this module first touches a spawn (see Export).
* Saving records persisted spawn data; it does not read client-side visuals.

## Readiness

Code complete, compiled into the real worldserver, maths and database behaviour tested. **Ready for a
trial installation, not proven in game**: install with a world database backup, run the checklist above,
and keep the rollback steps at hand.

## Files

```
src/GObjectPlacementCommands.cpp   the three commands
src/GObjectPlacementMath.h         quaternion helpers (header only, unit tested)
src/GP_loader.cpp                  module loader (Addmod_gobject_placementScripts)
data/sql/db-characters/...         tables (auto-applied)
data/sql/db-world/...              help text (auto-applied)
data/sql/manual/uninstall.sql      rollback statements (never auto-applied)
tools/export_placements.py         explicit exporter
tests/                             math, exporter and database tests
```
