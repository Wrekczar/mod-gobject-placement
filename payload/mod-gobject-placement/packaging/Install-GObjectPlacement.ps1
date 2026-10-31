#requires -Version 5.1
<#
.SYNOPSIS
    Installs mod-gobject-placement (.gobject pitch / roll / save) into an AFK Realm server
    through AFK Realm's own module system.

.DESCRIPTION
    1. Finds the AFK Realm installation (or takes -InstallRoot) and runs read-only checks:
       engine, core source, revision, interfaces, build tools, conflicts, existing install,
       and (if the database already runs) the database layout.
    2. Shows a preview and asks before it changes anything.
    3. Stages the module as a local Git repository in <install>\Dependencies\LocalModules
       (the only thing this script creates itself).
    4. With the server stopped and a second, separate confirmation, runs the AFK Realm engine:
           -Mode Modules -AddModules file:///<install>/Dependencies/LocalModules/mod-gobject-placement.git
       AFK Realm then backs up the server, builds it with the module at the CURRENT core revision,
       installs the new programs only if the build succeeds (otherwise it takes the module out
       again), and applies + records the module SQL so that removing the module undoes it.

    This script never stops or starts the server or database, never edits databases itself,
    never updates the core source and never stores or prints a password (AFK Realm asks for it).

.PARAMETER InstallRoot
    The AFK Realm SERVER folder (the one with Dependencies, Server, DB, e.g. C:\CoA-Server). The AFK Realm
    program folder (e.g. C:\!AFK\AFK-Realm-main, with engine\engine.ps1) is accepted too: its server folder is
    then taken from AFK Realm's settings. Asked for when omitted.
.PARAMETER EnginePath
    The AFK Realm engine to run. By default the copy AFK Realm extracted into <server>\Builder, else
    <server>\engine\engine.ps1, else engine\engine.ps1 of the AFK Realm program folder.
.PARAMETER CheckOnly
    Only run the checks and show the preview.
.PARAMETER StageOnly
    Stage the module but do not run AFK Realm (prints the command to run later).
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [string]$EnginePath = '',
    [switch]$CheckOnly,
    [switch]$StageOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\GObjectPlacement.Common.ps1')

$payload = Join-Path $PSScriptRoot 'payload'
$bundle = Join-Path $payload "$script:ModuleName.bundle"
$expectedCommitFile = Join-Path $payload 'COMMIT.txt'

function Show-State($State) {
    foreach ($f in $State.Facts) { Write-Ok $f }
    foreach ($w in $State.Warnings) { Write-Warn $w }
    foreach ($p in $State.Problems) { Write-Bad $p }
}

function Exit-With([int]$Code, [string]$Message) {
    Write-Host ''
    if ($Code -eq 0) { Write-Host $Message -ForegroundColor Green } else { Write-Host $Message -ForegroundColor Red }
    exit $Code
}

Write-Host "mod-gobject-placement installer $script:PackageVersion" -ForegroundColor White
if (-not (Test-Path -LiteralPath $bundle) -or -not (Test-Path -LiteralPath $expectedCommitFile)) { Exit-With 2 "The package is incomplete: $bundle or COMMIT.txt is missing." }
$expectedCommit = ([IO.File]::ReadAllText($expectedCommitFile)).Trim()

$selection = Select-AfkRoot $InstallRoot $EnginePath
if (-not $selection) { Exit-With 1 'Cancelled. Nothing was changed.' }
$root = $selection.Root
$paths = Get-AfkPaths $root $selection.Engine

Write-Step "Checking $root (read only)"
foreach ($n in $selection.Notes) { Write-Info $n }
if ($selection.EngineSource) { Write-Info "Engine source: $($selection.EngineSource)" }
$state = Get-InstallState $paths $payload
Show-State $state
if ($state.Fatal) { Exit-With 1 'Cannot continue: see the problem above. Nothing was changed.' }
if ($state.Git) {
    $verify = Invoke-Git $state.Git @('bundle', 'verify', $bundle)
    $bundleHead = Invoke-Git $state.Git @('bundle', 'list-heads', $bundle)
    if ($verify.Code -ne 0 -or $bundleHead.Text -notmatch [regex]::Escape($expectedCommit)) { $state.Problems.Add('The module bundle in the package is damaged or does not contain the expected commit.') ; Write-Bad 'Package bundle check failed.' }
    else { Write-Ok "Package module commit: $expectedCommit" }
}

Write-Step 'Database (read only, only if it already runs)'
$db = Test-DatabaseState $paths $false
foreach ($n in $db.Notes) { Write-Info $n }
foreach ($p in $db.Problems) { Write-Bad $p; $state.Problems.Add($p) }
if ($db.Checked) { Write-Ok 'acore_world and acore_characters have the expected layout.' }

if ($state.StagedPresent) {
    if ($state.StagedCommit -eq $expectedCommit) { Write-Ok "Already staged from an earlier run: $($paths.StagedRepo) (same commit, reused)." }
    else { $state.Problems.Add("$($paths.StagedRepo) exists but holds a different commit ($($state.StagedCommit)). Move it away, then run again.") ; Write-Bad 'A different staged copy exists.' }
}

Write-Step 'Preview'
Write-Info "Module:          $script:ModuleName $script:PackageVersion (commit $($expectedCommit.Substring(0, 8)))"
Write-Info "Installation:    $root"
Write-Info "Core revision:   $($state.Revision)  (stays as it is; nothing is updated from GitHub)"
if (-not $state.StagedPresent) { Write-Info "This script adds: $($paths.StagedRepo)  (new folder; nothing existing is replaced)" }
Write-Info 'AFK Realm then (only after your second confirmation, server stopped):'
Write-Info '  1. saves a backup snapshot of programs, configs and all databases in Backups\'
if ($state.Snapshots.WouldBeRemoved.Count -gt 0) {
    Write-Warn ("     AFK Realm keeps {0} snapshots; making this one removes the oldest: {1}" -f $state.Snapshots.Keep, ($state.Snapshots.WouldBeRemoved -join ', '))
    Write-Warn '     Copy that folder elsewhere first if you want to keep it (or raise keep= in Dependencies\backup-settings.txt).'
}
Write-Info "  2. clones the module into $($paths.ModuleFolder)"
Write-Info '  3. builds the server at the current revision (incremental; can take 10-40 minutes)'
Write-Info '  4. only if the build succeeds: replaces the programs in Server\ (otherwise takes the module out; server unchanged)'
Write-Info '  5. applies and records the module SQL:'
Write-Info '       acore_characters: creates gobject_placement_verified / _history / _baseline (if not there)'
Write-Info "       acore_world:      3 help rows in 'command' (gobject pitch / roll / save)"
Write-Info '     No gameobject row is changed by installing.'

if ($state.Problems.Count -gt 0) { Exit-With 1 ("Cannot install: {0} problem(s) above. Nothing was changed." -f $state.Problems.Count) }
if ($CheckOnly) { Exit-With 0 'Check finished. Nothing was changed (-CheckOnly).' }

# ---- Step 1: stage (the only change this script makes itself)
$created = New-Object Collections.Generic.List[string]
if (-not $state.StagedPresent) {
    if (-not (Confirm-YesNo "Stage the module in $($paths.StagedRepo)?")) { Exit-With 1 'Cancelled. Nothing was changed.' }
    try {
        if (-not (Test-Path -LiteralPath $paths.LocalRepos)) { New-Item -ItemType Directory -Path $paths.LocalRepos | Out-Null; $created.Add($paths.LocalRepos) }
        $created.Add($paths.StagedRepo)
        $clone = Invoke-Git $state.Git @('clone', '--quiet', '--bare', '--branch', 'main', $bundle, $paths.StagedRepo)
        if ($clone.Code -ne 0) { throw "git clone failed: $($clone.Text)" }
        $null = Invoke-Git $state.Git @('--git-dir', $paths.StagedRepo, 'remote', 'remove', 'origin')
        $head = Invoke-Git $state.Git @('--git-dir', $paths.StagedRepo, 'rev-parse', 'refs/heads/main')
        if ($head.Text -ne $expectedCommit) { throw "staged commit is $($head.Text), expected $expectedCommit" }
        if (Test-Hook 'GP_TEST_FAIL_AFTER_STAGE') { throw 'simulated failure after staging (test)' }
        Write-Ok "Staged $($paths.StagedRepo)"
    } catch {
        Write-Bad "Staging failed: $($_.Exception.Message)"
        for ($i = $created.Count - 1; $i -ge 0; $i--) {
            if (Test-Path -LiteralPath $created[$i]) { Remove-Item -LiteralPath $created[$i] -Recurse -Force; Write-Info "rolled back: removed $($created[$i]) (created by this run)" }
        }
        Exit-With 1 'Installation stopped. Only what this run had created was removed; nothing else was changed.'
    }
}

$command = Get-EngineCommand $paths ('-AddModules "{0}"' -f $paths.StagedUrl)
if ($StageOnly) {
    Write-Host ''
    Write-Host 'Staged. When the server is stopped, run this in an administrator PowerShell:' -ForegroundColor Yellow
    Write-Host "  $command"
    Exit-With 0 'Staging finished (-StageOnly). The server was not touched.'
}

# ---- Step 2: AFK Realm module installation (affects the server; separate confirmation)
$running = @(Get-ServerProcesses $paths)
if ($running.Count -gt 0) {
    Write-Host ''
    Write-Warn ("The server is running ({0}). AFK Realm can only add a module while worldserver and authserver are stopped." -f (($running | ForEach-Object { $_.ProcessName }) -join ', '))
    Write-Info 'Nothing was stopped. When you are ready: stop the server, then run this installer again'
    Write-Info '(it reuses the staged copy) or run in an administrator PowerShell:'
    Write-Info "  $command"
    Exit-With 0 'Staged; the server was left running and unchanged.'
}
if (-not (Test-IsAdministrator)) {
    Write-Host ''
    Write-Warn 'AFK Realm needs administrator rights for this step.'
    Write-Info 'Run this installer again from an administrator PowerShell, or run:'
    Write-Info "  $command"
    Exit-With 0 'Staged; the server was not touched.'
}
$question = "Run AFK Realm now to back up, rebuild and install the module into $root ? AFK Realm will ask for the database password, start and stop the database itself, and replace the server programs only after a successful build."
if (-not (Confirm-Word $question 'INSTALL')) {
    Write-Info 'The staged copy stays; run this installer again to continue, or:'
    Write-Info "  $command"
    Exit-With 1 'Cancelled before AFK Realm ran. The server was not touched.'
}

Write-Step 'AFK Realm module installation (output below is from AFK Realm)'
$code = Invoke-Engine $paths @('-AddModules', $paths.StagedUrl)
$line = Get-ManagedModuleLine $paths
if ($code -eq 0 -and $line -and ($line.Split('|')[4] -eq 'ok')) {
    Write-Ok "AFK Realm lists the module: $line"
    Write-Host ''
    Write-Host 'Next: start the server when you choose (AFK Realm app or START-SERVER.cmd), then in game:' -ForegroundColor White
    Write-Info '.help gobject pitch       (should print the syntax)'
    Write-Info 'See README.md "In-game check" for the full acceptance list.'
    Exit-With 0 'Installed.'
}
Write-Bad "AFK Realm ended with code $code; module list entry: $line"
Write-Info 'If the build failed, AFK Realm already took the module out and kept the old programs (see logs\install.log).'
Write-Info 'The backup snapshot it made is in Backups\. See TROUBLESHOOTING.md.'
Exit-With 1 'Installation did not complete.'
