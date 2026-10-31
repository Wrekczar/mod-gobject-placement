#requires -Version 5.1
<#
.SYNOPSIS
    Removes mod-gobject-placement from an AFK Realm server through AFK Realm's module system,
    keeping the saved placement records by default.

.DESCRIPTION
    Installed through the installer (AFK Realm "managed" module):
        AFK Realm -Mode Modules -RemoveModules mod-gobject-placement backs up the server, rebuilds it
        without the module and undoes the module's recorded database changes. That undo DROPS the
        three placement tables, so this script first dumps them to Backups\gobject-placement\ and,
        unless you choose -RemovePlacementData, loads them back afterwards.
    Copied in by hand (folder only):
        AFK Realm sets the folder aside, rebuilds, deletes the set-aside folder after a successful build,
        and leaves the database alone. This script then removes only the three help rows (with confirmation) and keeps the tables.

    Never changes gameobject rows: rotations made with .gobject pitch/roll stay as they are
    (README "Rollback" shows how to put single spawns back). Never stops the server; starts the
    database only after you confirm. Uses DB\launcher.cnf for its own SQL; no password is stored.

.PARAMETER RemovePlacementData
    Also delete the placement tables (separate confirmation; the dump file is kept).
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [string]$EnginePath = '',
    [switch]$RemovePlacementData,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\GObjectPlacement.Common.ps1')

function Exit-With([int]$Code, [string]$Message) {
    Write-Host ''
    if ($Code -eq 0) { Write-Host $Message -ForegroundColor Green } else { Write-Host $Message -ForegroundColor Red }
    exit $Code
}

function Start-DatabaseConfirmed([hashtable]$Paths, [string]$Why) {
    $port = Get-DatabasePort $Paths
    if (Test-TcpPort $port) { return $true }
    if (-not (Confirm-Word "The database is not running. Start ONLY the database (not the game server) to $Why ? It is left running afterwards; START-SERVER.cmd and the AFK Realm app use it as it is." 'START')) { return $false }
    $mysqld = Join-Path $Paths.MySqlBin 'mysqld.exe'
    Start-Process -FilePath $mysqld -ArgumentList "--defaults-file=`"$($Paths.MyIni)`"" -WindowStyle Minimized | Out-Null
    for ($i = 0; $i -lt 90; $i++) { if (Test-TcpPort $port) { Write-Ok "Database started on port $port."; return $true }; Start-Sleep -Seconds 1 }
    throw "The database did not start within 90 seconds (see logs\mysql-error.log)."
}

function Get-TableCounts([hashtable]$Paths, [string[]]$Tables) {
    $counts = [ordered]@{}
    foreach ($t in $Tables) { $counts[$t] = [int](Get-LauncherSqlValue $Paths "SELECT COUNT(*) FROM acore_characters.``$t``;") }
    return $counts
}

function Save-PlacementDump([hashtable]$Paths, [string[]]$Tables) {
    $folder = Join-Path $Paths.Backups 'gobject-placement'
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
    $file = Join-Path $folder ("placements-{0:yyyy-MM-dd_HH-mm-ss}.sql" -f (Get-Date))
    $dump = Join-Path $Paths.MySqlBin 'mysqldump.exe'
    $arguments = @("--defaults-extra-file=$($Paths.Cnf)", '--single-transaction', '--skip-lock-tables', '--hex-blob', '--set-gtid-purged=OFF',
                   '--default-character-set=utf8mb4', "--result-file=$file", 'acore_characters') + $Tables
    $r = Invoke-Native $dump $arguments
    if ($r.Code -ne 0) { throw ("mysqldump failed: " + ($r.Lines -join ' ')) }
    $text = [IO.File]::ReadAllText($file)
    foreach ($t in $Tables) { if (-not $text.Contains("CREATE TABLE ``$t``")) { throw "The dump $file does not contain $t." } }
    return $file
}

function Restore-PlacementDump([hashtable]$Paths, [string]$File) {
    $mysql = Join-Path $Paths.MySqlBin 'mysql.exe'
    $r = Invoke-Native $mysql @("--defaults-extra-file=$($Paths.Cnf)", '--default-character-set=utf8mb4', 'acore_characters') ([IO.File]::ReadAllText($File))
    if ($r.Code -ne 0) { throw ("Loading $File failed: " + ($r.Lines -join ' ')) }
}

Write-Host "mod-gobject-placement uninstaller $script:PackageVersion" -ForegroundColor White
$selection = Select-AfkRoot $InstallRoot $EnginePath
if (-not $selection) { Exit-With 1 'Cancelled. Nothing was changed.' }
$root = $selection.Root
$paths = Get-AfkPaths $root $selection.Engine

Write-Step "Checking $root (read only)"
foreach ($n in $selection.Notes) { Write-Info $n }
if (-not (Test-ServerRoot $root)) { Exit-With 1 "$root is not an AFK Realm server folder (Dependencies\Source + Server). Nothing was changed." }
if (-not (Test-Path -LiteralPath $paths.Engine)) { Exit-With 1 "No AFK Realm engine found for this server (pass -EnginePath <AFK Realm folder>\engine\engine.ps1). Nothing was changed." }
Write-Ok "AFK Realm engine: $($paths.Engine)$(if ($selection.EngineSource) { " ($($selection.EngineSource))" })"
$managedLine = Get-ManagedModuleLine $paths
$folderPresent = Test-Path -LiteralPath $paths.ModuleFolder
$kind = 'none'
if ($managedLine) { $kind = 'managed' } elseif ($folderPresent) { $kind = 'manual' }
switch ($kind) {
    'managed' { Write-Ok "Installed through AFK Realm: $managedLine" }
    'manual'  { Write-Ok "Installed by hand: $($paths.ModuleFolder) (not in AFK Realm's module list)" }
    default   { Write-Warn 'The module is not installed (no folder, not in AFK Realm''s module list).' }
}
$running = @(Get-ServerProcesses $paths)
if ($running.Count -gt 0) { Write-Warn ("The server is running ({0}); it must be stopped for the rebuild. Nothing is stopped by this script." -f (($running | ForEach-Object { $_.ProcessName }) -join ', ')) }
$snap = Get-SnapshotInfo $paths
$dbUp = Test-TcpPort (Get-DatabasePort $paths)

Write-Step 'Preview'
if ($kind -eq 'none') {
    Write-Info 'Nothing to remove. Placement tables, if any, are left as they are.'
    Exit-With 0 'Nothing was changed.'
}
Write-Info '1. Dump the placement tables (acore_characters.gobject_placement_*) to Backups\gobject-placement\ (needs the database running).'
Write-Info "2. AFK Realm: backup snapshot, rebuild WITHOUT the module, replace the server programs after a successful build."
Write-Info "   AFK Realm sets $($paths.ModuleFolder) aside during the build and deletes it after success (the package keeps the source)."
if ($snap.WouldBeRemoved.Count -gt 0) { Write-Warn ("   AFK Realm keeps {0} snapshots; the new one removes the oldest: {1}" -f $snap.Keep, ($snap.WouldBeRemoved -join ', ')) }
if ($kind -eq 'managed') {
    Write-Info '   AFK Realm undoes the module SQL: removes the 3 help rows and DROPS the placement tables if this install created them.'
    if ($RemovePlacementData) { Write-Warn '3. -RemovePlacementData: the placement tables are removed (the dump file from step 1 is kept).' }
    else { Write-Info '3. Load the dump back if AFK Realm dropped them, so the placement records are kept (default; row counts checked).' }
} else {
    Write-Info '   AFK Realm leaves the database alone for a module it did not install.'
    Write-Info "3. Remove the 3 help rows (acore_world.command) and the module's 2 entries in the 'updates' tables."
    if ($RemovePlacementData) { Write-Warn '4. -RemovePlacementData: DROP the 3 placement tables (the dump file from step 1 is kept).' }
    else { Write-Info '   The placement tables are kept (default).' }
}
Write-Info 'Never changed: gameobject rows (tilted objects stay tilted), other modules, the core source revision.'
Write-Info "Staged copy $($paths.StagedRepo) is left in place (a later reinstall reuses it)."
if (-not $dbUp) { Write-Info 'The database is not running now; you will be asked before it is started.' }

if ($CheckOnly) { Exit-With 0 'Check finished. Nothing was changed (-CheckOnly).' }
if ($running.Count -gt 0) { Exit-With 1 'Stop the server first (AFK Realm app or close the worldserver/authserver windows), then run this again. Nothing was changed.' }
if (-not (Test-IsAdministrator)) { Exit-With 1 'Run this from an administrator PowerShell (AFK Realm needs it for the rebuild). Nothing was changed.' }
if ($RemovePlacementData -and -not (Confirm-Word 'You asked to DELETE all saved placement records (verified, history and baseline). A dump is still written first.' 'DELETE')) {
    Exit-With 1 'Cancelled. Nothing was changed.'
}

# ---- 1. dump
if (-not (Start-DatabaseConfirmed $paths 'dump the placement records first')) { Exit-With 1 'Cancelled. Nothing was changed.' }
$present = @(Invoke-LauncherSql $paths ("SELECT table_name FROM information_schema.tables WHERE table_schema = 'acore_characters' AND table_name IN ('" + ($script:PlacementTables -join "','") + "') ORDER BY table_name;"))
$dumpFile = $null
$before = $null
if ($present.Count -gt 0) {
    $before = Get-TableCounts $paths $present
    $dumpFile = Save-PlacementDump $paths $present
    Write-Ok ("Dumped {0} to {1}" -f (($before.Keys | ForEach-Object { "$_ ($($before[$_]) rows)" }) -join ', '), $dumpFile)
} else { Write-Info 'No placement tables exist; nothing to dump.' }

# ---- 2. AFK Realm
if (-not (Confirm-Word "Run AFK Realm now to back up, rebuild without $script:ModuleName and replace the server programs? It asks for the database password and stops the database when it finishes." 'UNINSTALL')) {
    Exit-With 1 ("Cancelled before AFK Realm ran. The module is still installed. {0}" -f $(if ($dumpFile) { "(A dump was written: $dumpFile)" } else { '' }))
}
Write-Step 'AFK Realm module removal (output below is from AFK Realm)'
$code = Invoke-Engine $paths @('-RemoveModules', $script:ModuleName)
if ($code -ne 0 -or (Get-ManagedModuleLine $paths) -or (Test-Path -LiteralPath $paths.ModuleFolder)) {
    Write-Bad "AFK Realm ended with code $code; the module may still be installed."
    Write-Info 'If the rebuild failed, AFK Realm put the module back and kept the old programs (logs\install.log).'
    if ($dumpFile) { Write-Info "Your placement records are also in $dumpFile." }
    Exit-With 1 'Uninstall did not complete. See TROUBLESHOOTING.md.'
}
Write-Ok 'AFK Realm removed the module and rebuilt the server.'

# ---- 3. database follow-up
# AFK Realm drops the placement tables only when its record says this install created them (not when they
# already existed, e.g. after a reinstall), so the follow-up looks at what is actually there now.
$needDb = ($present.Count -gt 0) -or ($kind -eq 'manual')
if ($needDb -and -not (Start-DatabaseConfirmed $paths 'finish the database part')) {
    Write-Warn 'Database part skipped. Run this script again later, or see ROLLBACK.md to load the dump by hand.'
    Exit-With 1 ("Module removed; database follow-up not done. Dump: {0}" -f $dumpFile)
}
if ($kind -eq 'manual') {
    if (Confirm-Word 'Remove the 3 help rows for .gobject pitch/roll/save and the module''s 2 entries in the updates tables?' 'YES') {
        $null = Invoke-LauncherSql $paths "DELETE FROM acore_world.command WHERE name IN ('gobject pitch','gobject roll','gobject save'); DELETE FROM acore_world.updates WHERE name = '$($script:ModuleSqlFiles[1])' AND state = 'MODULE'; DELETE FROM acore_characters.updates WHERE name = '$($script:ModuleSqlFiles[0])' AND state = 'MODULE';"
        Write-Ok 'Help rows and update entries removed.'
    } else { Write-Info 'Help rows left in place (the server logs a harmless "non-existant command" line for each).' }
}
if ($present.Count -gt 0) {
    $remaining = @(Invoke-LauncherSql $paths ("SELECT table_name FROM information_schema.tables WHERE table_schema = 'acore_characters' AND table_name IN ('" + ($script:PlacementTables -join "','") + "') ORDER BY table_name;"))
    if ($RemovePlacementData) {
        if ($remaining.Count -gt 0) { $null = Invoke-LauncherSql $paths ('DROP TABLE IF EXISTS ' + (($remaining | ForEach-Object { "acore_characters.``$_``" }) -join ', ') + ';') }
        Write-Ok "Placement tables removed. Dump kept: $dumpFile"
    } else {
        if ($remaining.Count -lt $present.Count) {
            Write-Info ('AFK Realm removed {0} placement table(s); loading the dump back.' -f ($present.Count - $remaining.Count))
            Restore-PlacementDump $paths $dumpFile
        } else { Write-Info 'AFK Realm left the placement tables in place (they existed before this install).' }
        $after = Get-TableCounts $paths @($before.Keys)
        foreach ($t in $before.Keys) { if ($after[$t] -ne $before[$t]) { throw "$t has $($after[$t]) rows, expected $($before[$t]). The dump is $dumpFile." } }
        Write-Ok ('Placement records kept: ' + (($before.Keys | ForEach-Object { "$_ $($after[$_]) rows" }) -join ', '))
    }
}
if ($needDb) { Write-Info 'The database is left running; start the game server when you choose.' }
Exit-With 0 'Uninstalled.'
