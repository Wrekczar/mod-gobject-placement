# GObject Placement Module — Installation Guide

**Version:** 1.0.0  
**For:** AFK Realm / CoACore servers  
**Access required:** GM level 3 (the same level as `.gobject turn`)

This package adds commands for tilting game objects and recording their verified placement. It installs through AFK Realm's module manager, which handles backups, compilation, and tracked database changes.

> **Testing status:** The package has been compiled, and its installation and removal process was tested against an isolated copy. See `COMPATIBILITY.md`.

## 1. New GM commands

| Command | What it does |
| --- | --- |
| `.gobject pitch <guid> <degrees>` | Tilts an object around its own Y axis. Positive values move the front downward. |
| `.gobject roll <guid> <degrees>` | Tilts an object around its own forward (X) axis. |
| `.gobject save <guid>` | Records the object's current placement as verified. |

`<guid>` is the object's unique identifier; `<degrees>` is the amount of rotation.

For the full command reference and technical design, see `payload\mod-gobject-placement\README.md`.

## 2. Before you begin

- Have the installation ZIP available on the **computer running the server**.
- Be able to open **PowerShell as administrator**.
- Allow approximately **10–40 minutes** for the server rebuild.
- Plan to **stop the server before the actual installation**. You may perform the earlier checks while it is running.
- Review your existing backups. AFK Realm normally retains only the **three newest snapshots**; making a new one may remove the oldest.

> **Backup warning:** The retention count is controlled by `keep=` in `Dependencies\backup-settings.txt`. The installer previews which older snapshot would be removed. Copy that snapshot elsewhere first if you need to preserve it.

## 3. Install the module

### Step 1 — Extract the package

Copy the ZIP to the server computer and extract it to a convenient folder, such as Downloads.

### Step 2 — Open administrator PowerShell

Open the Start menu, search for **PowerShell**, right-click it, and select **Run as administrator**.

### Step 3 — Start the installer

Run these commands, replacing the example folder name with the name of your extracted folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd "$env:USERPROFILE\Downloads\GObjectPlacement-1.0.0-xxxxxxxx"
.\Install-GObjectPlacement.ps1
```

**Optional: check first without installing.** Run this instead of the final command:

```powershell
.\Install-GObjectPlacement.ps1 -CheckOnly
```

This performs checks and displays a preview without making changes.

### Step 4 — Select your AFK Realm installation

Choose your **server** from the list. The installer looks in AFK Realm's saved settings (`%APPDATA%\AFK-Realm\servers.txt`) and searches your drives.

You can also enter either of these paths:

- **Server folder:** Contains `Dependencies`, `Server`, and `DB` (default example: `C:\CoA-Server`).
- **AFK Realm program folder:** Contains `engine\engine.ps1` (example: `C:\!AFK\AFK-Realm-main`). If you select this folder, the installer looks up its server folder in AFK Realm's settings and asks you to choose if needed.

To specify the program folder when launching the installer:

```powershell
.\Install-GObjectPlacement.ps1 -InstallRoot "C:\!AFK\AFK-Realm-main"
```

**Advanced — selecting the engine:** The installer normally uses the engine stored in the server's `<server>\Builder` folder (the version last used for that server). Otherwise, it uses the program folder's `engine\engine.ps1`. The checks show which engine was selected. To override it:

```powershell
.\Install-GObjectPlacement.ps1 -EnginePath "C:\!AFK\AFK-Realm-main\engine\engine.ps1"
```

### Step 5 — Review the checks

Read the results and installation preview. If any check displays **`[FAIL]`**, the installer stops without proceeding.

### Step 6 — Stage the module

When prompted, enter **`y`**. This creates a local module repository at:

```text
<server>\Dependencies\LocalModules\mod-gobject-placement.git
```

Staging does **not** modify the running server. Nothing is published online.

### Step 7 — Stop the server

Use AFK Realm to stop the server, or close the `worldserver` and `authserver` windows.

If the server is still running, the installer stops at this point **without shutting it down**. Run the installer again after stopping the server; it will reuse the staged module.

### Step 8 — Confirm installation

When ready, type:

```text
INSTALL
```

AFK Realm then:

1. Creates a backup of server programs, configuration files, and databases in `<server>\Backups\`.
2. Rebuilds the server at its **current core revision**, without updating the core from GitHub.
3. Installs the rebuilt `Server\worldserver.exe` **only if compilation succeeds**.
4. Applies and tracks the module's database changes so its removal can reverse them.

**Expected build time:** 10–40 minutes.

AFK Realm requests your **database password** directly. This package does not read, store, or log it.

If the build fails, AFK Realm removes the module again and leaves the existing server in place.

### Step 9 — Start the server

Wait until the installer reports **`Installed.`** Then start the server through AFK Realm or `START-SERVER.cmd`.

### Step 10 — Verify the commands in-game

Log in with an appropriately privileged GM account and follow the tests below.

## 4. Test the commands in-game

> **Important:** These are the intended verification steps, not a record of completed in-game testing.

1. **Check help:** Run `.help gobject pitch`, `.help gobject roll`, and `.help gobject save` to view their syntax.
2. **Find an object:** Stand near one and run `.gobject near`. Note its GUID (called `G` in the examples below).
3. **Test pitch:** Run `.gobject pitch G 15`, then `.gobject pitch G -15`. Each command should tilt the object immediately.
4. **Test roll:** Run `.gobject roll G 10`, then `.gobject roll G -10`.
5. **Test combined rotation:** Run `.gobject turn G`, then `.gobject pitch G 10` and `.gobject roll G 20`. The response should report pitch **10** and roll **20**. **Note:** `.gobject turn G` by itself resets pitch and roll (existing core behavior).
6. **Test saving:** Run `.gobject save G` twice. The `acore_characters.gobject_placement_history` table should contain two records for that GUID.
7. **Test persistence:** Restart the server. The object should remain tilted.
8. **Test invalid values:** The following commands should each be rejected with an explanatory message:

   ```text
   .gobject pitch 999999999 5
   .gobject pitch G 0
   .gobject pitch G 400
   ```

Replace `G` with the actual object GUID in these examples.

## 5. Export saved placements (optional)

The included exporter produces files for review. **It does not apply changes to the world database**, and exports are never automatic.

From the extracted package folder, run the following in PowerShell, replacing `<install>` with your server installation path:

```powershell
python tools\export_placements.py --mysql <install>\DB\mysql\bin\mysql.exe --defaults-file <install>\DB\launcher.cnf `
    --database acore_characters --sql placements.sql --toml placements.toml
```

The exporter generates:

- **SQL review output:** Statements guarded by GUID, entry, and map.
- **TOML review output:** Worldforged Placement Fixes manifest entries, initially **disabled**.

It writes review files only; it never executes the generated SQL.

## 6. Uninstall the module

1. **Stop the server.**
2. Open **PowerShell as administrator**.
3. In the extracted package folder, run:

   ```powershell
   .\Uninstall-GObjectPlacement.ps1
   ```

The uninstall process removes the module through AFK Realm. **Saved placement records are retained by default.** For rollback details, see `ROLLBACK.md`.

## 7. Why the installer uses AFK Realm

AFK Realm's module manager (`AFK-Realm-Engine.ps1 -Mode Modules`) provides backup, build, and database-change tracking. Its graphical interface accepts only `https://` module addresses, so this installer stages a **local Git repository** and passes it to the engine using `-AddModules file:///.../mod-gobject-placement.git`.

You could copy the module files manually, and the core's updater has been verified to apply their SQL. **However, a manual copy bypasses AFK Realm's pre-install backup and its database-change tracking and reversal.** The included installer is therefore the recommended approach.

## Author and license

**Author:** Wrekczar  
**Discord:** @iamjustleon

**License:** MIT License © 2026 Wrekczar. See [LICENSE](LICENSE) for the full license text.

> The MIT license applies to original material for which Wrekczar holds the rights. Third-party components and applicable upstream licenses retain their own terms.

## 8. Package contents

| File or folder | Purpose |
| --- | --- |
| `Install-GObjectPlacement.ps1` | Installation checks, preview, staging, and installation |
| `Uninstall-GObjectPlacement.ps1` | Module removal; retains placement history by default |
| `lib\` | Shared helpers for both scripts |
| `payload\mod-gobject-placement.bundle` | Git repository bundle used for installation |
| `payload\mod-gobject-placement\` | Readable module source, SQL, and tests |
| `payload\COMMIT.txt` | Exact module commit identifier |
| `tools\export_placements.py` | Read-only placement exporter |
| `COMPATIBILITY.md` | Compatibility and test information |
| `TROUBLESHOOTING.md` | Troubleshooting instructions |
| `ROLLBACK.md` | Uninstall and rollback details |
| `SHA256SUMS.txt` | File checksums |

---

**Quick reminder:** Check → Stage → Stop server → Type `INSTALL` → Wait for `Installed.` → Start server → Test in-game.


## Author and license

**Wrekczar** · Discord: **@iamjustleon**

MIT License © 2026 Wrekczar. See [LICENSE](LICENSE). Third-party components retain their respective licenses.
