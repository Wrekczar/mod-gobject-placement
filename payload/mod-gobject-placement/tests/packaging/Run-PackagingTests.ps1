#requires -Version 5.1
<#
Tests the packaged installer and uninstaller against ISOLATED AFK Realm copies and a DISPOSABLE MySQL, in both
AFK Realm layouts:

  classic   -ClassicRoot: server folder with Builder\AFK-Realm-Engine.ps1 (the engine the app extracts there;
            here AFK Realm 1.0.5), installer pointed at the server folder
  program   -ProgramFolder: AFK Realm program folder with engine\engine.ps1 + module-journal.sql (here 1.1.6,
            e.g. C:\!AFK\AFK-Realm-main) and a separate server folder -ServerRootB WITHOUT a Builder copy;
            installer pointed at the PROGRAM folder, server taken from AFK Realm's settings (-TestAppData)

For each engine a FakeEngine.ps1 is generated next to it: that engine's own code before its main block plus
fake-engine-main.ps1 (snapshot and compile skipped). The installer runs the FakeEngine.ps1 next to the engine it
resolved, so the tests also prove which engine would have run.

Both server folders need DB\launcher.cnf for the disposable MySQL (root, no password on -Port), DB\mysql
(MySQL binaries), Dependencies\Source (core checkout), Dependencies\Build\CMakeCache.txt, Server\worldserver.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Zip,
    [string]$ClassicRoot = 'I:\gobject-placement-dev\afk-test',
    [string]$ServerRootB = 'I:\gobject-placement-dev\afk-test-b',
    [string]$ProgramFolder = 'I:\gobject-placement-dev\afk-launcher-test\AFK-Realm-main',
    [string]$TestAppData = 'I:\gobject-placement-dev\test-appdata',
    [string]$CoreSource = 'I:\gobject-placement-dev\src',
    [int]$Port = 3398
)

# Native tools write progress to stderr; every exit code is checked explicitly instead.
$ErrorActionPreference = 'Continue'
foreach ($r in $ClassicRoot, $ServerRootB) {
    $text = [IO.File]::ReadAllText((Join-Path $r 'DB\launcher.cnf'))
    if ($text -notmatch "port=$Port" -or $text -match 'password') { throw "$r\DB\launcher.cnf is not the disposable test login." }
}
$mysql = Join-Path $ClassicRoot 'DB\mysql\bin\mysql.exe'
$cnf = Join-Path $ClassicRoot 'DB\launcher.cnf'
$script:results = New-Object Collections.Generic.List[object]

function Check([bool]$Ok, [string]$Name, [string]$Detail = '') {
    $script:results.Add([pscustomobject]@{ Ok = $Ok; Name = $Name; Detail = $Detail })
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} {2}" -f $mark, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

function Sql([string]$Statement) {
    $out = $Statement | & $mysql "--defaults-extra-file=$cnf" --batch --skip-column-names 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("SQL failed: " + (($out | ForEach-Object { "$_" }) -join ' ')) }
    return ,@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne '' })
}

function Source-File([string]$File, [string]$Database) {
    $out = Get-Content -LiteralPath $File -Raw | & $mysql "--defaults-extra-file=$cnf" $Database 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("Loading $File failed: " + (($out | ForEach-Object { "$_" }) -join ' ')) }
}

function Reset-Databases {
    Sql 'DROP DATABASE IF EXISTS acore_world; DROP DATABASE IF EXISTS acore_characters; DROP DATABASE IF EXISTS afk_modules; CREATE DATABASE acore_world CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE DATABASE acore_characters CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' | Out-Null
    foreach ($f in 'command.sql', 'updates.sql', 'updates_include.sql', 'gameobject.sql') { Source-File (Join-Path $CoreSource "data\sql\base\db_world\$f") 'acore_world' }
    foreach ($f in 'updates.sql', 'updates_include.sql') { Source-File (Join-Path $CoreSource "data\sql\base\db_characters\$f") 'acore_characters' }
}

function Reset-Install([string]$Root) {
    foreach ($p in 'Dependencies\Source\modules\mod-gobject-placement', 'Dependencies\LocalModules', 'Dependencies\ModulesRemoved', 'Dependencies\modules.txt', 'Backups\gobject-placement') {
        $full = Join-Path $Root $p
        if (Test-Path $full) { Remove-Item $full -Recurse -Force }
    }
}

function Set-AfkSettings([string[]]$Servers) {
    $dir = Join-Path $TestAppData 'AFK-Realm'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $last = if ($Servers.Count -gt 0) { $Servers[0] } else { '' }
    [IO.File]::WriteAllText((Join-Path $dir 'last-install.txt'), $last)
    [IO.File]::WriteAllLines((Join-Path $dir 'servers.txt'), [string[]]@($Servers | ForEach-Object { "$_`tTest realm" }))
}

function New-FakeEngine([string]$Engine) {
    $lines = [IO.File]::ReadAllLines($Engine)
    $cut = [Array]::IndexOf($lines, '$exitCode = 0')
    if ($cut -lt 0) { throw "Engine main block not found in $Engine." }
    $fake = Join-Path (Split-Path $Engine -Parent) 'FakeEngine.ps1'
    [IO.File]::WriteAllLines($fake, [string[]]($lines[0..($cut - 1)] + [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'fake-engine-main.ps1'))), (New-Object Text.UTF8Encoding($true)))
    return $fake
}

function Run([string]$Script, [string[]]$Arguments, [string]$Answers, [hashtable]$Env = @{}) {
    $env:GP_TEST_MODE = '1'
    $env:GP_TEST_ANSWERS = $Answers
    $env:GP_TEST_APPDATA = $TestAppData
    foreach ($k in 'GP_TEST_ASSUME_ADMIN', 'GP_TEST_ENGINE', 'GP_TEST_FAIL_AFTER_STAGE', 'GP_TEST_BUILD_FAIL') { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    foreach ($k in $Env.Keys) { Set-Item "Env:$k" $Env[$k] }
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:pkg $Script)) + $Arguments
    $out = & powershell.exe @all 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $log = Join-Path $script:logDir ("{0:D2}-{1}.log" -f ($script:runNo++), [IO.Path]::GetFileNameWithoutExtension($Script))
    [IO.File]::WriteAllLines($log, [string[]]$out)
    return [pscustomobject]@{ Code = $code; Text = ($out -join "`n"); Log = $log }
}

function Count([string]$Statement) { return [int](Sql $Statement)[0] }
function TableCount { return Count "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'acore_characters' AND table_name LIKE 'gobject_placement%';" }
function HelpRows { return Count "SELECT COUNT(*) FROM acore_world.command WHERE name IN ('gobject pitch','gobject roll','gobject save');" }
function Clean([object]$R) { return ($R.Text -notmatch 'Exception|PropertyNotFound|System\.String\[\]|At .*\.ps1:\d+') }

# ================================================================ package contents
$work = Join-Path ([IO.Path]::GetTempPath()) ('gp-pkgtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$script:logDir = Join-Path $work 'logs'; New-Item -ItemType Directory -Path $script:logDir | Out-Null
$script:runNo = 1
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($Zip, $work)
$script:pkg = @(Get-ChildItem $work -Directory | Where-Object { $_.Name -like 'GObjectPlacement-*' })[0].FullName
$expected = @('Install-GObjectPlacement.ps1', 'Uninstall-GObjectPlacement.ps1', 'lib\GObjectPlacement.Common.ps1', 'README.md', 'TROUBLESHOOTING.md',
              'COMPATIBILITY.md', 'ROLLBACK.md', 'SHA256SUMS.txt', 'tools\export_placements.py', 'payload\COMMIT.txt', 'payload\mod-gobject-placement.bundle',
              'payload\mod-gobject-placement\src\GObjectPlacementCommands.cpp', 'payload\mod-gobject-placement\src\GObjectPlacementMath.h',
              'payload\mod-gobject-placement\src\GP_loader.cpp', 'payload\mod-gobject-placement\data\sql\db-characters\2026_10_28_00_gobject_placement.sql',
              'payload\mod-gobject-placement\data\sql\db-world\2026_10_28_00_gobject_placement_commands.sql', 'payload\mod-gobject-placement\data\sql\manual\uninstall.sql')
$missing = @($expected | Where-Object { -not (Test-Path (Join-Path $script:pkg $_)) })
Check ($missing.Count -eq 0) 'ZIP contains every expected file' ($missing -join ', ')
$bad = @(Get-Content (Join-Path $script:pkg 'SHA256SUMS.txt') | Where-Object { $_ } | Where-Object {
    $h, $f = $_ -split '  ', 2
    (Get-FileHash (Join-Path $script:pkg $f) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $h })
Check ($bad.Count -eq 0) 'SHA256SUMS match' ($bad -join '; ')
$commit = (Get-Content (Join-Path $script:pkg 'payload\COMMIT.txt') -Raw).Trim()
$heads = & git bundle list-heads (Join-Path $script:pkg 'payload\mod-gobject-placement.bundle') 2>&1 | Out-String
Check ($heads -match "$commit refs/heads/main" -and $heads -match "$commit HEAD") 'Bundle holds COMMIT.txt as main and HEAD' $commit.Substring(0, 8)
$secrets = @(Get-ChildItem $script:pkg -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.md', '.txt', '.sql', '.py', '.cnf', '.ini' } |
             Select-String -Pattern "(?i)password\s*=\s*(?!'')\S|gpdev-test-only|IDENTIFIED BY" | Where-Object { $_.Line -notmatch 'GP_TEST|password=`"\$Password' })
Check ($secrets.Count -eq 0) 'No passwords or test credentials in the package' (($secrets | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')
$nonAscii = @(Get-ChildItem $script:pkg -Recurse -File -Filter '*.ps1' | Where-Object { [IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1 })
Check ($nonAscii.Count -eq 0) 'Scripts are ASCII (Windows PowerShell 5.1 reads them correctly)' (($nonAscii | ForEach-Object Name) -join ', ')
$wow = @(Get-ChildItem $script:pkg -Recurse -File -Filter '*.ps1' | Select-String -Pattern '(?i)[a-z]:\\wow')
Check ($wow.Count -eq 0) 'Scripts contain no path into a WoW client folder'
$parseErrors = @()
foreach ($f in Get-ChildItem $script:pkg -Recurse -File -Filter '*.ps1') {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) { $parseErrors += "$($f.Name): $($errors[0].Message)" }
}
Check ($parseErrors.Count -eq 0) "Scripts parse in PowerShell $($PSVersionTable.PSVersion)" ($parseErrors -join '; ')
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwsh) {
    $out = & $pwsh.Source -NoProfile -Command "`$e=0; Get-ChildItem '$script:pkg' -Recurse -Filter *.ps1 | ForEach-Object { `$t=`$null; `$r=`$null; [void][Management.Automation.Language.Parser]::ParseFile(`$_.FullName,[ref]`$t,[ref]`$r); if (`$r) { `$e++ } }; `$e" 2>&1
    Check ("$out".Trim() -eq '0') 'Scripts parse in PowerShell 7' "$out"
} else { Write-Host '[SKIP] PowerShell 7 not installed' }

# ================================================================ detection on this PC (read only, real settings)
$detect = & powershell.exe -NoProfile -Command ". '$script:pkg\lib\GObjectPlacement.Common.ps1'; `$f = Find-AfkInstallations; (@(`$f.Servers | ForEach-Object { `$_.Root + '|' + `$_.Source }) -join ';'); (@(`$f.Programs) -join ';'); [string](Test-ProtectedName 'WoW'); [string](Test-ProtectedName 'WoW Storage'); [string](Test-ProtectedName 'CoA-Server'); [string](Test-ProtectedName 'AFK-Realm-main')" 2>&1 | ForEach-Object { "$_" }
Check ($detect[0] -match '(?i)^H:\\CoA-Server\|AFK Realm settings') 'Detection: real AFK Realm settings name H:\CoA-Server first' $detect[0]
Check ("$($detect[0]);$($detect[1])" -notmatch '(?i)\\wow(\\|;|\||$)') 'Detection lists no WoW folder'
Check ($detect[1] -match '(?i)afk-realm-src') 'Detection: finds an AFK Realm program folder (engine\engine.ps1) on disk' $detect[1]
Check ($detect[2] -eq 'True' -and $detect[3] -eq 'True' -and $detect[4] -eq 'False' -and $detect[5] -eq 'False') 'Protected-name rule (WoW, WoW Storage blocked; CoA-Server, AFK-Realm-main allowed)'

# ================================================================ layout and selection cases
Reset-Databases
foreach ($r in $ClassicRoot, $ServerRootB) { Reset-Install $r }
$fakeClassic = New-FakeEngine (Join-Path $ClassicRoot 'Builder\AFK-Realm-Engine.ps1')
$fakeProgram = New-FakeEngine (Join-Path $ProgramFolder 'engine\engine.ps1')

Set-AfkSettings @($ClassicRoot, $ServerRootB)
$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly') '1'
Check ($r.Code -eq 0 -and $r.Text -match ([regex]::Escape("1) $ClassicRoot   (AFK Realm settings)")) -and (Clean $r)) 'Menu shows server paths (no System.String[]); "1" selects it' $r.Log
Check ($r.Text -match ([regex]::Escape("Checking $ClassicRoot"))) 'Menu choice is used as the server folder' $r.Log
$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly') "<empty>"
Check ($r.Code -eq 1 -and $r.Text -match 'Cancelled' -and (Clean $r)) 'Empty answer in the menu cancels cleanly' $r.Log
$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly') "$ServerRootB"
Check ($r.Code -eq 0 -and $r.Text -match ([regex]::Escape("Checking $ServerRootB"))) 'Typed server path in the menu is used' $r.Log

$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly', '-InstallRoot', $ProgramFolder) '2'
Check ($r.Code -eq 0 -and $r.Text -match 'program folder' -and $r.Text -match 'Servers known to AFK Realm' -and $r.Text -match ([regex]::Escape("Checking $ServerRootB")) -and (Clean $r)) 'Program folder + two known servers: asks which, uses the choice' $r.Log
Check ($r.Text -match ([regex]::Escape("AFK Realm engine: $ProgramFolder\engine\engine.ps1"))) 'Program folder given: its engine\engine.ps1 is used (server has no Builder copy)' $r.Log

Set-AfkSettings @()
$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly', '-InstallRoot', $ProgramFolder) '<empty>'
Check ($r.Code -eq 1 -and $r.Text -match 'settings name no server folder' -and (Clean $r)) 'Program folder, no known server: asks for the server path; empty cancels cleanly' $r.Log
$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly', '-InstallRoot', $ProgramFolder) $ServerRootB
Check ($r.Code -eq 0 -and $r.Text -match ([regex]::Escape("Checking $ServerRootB")) -and $r.Text -match ([regex]::Escape("$ProgramFolder\engine\engine.ps1"))) 'Program folder, server path typed: works with the program folder''s engine' $r.Log

$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly', '-InstallRoot', $work) ''
Check ($r.Code -eq 1 -and $r.Text -match 'not an AFK Realm server folder' -and (Clean $r)) 'A folder that is neither layout: clean refusal, no exception' $r.Log
$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly', '-InstallRoot', $ServerRootB, '-EnginePath', (Join-Path $work 'missing\engine.ps1')) ''
Check ($r.Code -eq 1 -and $r.Text -match 'No AFK Realm engine found' -and $r.Text -match 'Cannot continue' -and (Clean $r)) 'Missing engine: clean stop (no PropertyNotFoundStrict)' $r.Log
$r = Run 'Uninstall-GObjectPlacement.ps1' @('-CheckOnly', '-InstallRoot', $ServerRootB, '-EnginePath', (Join-Path $work 'missing\engine.ps1')) ''
Check ($r.Code -eq 1 -and $r.Text -match 'No AFK Realm engine found' -and (Clean $r)) 'Uninstaller, missing engine: clean stop' $r.Log
$r = Run 'Install-GObjectPlacement.ps1' @('-CheckOnly', '-InstallRoot', $ClassicRoot) ''
Check ($r.Code -eq 0 -and $r.Text -match ([regex]::Escape("AFK Realm engine: $ClassicRoot\Builder\AFK-Realm-Engine.ps1")) -and $r.Text -match 'extracted by the AFK Realm app') 'Classic server folder: uses its Builder copy' $r.Log

# ================================================================ full suite per layout
function Invoke-Suite([string]$Layout) {
    if ($Layout -eq 'classic') { $TestRoot = $ClassicRoot; $root = @('-InstallRoot', $ClassicRoot); Set-AfkSettings @($ClassicRoot); $engine = Join-Path $ClassicRoot 'Builder\AFK-Realm-Engine.ps1' }
    else { $TestRoot = $ServerRootB; $root = @('-InstallRoot', $ProgramFolder); Set-AfkSettings @($ServerRootB); $engine = Join-Path $ProgramFolder 'engine\engine.ps1' }
    $L = "[$Layout]"
    Reset-Databases
    Reset-Install $TestRoot
    $engineEnv = @{ GP_TEST_ASSUME_ADMIN = '1'; GP_TEST_ENGINE = 'sibling' }
    $modFolder = Join-Path $TestRoot 'Dependencies\Source\modules\mod-gobject-placement'
    $staged = Join-Path $TestRoot 'Dependencies\LocalModules\mod-gobject-placement.git'
    $list = Join-Path $TestRoot 'Dependencies\modules.txt'

    $r = Run 'Install-GObjectPlacement.ps1' ($root + '-CheckOnly') ''
    Check ($r.Code -eq 0 -and $r.Text -match 'Check finished' -and -not (Test-Path $staged) -and $r.Text -match 'Tested revision') "$L -CheckOnly passes and changes nothing" $r.Log
    Check ($r.Text -match ([regex]::Escape("AFK Realm engine: $engine"))) "$L resolved engine is $engine" $r.Log
    Check ($r.Text -match 'removes the oldest: 2026-10-01_10-00-00') "$L warns which AFK Realm snapshot would be pruned" $r.Log

    $r = Run 'Install-GObjectPlacement.ps1' $root 'n'
    Check ($r.Code -eq 1 -and -not (Test-Path (Join-Path $TestRoot 'Dependencies\LocalModules'))) "$L cancel at staging: nothing created" $r.Log
    $r = Run 'Install-GObjectPlacement.ps1' $root 'y' @{ GP_TEST_FAIL_AFTER_STAGE = '1' }
    Check ($r.Code -eq 1 -and -not (Test-Path (Join-Path $TestRoot 'Dependencies\LocalModules')) -and $r.Text -match 'rolled back') "$L failure after staging rolls back only what the run created" $r.Log

    $fakeServer = Join-Path $TestRoot 'Server\worldserver.exe'
    Copy-Item "$env:SystemRoot\System32\PING.EXE" $fakeServer -Force
    $proc = Start-Process $fakeServer -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        $r = Run 'Install-GObjectPlacement.ps1' $root 'y' $engineEnv
        Check ($r.Code -eq 0 -and $r.Text -match 'server is running' -and (Test-Path $staged) -and -not (Test-Path $modFolder) -and -not (Test-Path $list)) "$L running server: stages only, AFK Realm not started" $r.Log
    } finally { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; Set-Content -LiteralPath $fakeServer -Value 'placeholder (test only)' -Encoding ascii }

    $r = Run 'Install-GObjectPlacement.ps1' $root '' @{ GP_TEST_ENGINE = 'sibling' }
    Check ($r.Code -eq 0 -and $r.Text -match 'administrator' -and $r.Text -match ([regex]::Escape("-File `"$engine`"")) -and -not (Test-Path $modFolder)) "$L not elevated: prints the command for the resolved engine" $r.Log
    $r = Run 'Install-GObjectPlacement.ps1' $root 'install' $engineEnv
    Check ($r.Code -eq 1 -and -not (Test-Path $modFolder) -and (HelpRows) -eq 0) "$L wrong confirmation word cancels before AFK Realm" $r.Log
    $r = Run 'Install-GObjectPlacement.ps1' $root 'INSTALL' ($engineEnv + @{ GP_TEST_BUILD_FAIL = '1' })
    Check ($r.Code -eq 1 -and -not (Test-Path $modFolder) -and (HelpRows) -eq 0 -and (TableCount) -eq 0) "$L build failure: AFK Realm takes the module out, databases unchanged" $r.Log

    $r = Run 'Install-GObjectPlacement.ps1' $root 'INSTALL' $engineEnv
    $line = if (Test-Path $list) { (Get-Content $list | Where-Object { $_ -like 'mod-gobject-placement|*' }) } else { '' }
    Check ($r.Code -eq 0 -and (Test-Path (Join-Path $modFolder 'src\GObjectPlacementCommands.cpp')) -and (Get-Content (Join-Path $TestRoot 'logs\install.log') -Raw) -match 'TEST ENGINE') "$L install: the resolved engine's module code cloned the module" $r.Log
    Check ("$line" -match '\|ok\|') "$L install: AFK Realm lists the module as ok" "$line"
    Check ((TableCount) -eq 3 -and (HelpRows) -eq 3) "$L install: module SQL applied (3 tables, 3 help rows)"
    $kinds = (Sql "SELECT GROUP_CONCAT(DISTINCT e.kind ORDER BY e.kind) FROM afk_modules.entries e JOIN afk_modules.batches b ON b.id = e.batch WHERE b.module = 'mod-gobject-placement';")[0]
    Check ($kinds -eq 'created,rows') "$L install: journal recorded created tables and command rows" $kinds
    $hash = (Sql "SELECT hash, state FROM acore_characters.updates WHERE name = '2026_10_28_00_gobject_placement.sql';")[0]
    Check ($hash -match '^80F4CC1[0-9A-F]+\tMODULE$') "$L install: journal hash equals the core updater's hash" $hash
    $head = & git -C (Join-Path $TestRoot 'Dependencies\Source') rev-parse HEAD
    Check ($head -eq '3f17c961fb251923b49496d81fe3fb1c367d59af') "$L install: core source revision unchanged"
    $r = Run 'Install-GObjectPlacement.ps1' $root '' $engineEnv
    Check ($r.Code -eq 1 -and $r.Text -match 'already installed') "$L repeat install refused" $r.Log

    Sql "INSERT INTO acore_characters.gobject_placement_baseline (guid, entry, map, script_name, position_x, position_y, position_z, orientation, rotation0, rotation1, rotation2, rotation3, captured_by_command) VALUES (6940236, 90387, 1, 'worldforged_pickup', 1, 2, 3, 0.5, 0, 0, 0.247404, 0.968912, 'pitch');
         INSERT INTO acore_characters.gobject_placement_verified (guid, entry, map, script_name, position_x, position_y, position_z, orientation, rotation0, rotation1, rotation2, rotation3, revision) VALUES (6940236, 90387, 1, 'worldforged_pickup', 1, 2, 3, 0.5, 0.02, -0.02, 0.247, 0.968, 2);
         INSERT INTO acore_characters.gobject_placement_history (guid, entry, map, script_name, position_x, position_y, position_z, orientation, rotation0, rotation1, rotation2, rotation3, saved_at, revision) VALUES (6940236, 90387, 1, '', 1, 2, 3, 0.5, 0, 0, 0.24, 0.97, NOW(), 1), (6940236, 90387, 1, '', 1, 2, 3, 0.5, 0.02, -0.02, 0.247, 0.968, NOW(), 2);
         INSERT INTO acore_world.gameobject (guid, id, map, position_x, position_y, position_z, orientation, rotation0, rotation1, rotation2, rotation3) VALUES (6940236, 90387, 1, 1, 2, 3, 0.5, 0.02, -0.02, 0.247, 0.968);" | Out-Null
    $r = Run 'Uninstall-GObjectPlacement.ps1' $root 'UNINSTALL' $engineEnv
    $dumps = @(Get-ChildItem (Join-Path $TestRoot 'Backups\gobject-placement') -Filter '*.sql' -ErrorAction SilentlyContinue)
    Check ($r.Code -eq 0 -and -not (Test-Path $modFolder) -and -not ((Get-Content $list -ErrorAction SilentlyContinue) -match 'mod-gobject-placement')) "$L uninstall: AFK Realm removed the module" $r.Log
    Check ($r.Text -match 'table of the module removed' -and $r.Text -match 'gobject_placement_history \(2 rows\)' -and $r.Text -match 'loading the dump back') "$L uninstall: AFK Realm dropped the tables; real counts reported; dump loaded back" $r.Log
    Check ((Count 'SELECT COUNT(*) FROM acore_characters.gobject_placement_history') -eq 2 -and (Count 'SELECT revision FROM acore_characters.gobject_placement_verified') -eq 2 -and (Count 'SELECT COUNT(*) FROM acore_characters.gobject_placement_baseline') -eq 1) "$L uninstall (default): placement records restored"
    Check ((HelpRows) -eq 0 -and $dumps.Count -eq 1) "$L uninstall: help rows removed, dump kept"
    Check ((Sql 'SELECT rotation0 FROM acore_world.gameobject WHERE guid = 6940236')[0] -eq '0.02') "$L uninstall: tilted gameobject row unchanged"
    Check (@(Get-ChildItem (Join-Path $TestRoot 'Backups') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.txt') }).Count -eq 3) "$L existing snapshot folders untouched"

    $r = Run 'Install-GObjectPlacement.ps1' $root 'INSTALL' $engineEnv
    Check ($r.Code -eq 0 -and (Count 'SELECT COUNT(*) FROM acore_characters.gobject_placement_history') -eq 2 -and (HelpRows) -eq 3) "$L reinstall: records kept, help rows back" $r.Log
    $r = Run 'Uninstall-GObjectPlacement.ps1' $root 'UNINSTALL' $engineEnv
    Check ($r.Code -eq 0 -and $r.Text -match 'left the placement tables in place' -and (Count 'SELECT COUNT(*) FROM acore_characters.gobject_placement_history') -eq 2 -and (HelpRows) -eq 0) "$L uninstall after reinstall: pre-existing tables kept" $r.Log
    $r = Run 'Install-GObjectPlacement.ps1' $root 'INSTALL' $engineEnv
    $r = Run 'Uninstall-GObjectPlacement.ps1' ($root + '-RemovePlacementData') 'delete' $engineEnv
    Check ($r.Code -eq 1 -and (Test-Path $modFolder) -and (TableCount) -eq 3) "$L RemovePlacementData: wrong confirmation cancels" $r.Log
    $r = Run 'Uninstall-GObjectPlacement.ps1' ($root + '-RemovePlacementData') 'DELETE|UNINSTALL' $engineEnv
    Check ($r.Code -eq 0 -and (TableCount) -eq 0 -and @(Get-ChildItem (Join-Path $TestRoot 'Backups\gobject-placement') -Filter '*.sql').Count -eq 3) "$L RemovePlacementData: tables removed, dumps kept" $r.Log

    Reset-Databases
    Reset-Install $TestRoot
    & git clone --quiet (Join-Path $script:pkg 'payload\mod-gobject-placement.bundle') $modFolder 2>&1 | Out-Null
    Check (Test-Path (Join-Path $modFolder 'src\GP_loader.cpp')) "$L plain git clone of the bundle checks out the module"
    foreach ($f in Get-ChildItem (Join-Path $modFolder 'data\sql\db-characters') -Filter *.sql) { Source-File $f.FullName 'acore_characters' }
    foreach ($f in Get-ChildItem (Join-Path $modFolder 'data\sql\db-world') -Filter *.sql) { Source-File $f.FullName 'acore_world' }
    Sql "INSERT INTO acore_characters.updates (name, hash, state) VALUES ('2026_10_28_00_gobject_placement.sql', 'X', 'MODULE'); INSERT INTO acore_world.updates (name, hash, state) VALUES ('2026_10_28_00_gobject_placement_commands.sql', 'X', 'MODULE'); INSERT INTO acore_characters.gobject_placement_history (guid, entry, map, position_x, position_y, position_z, orientation, rotation0, rotation1, rotation2, rotation3, saved_at, revision) VALUES (1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 1, NOW(), 1);" | Out-Null
    $r = Run 'Install-GObjectPlacement.ps1' $root '' $engineEnv
    Check ($r.Code -eq 1 -and $r.Text -match 'already installed') "$L hand-copied module detected by the installer" $r.Log
    $r = Run 'Uninstall-GObjectPlacement.ps1' $root 'UNINSTALL|YES' $engineEnv
    Check ($r.Code -eq 0 -and -not (Test-Path $modFolder) -and $r.Text -match 'not installed through AFK Realm') "$L hand-copied uninstall: AFK Realm leaves the database alone" $r.Log
    Check ((TableCount) -eq 3 -and (Count 'SELECT COUNT(*) FROM acore_characters.gobject_placement_history') -eq 1 -and (HelpRows) -eq 0 -and (Count "SELECT COUNT(*) FROM acore_world.updates WHERE name LIKE '2026_10_28_00_gobject%'") -eq 0) "$L hand-copied uninstall: records kept, help rows and update entries removed"
    $r = Run 'Uninstall-GObjectPlacement.ps1' $root '' $engineEnv
    Check ($r.Code -eq 0 -and $r.Text -match 'Nothing to remove') "$L uninstall when not installed: nothing changed" $r.Log
    Reset-Install $TestRoot
}

Invoke-Suite 'classic'
Invoke-Suite 'program'

$dirty = @(Get-ChildItem $script:logDir -Filter '*.log' | Where-Object { (Get-Content $_.FullName -Raw) -match 'PropertyNotFound|System\.String\[\]|ParameterBindingException' })
Check ($dirty.Count -eq 0) 'No run printed PropertyNotFound, System.String[] or a binding error' (($dirty | ForEach-Object Name) -join ', ')

foreach ($f in $fakeClassic, $fakeProgram) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
Set-AfkSettings @()
foreach ($k in 'GP_TEST_MODE', 'GP_TEST_ANSWERS', 'GP_TEST_APPDATA') { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
$failed = @($script:results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("{0} checks, {1} failed. Logs: {2}" -f $script:results.Count, $failed.Count, $script:logDir)
$script:results | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $script:logDir 'results.json')
if ($failed.Count) { exit 1 } else { exit 0 }
