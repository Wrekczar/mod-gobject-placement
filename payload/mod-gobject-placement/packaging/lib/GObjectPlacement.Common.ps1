#requires -Version 5.1
# Shared helpers for Install-/Uninstall-GObjectPlacement.ps1. Windows PowerShell 5.1 and PowerShell 7.
# Nothing in here changes files or databases; changes happen only in the two scripts, after confirmation.

Set-StrictMode -Version 2.0

$script:ModuleName = 'mod-gobject-placement'
$script:PackageVersion = '1.0.0'
# Core revisions this package was compiled against (full builds of the core with all its modules).
$script:TestedRevisions = [ordered]@{
    '3f17c961fb251923b49496d81fe3fb1c367d59af' = 'AFK Realm install of 2026-10-20 (compiled and database-tested)'
    '3c6e24e4ba85f8a448c95b92eb8f7e5d068e1890' = 'upstream main of 2026-10-28 (compiled)'
}
# Core interfaces the module calls; each must exist in the target source tree.
$script:ApiMarkers = @(
    @{ File = 'src\server\game\Chat\Chat.h'; Text = 'GetObjectFromPlayerMapByDbGuid(ObjectGuid::LowType lowguid)' },
    @{ File = 'src\server\game\Chat\ChatCommands\ChatCommand.cpp'; Text = 'LoadCommandsIntoMap' },
    @{ File = 'src\server\game\Entities\GameObject\GameObject.h'; Text = 'G3D::Quat const& GetWorldRotation() const' },
    @{ File = 'src\server\game\Entities\GameObject\GameObject.h'; Text = 'bool LoadGameObjectFromDB(ObjectGuid::LowType guid, Map* map, bool addToMap = true)' },
    @{ File = 'src\server\game\Globals\ObjectMgr.h'; Text = 'GameObjectData& NewGOData(ObjectGuid::LowType guid)' },
    @{ File = 'src\server\game\Globals\ObjectMgr.h'; Text = 'GameObjectData const* GetGameObjectData(ObjectGuid::LowType spawnId) const' },
    @{ File = 'src\server\game\Entities\GameObject\GameObjectData.h'; Text = 'G3D::Quat rotation;' },
    @{ File = 'src\server\database\Database\Transaction.h'; Text = 'void Append(std::string_view sql, Args&&... args)' },
    @{ File = 'data\sql\base\db_world\gameobject.sql'; Text = '`rotation3` float NOT NULL' },
    @{ File = 'data\sql\base\db_world\command.sql'; Text = '`security` tinyint unsigned NOT NULL' }
)
$script:PlacementTables = @('gobject_placement_verified', 'gobject_placement_history', 'gobject_placement_baseline')
$script:ModuleSqlFiles = @('2026_10_28_00_gobject_placement.sql', '2026_10_28_00_gobject_placement_commands.sql')

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "         $Text" }

# Automated tests of this package set GP_TEST_MODE=1 and answer questions through GP_TEST_ANSWERS
# ("answer1|answer2|..."); without GP_TEST_MODE every question is asked on the console.
$script:TestMode = ($env:GP_TEST_MODE -eq '1')
$script:TestAnswers = New-Object Collections.Generic.Queue[string]
if ($script:TestMode -and $env:GP_TEST_ANSWERS) { foreach ($a in $env:GP_TEST_ANSWERS.Split('|')) { $script:TestAnswers.Enqueue($a) } }

function Read-Answer([string]$Prompt) {
    if ($script:TestMode) {
        if ($script:TestAnswers.Count -eq 0) { throw "Test answer queue is empty at: $Prompt" }
        $answer = $script:TestAnswers.Dequeue()
        if ($answer -eq '<empty>') { $answer = '' }
        Write-Host "$Prompt $answer"
        return $answer
    }
    return (Read-Host $Prompt)
}

function Test-Hook([string]$Name) { return ($script:TestMode -and [Environment]::GetEnvironmentVariable($Name) -eq '1') }

function Confirm-Word([string]$Question, [string]$Word) {
    Write-Host ''
    Write-Host $Question -ForegroundColor White
    $answer = Read-Answer "Type $Word to continue, anything else cancels"
    return ($answer -ceq $Word)
}

function Confirm-YesNo([string]$Question) {
    $answer = Read-Answer "$Question [y/N]"
    return ($answer -match '^(y|yes)$')
}

function Test-IsAdministrator {
    if (Test-Hook 'GP_TEST_ASSUME_ADMIN') { return $true }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Folders that must never be looked into (the play client). Matching is on the folder name.
function Test-ProtectedName([string]$Name) { return ($Name -match '(^|[^a-z])wow([^a-z]|$)') }

# AFK Realm has two layouts, and both run the same engine:
#   server folder   <root>\Dependencies\Source, <root>\Server, <root>\DB  - what -InstallRoot names; the app extracts
#                   its engine to <root>\Builder\AFK-Realm-Engine.ps1 (+ module-journal.sql) before every run
#   program folder  the AFK Realm app itself; from source (e.g. AFK-Realm-main) it holds engine\engine.ps1 and
#                   engine\module-journal.sql - the files the app embeds and extracts
# The app remembers its server folders in %APPDATA%\AFK-Realm\servers.txt and last-install.txt.
$script:SystemFolderPattern = '^\$|^System Volume Information$|^Windows$|^ProgramData$|^Program Files|^Recovery$|^PerfLogs$|^Users$'

function Test-ServerRoot([string]$Dir) {
    return ((Test-Path -LiteralPath (Join-Path $Dir 'Dependencies\Source')) -and (Test-Path -LiteralPath (Join-Path $Dir 'Server')))
}

function Test-ProgramFolder([string]$Dir) {
    return ((Test-Path -LiteralPath (Join-Path $Dir 'engine\engine.ps1')) -and (Test-Path -LiteralPath (Join-Path $Dir 'engine\module-journal.sql')))
}

function Get-AfkSettingsServers {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ($script:TestMode -and $env:GP_TEST_APPDATA) { $appData = $env:GP_TEST_APPDATA }
    $dir = Join-Path $appData 'AFK-Realm'
    $roots = New-Object Collections.Generic.List[string]
    foreach ($file in @((Join-Path $dir 'last-install.txt'), (Join-Path $dir 'servers.txt'))) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        foreach ($line in [IO.File]::ReadAllLines($file)) {
            $root = $line.Split("`t")[0].Trim().TrimEnd('\')
            if ($root -and -not (Test-ProtectedName (Split-Path $root -Leaf)) -and -not ($roots -contains $root)) { $roots.Add($root) }
        }
    }
    return $roots.ToArray()
}

# Folders up to two levels below each fixed drive's root; folders named like a game client are never entered.
function Get-ScanFolders {
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne [IO.DriveType]::Fixed -or -not $drive.IsReady) { continue }
        $top = @(Get-ChildItem -LiteralPath $drive.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue |
                 Where-Object { -not (Test-ProtectedName $_.Name) -and $_.Name -notmatch $script:SystemFolderPattern })
        foreach ($folder in $top) {
            $folder.FullName
            Get-ChildItem -LiteralPath $folder.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-ProtectedName $_.Name) } | ForEach-Object { $_.FullName }
        }
    }
}

# Server folders (AFK Realm's own list first, then the disk scan) and program folders.
function Find-AfkInstallations {
    $servers = New-Object Collections.Generic.List[object]
    $programs = New-Object Collections.Generic.List[string]
    foreach ($root in Get-AfkSettingsServers) {
        if (Test-ServerRoot $root) { $servers.Add([pscustomobject]@{ Root = $root; Source = 'AFK Realm settings' }) }
    }
    foreach ($dir in Get-ScanFolders) {
        if ((Test-ServerRoot $dir) -and -not ($servers | Where-Object { $_.Root -eq $dir })) { $servers.Add([pscustomobject]@{ Root = $dir; Source = 'found on disk' }) }
        if (Test-ProgramFolder $dir) { $programs.Add($dir) }
    }
    return [pscustomobject]@{ Servers = $servers.ToArray(); Programs = $programs.ToArray() }
}

function Find-AfkRoots { return @((Find-AfkInstallations).Servers | ForEach-Object { $_.Root }) }

# Which engine to run for a server folder, in this order: an explicit -EnginePath; the copy the app extracted into
# the server folder (the version that last ran on this server); engine\engine.ps1 inside the server folder; the
# program folder this was started from or the only one found on disk. Returns $null when none is found.
function Resolve-Engine([string]$Root, [string]$EnginePath, [string[]]$ProgramFolders) {
    if ($EnginePath) { return [pscustomobject]@{ Path = [IO.Path]::GetFullPath($EnginePath); Source = 'given with -EnginePath' } }
    $builder = Join-Path $Root 'Builder\AFK-Realm-Engine.ps1'
    if (Test-Path -LiteralPath $builder) { return [pscustomobject]@{ Path = $builder; Source = 'extracted by the AFK Realm app into the server folder' } }
    $local = Join-Path $Root 'engine\engine.ps1'
    if (Test-Path -LiteralPath $local) { return [pscustomobject]@{ Path = $local; Source = 'AFK Realm program files in the server folder' } }
    $programs = @($ProgramFolders | Where-Object { $_ } | Select-Object -Unique)
    if ($programs.Count -eq 1) { return [pscustomobject]@{ Path = (Join-Path $programs[0] 'engine\engine.ps1'); Source = "AFK Realm program folder $($programs[0])" } }
    return $null
}

# Returns @{ Root; Engine; EngineSource; Notes } or $null when cancelled. A program folder given or typed is
# mapped to its server folder through AFK Realm's settings.
function Select-AfkRoot([string]$Given, [string]$EnginePath = '') {
    $notes = New-Object Collections.Generic.List[string]
    $found = $null
    $root = $null
    $programs = @()
    $answer = $Given
    while (-not $root) {
        if (-not $answer) {
            if (-not $found) { $found = Find-AfkInstallations }
            $servers = @($found.Servers)
            Write-Step 'AFK Realm server'
            if ($servers.Count -eq 0) { Write-Info 'No AFK Realm server folder found (one with Dependencies\Source and Server).' }
            for ($i = 0; $i -lt $servers.Count; $i++) { Write-Info ('{0}) {1}   ({2})' -f ($i + 1), $servers[$i].Root, $servers[$i].Source) }
            $answer = Read-Answer 'Number of the server, or the full path of its folder (empty cancels)'
            if (-not $answer) { return $null }
            $n = 0
            if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $servers.Count) { $answer = $servers[$n - 1].Root }
        }
        $full = [IO.Path]::GetFullPath($answer.Trim().Trim('"')).TrimEnd('\')
        if (Test-ProtectedName (Split-Path $full -Leaf)) { throw "Refusing to use $full (protected folder name)." }
        if (Test-ServerRoot $full) { $root = $full; break }
        if (Test-ProgramFolder $full) {
            $programs += $full
            $servers = @(Get-AfkSettingsServers | Where-Object { Test-ServerRoot $_ })
            $notes.Add("$full is the AFK Realm program folder (engine\engine.ps1); the module goes into its server folder.")
            if ($servers.Count -eq 1) { $root = $servers[0]; $notes.Add("Server folder from AFK Realm's settings: $root"); break }
            if ($servers.Count -gt 1) {
                Write-Step "Servers known to AFK Realm"
                for ($i = 0; $i -lt $servers.Count; $i++) { Write-Info ('{0}) {1}' -f ($i + 1), $servers[$i]) }
                $pick = Read-Answer 'Number of the server (empty cancels)'
                $n = 0
                if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $servers.Count) { $root = $servers[$n - 1]; break }
                return $null
            }
            Write-Warn "$full is the AFK Realm program folder, and AFK Realm's settings name no server folder."
            $answer = Read-Answer 'Full path of the server folder (the one with Dependencies, Server and DB; empty cancels)'
            if (-not $answer) { return $null }
            continue
        }
        Write-Warn "$full is neither an AFK Realm server folder (Dependencies\Source + Server) nor its program folder (engine\engine.ps1)."
        if ($Given -and $answer -eq $Given) { return [pscustomobject]@{ Root = $full; Engine = $null; EngineSource = ''; Notes = $notes.ToArray() } }
        $answer = ''
    }
    $engine = Resolve-Engine $root $EnginePath $programs
    if (-not $engine) {
        if ($found) { $programs = @($found.Programs) } else { $programs = @(Get-ScanFolders | Where-Object { Test-ProgramFolder $_ }) }
        $engine = Resolve-Engine $root $EnginePath $programs
        if (-not $engine -and $programs.Count -gt 1) { $notes.Add("Several AFK Realm program folders were found ($($programs -join ', ')); pass -EnginePath to choose one.") }
    }
    return [pscustomobject]@{ Root = $root; Engine = $(if ($engine) { $engine.Path } else { $null }); EngineSource = $(if ($engine) { $engine.Source } else { '' }); Notes = $notes.ToArray() }
}

function Get-AfkPaths([string]$Root, [string]$Engine = '') {
    if (-not $Engine) { $Engine = Join-Path $Root 'Builder\AFK-Realm-Engine.ps1' }
    $p = [ordered]@{
        Root       = $Root
        Engine     = $Engine
        Journal    = Join-Path (Split-Path $Engine -Parent) 'module-journal.sql'
        Deps       = Join-Path $Root 'Dependencies'
        Source     = Join-Path $Root 'Dependencies\Source'
        Build      = Join-Path $Root 'Dependencies\Build'
        Server     = Join-Path $Root 'Server'
        Revisions  = Join-Path $Root 'Dependencies\revisions.txt'
        ModuleList = Join-Path $Root 'Dependencies\modules.txt'
        Backups    = Join-Path $Root 'Backups'
        LocalRepos = Join-Path $Root 'Dependencies\LocalModules'
        Cnf        = Join-Path $Root 'DB\launcher.cnf'
        MyIni      = Join-Path $Root 'DB\my.ini'
        MySqlBin   = Join-Path $Root 'DB\mysql\bin'
    }
    $p.Modules = Join-Path $p.Source 'modules'
    $p.ModuleFolder = Join-Path $p.Modules $script:ModuleName
    $p.StagedRepo = Join-Path $p.LocalRepos "$script:ModuleName.git"
    $p.StagedUrl = 'file:///' + $p.StagedRepo.Replace('\', '/')
    return $p
}

function Find-Git([hashtable]$Paths) {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($candidate in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
                             "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe", (Join-Path $Paths.Deps 'Git\cmd\git.exe'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

# Runs a native program. Windows PowerShell 5.1 turns stderr lines into errors that 'Stop' would make fatal,
# so they are collected as text instead (git and mysql write normal progress to stderr).
function Invoke-Native([string]$Program, [string[]]$Arguments, [string]$InputText = $null) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($null -ne $InputText) { $output = $InputText | & $Program @Arguments 2>&1 } else { $output = & $Program @Arguments 2>&1 }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    $lines = @($output | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } })
    return [pscustomobject]@{ Code = $code; Lines = $lines; Text = ($lines -join "`n").Trim() }
}

function Invoke-Git([string]$Git, [string[]]$Arguments) { return (Invoke-Native $Git $Arguments) }

function Get-DatabasePort([hashtable]$Paths) {
    if (Test-Path -LiteralPath $Paths.MyIni) {
        $line = Select-String -LiteralPath $Paths.MyIni -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -First 1
        if ($line) { return [int]$line.Matches[0].Groups[1].Value }
    }
    return 3307
}

function Test-TcpPort([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(700)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Get-ServerProcesses([hashtable]$Paths) {
    return @(Get-Process -Name worldserver, authserver -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($Paths.Server, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
}

# Read-only or explicitly confirmed SQL through the launcher's own client file (the password stays in that file).
function Invoke-LauncherSql([hashtable]$Paths, [string]$Sql, [string]$Database = '') {
    $mysql = Join-Path $Paths.MySqlBin 'mysql.exe'
    $arguments = @("--defaults-extra-file=$($Paths.Cnf)", '--batch', '--skip-column-names', '--default-character-set=utf8mb4', '-e', $Sql)
    if ($Database) { $arguments += $Database }
    $r = Invoke-Native $mysql $arguments
    if ($r.Code -ne 0) { throw ("mysql failed: " + ($r.Lines -join ' ')) }
    return @($r.Lines | Where-Object { $_ -ne '' })
}

# First row as a whole string (indexing a one-row result directly would index its characters).
function Get-LauncherSqlValue([hashtable]$Paths, [string]$Sql) {
    $rows = @(Invoke-LauncherSql $Paths $Sql)
    if ($rows.Count -eq 0) { return '' }
    return [string]$rows[0]
}

function Get-ManagedModuleLine([hashtable]$Paths) {
    if (-not (Test-Path -LiteralPath $Paths.ModuleList)) { return $null }
    return (Get-Content -LiteralPath $Paths.ModuleList | Where-Object { $_ -like "$script:ModuleName|*" } | Select-Object -First 1)
}

function Get-SnapshotInfo([hashtable]$Paths) {
    $keep = 3
    $keepFile = Join-Path $Paths.Deps 'backup-settings.txt'
    if (Test-Path -LiteralPath $keepFile) {
        foreach ($line in Get-Content -LiteralPath $keepFile) {
            if ($line -match '^\s*keep\s*=\s*(\d+)\s*$') { $keep = [int]$Matches[1]; break }
        }
    }
    $snapshots = @()
    if (Test-Path -LiteralPath $Paths.Backups) {
        $snapshots = @(Get-ChildItem -LiteralPath $Paths.Backups -Directory | Where-Object {
            $_.Name -notlike '*.partial' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.txt')) } | Sort-Object Name -Descending)
    }
    $pruned = @()
    if ($snapshots.Count -ge $keep) { $pruned = @($snapshots | Select-Object -Skip ($keep - 1) | ForEach-Object { $_.Name }) }
    return [pscustomobject]@{ Keep = $keep; Existing = @($snapshots | ForEach-Object { $_.Name }); WouldBeRemoved = $pruned }
}

# Everything the installer needs to decide; no side effects.
function Get-InstallState([hashtable]$Paths, [string]$PayloadDir) {
    # Every field exists from the start: callers read them even when a check stops early (strict mode).
    $s = [ordered]@{ Problems = New-Object Collections.Generic.List[string]; Warnings = New-Object Collections.Generic.List[string]
                     Facts = New-Object Collections.Generic.List[string]; Fatal = $false
                     EngineHash = ''; EngineModules = $false; EngineKeepsModules = $false; Git = $null; Revision = ''
                     ModulesIgnored = $false; Conflicts = @(); FolderPresent = $false; ManagedLine = $null
                     StagedPresent = $false; StagedCommit = ''; FreeGB = 0; Running = @(); DbPort = 3307; DbUp = $false
                     Snapshots = [pscustomobject]@{ Keep = 3; Existing = @(); WouldBeRemoved = @() }; Payload = $PayloadDir }

    if (-not (Test-ServerRoot $Paths.Root)) {
        $s.Problems.Add("$($Paths.Root) is not an AFK Realm server folder (it needs Dependencies\Source and Server). Pick the folder AFK Realm installed the server into.")
        $s.Fatal = $true
        return $s
    }
    if (-not (Test-Path -LiteralPath $Paths.Engine)) {
        $s.Problems.Add("No AFK Realm engine found for this server (looked for $($Paths.Engine), engine\engine.ps1 and AFK Realm program folders). Open the server once in AFK Realm, or pass -EnginePath <AFK Realm folder>\engine\engine.ps1.")
        $s.Fatal = $true
        return $s
    }
    $s.Facts.Add("AFK Realm engine: $($Paths.Engine)")
    $engineText = [IO.File]::ReadAllText($Paths.Engine)
    $s.EngineHash = (Get-FileHash -LiteralPath $Paths.Engine -Algorithm SHA256).Hash
    $s.EngineModules = $engineText.Contains("'Modules'") -and $engineText.Contains('function Edit-ModuleFolders') -and $engineText.Contains('-AddModules')
    $s.EngineKeepsModules = $engineText.Contains("@('-e', 'modules/')")
    if (-not $s.EngineModules) { $s.Problems.Add('This AFK Realm engine has no module mode (-Mode Modules). Update AFK Realm, or use the manual route in README.') }
    if (-not $s.EngineKeepsModules) { $s.Warnings.Add('Could not confirm that this AFK Realm version keeps extra folders in Source\modules during updates.') }
    if (-not (Test-Path -LiteralPath $Paths.Journal)) { $s.Problems.Add("$($Paths.Journal) is missing; AFK Realm cannot record module database changes.") }

    $git = Find-Git $Paths
    $s.Git = $git
    if (-not $git) { $s.Problems.Add('Git was not found (Program Files, PATH or AFK Realm''s portable copy).') } else { $s.Facts.Add("Git: $git") }

    if (-not (Test-Path -LiteralPath (Join-Path $Paths.Source '.git'))) {
        $s.Problems.Add("No CoACore source tree (Git checkout) at $($Paths.Source).")
    } elseif ($git) {
        $head = Invoke-Git $git @('-C', $Paths.Source, 'rev-parse', 'HEAD')
        $s.Revision = if ($head.Code -eq 0) { $head.Text } else { '' }
        $s.Facts.Add("Core source revision: $($s.Revision)")
        if ($script:TestedRevisions.Contains($s.Revision)) { $s.Facts.Add("Tested revision: $($script:TestedRevisions[$s.Revision])") }
        elseif ($s.Revision) { $s.Warnings.Add("Revision $($s.Revision.Substring(0, 8)) was not compiled with this package. The interfaces it needs are checked below; if the build still fails, AFK Realm takes the module out again and the server stays unchanged.") }
        $recorded = Get-Content -LiteralPath $Paths.Revisions -ErrorAction SilentlyContinue | Where-Object { $_ -like 'core|*' } | Select-Object -First 1
        if ($recorded -and $s.Revision -and ($recorded.Split('|')[3] -ne $s.Revision)) {
            $s.Warnings.Add('Dependencies\revisions.txt names a different core revision than the source checkout; AFK Realm builds the checkout as it is.')
        }
        $ignored = Invoke-Git $git @('-C', $Paths.Source, 'check-ignore', '-q', '--no-index', "modules/$script:ModuleName/src/x.cpp")
        $s.ModulesIgnored = ($ignored.Code -eq 0)
        if (-not $s.ModulesIgnored) { $s.Warnings.Add('The core .gitignore does not ignore modules/*; rely on AFK Realm''s own exclusion only.') }
        $dirty = Invoke-Git $git @('-C', $Paths.Source, 'status', '--porcelain', '--untracked-files=no')
        if ($dirty.Text) { $s.Warnings.Add('The core source has local changes to tracked files (AFK Realm module patches reset them before each build).') }
    }

    foreach ($marker in $script:ApiMarkers) {
        $file = Join-Path $Paths.Source $marker.File
        if (-not (Test-Path -LiteralPath $file) -or -not ([IO.File]::ReadAllText($file).Contains($marker.Text))) {
            $s.Problems.Add("Incompatible core: '$($marker.Text)' not found in $($marker.File).")
        }
    }

    $conflicts = @()
    $scan = @((Join-Path $Paths.Source 'src\server\scripts'), $Paths.Modules)
    foreach ($dir in $scan) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.cpp' -ErrorAction SilentlyContinue) {
            if ($f.FullName.StartsWith($Paths.ModuleFolder, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $text = [IO.File]::ReadAllText($f.FullName)
            if ($text -notmatch '"gobject') { continue }
            if ($text -match '\{\s*"(gobject\s+)?(pitch|roll|save)"\s*,') { $conflicts += $f.FullName }
        }
    }
    $s.Conflicts = $conflicts
    foreach ($c in $conflicts) { $s.Problems.Add("Another command already uses .gobject pitch/roll/save: $c") }

    $s.FolderPresent = Test-Path -LiteralPath $Paths.ModuleFolder
    $s.ManagedLine = Get-ManagedModuleLine $Paths
    if ($s.FolderPresent -or $s.ManagedLine) { $s.Problems.Add("$script:ModuleName is already installed (folder or AFK Realm module list). Run Uninstall-GObjectPlacement.ps1 first.") }

    $s.StagedPresent = Test-Path -LiteralPath $Paths.StagedRepo
    if ($s.StagedPresent -and $git) {
        $staged = Invoke-Git $git @('--git-dir', $Paths.StagedRepo, 'rev-parse', 'refs/heads/main')
        $s.StagedCommit = if ($staged.Code -eq 0) { $staged.Text } else { '' }
    }

    $cache = Join-Path $Paths.Build 'CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $cache)) { $s.Problems.Add('The server was never built here (no Dependencies\Build\CMakeCache.txt). Install it with AFK Realm first.') }
    else {
        $instance = Select-String -LiteralPath $cache -Pattern '^CMAKE_GENERATOR_INSTANCE[^=]*=([^,]+)' | Select-Object -First 1
        if ($instance) {
            $vs = $instance.Matches[0].Groups[1].Value.Trim()
            if (Test-Path -LiteralPath $vs) { $s.Facts.Add("C++ build tools: $vs") } else { $s.Warnings.Add("The build tools recorded by the last build ($vs) are missing; AFK Realm will look for or install them.") }
        }
        $modules = Select-String -LiteralPath $cache -Pattern '^MODULES:STRING=(\w+)' | Select-Object -First 1
        if ($modules -and $modules.Matches[0].Groups[1].Value -ne 'static') { $s.Problems.Add('Modules are not built statically (MODULES is not static).') }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Paths.Server 'worldserver.exe'))) { $s.Problems.Add('No Server\worldserver.exe; finish the AFK Realm installation first.') }

    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Paths.Root))
    $s.FreeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    if ($s.FreeGB -lt 5) { $s.Warnings.Add("Only $($s.FreeGB) GB free on $($drive.Name); the AFK Realm backup and build need several GB.") }

    $s.Running = @(Get-ServerProcesses $Paths)
    $s.DbPort = Get-DatabasePort $Paths
    $s.DbUp = Test-TcpPort $s.DbPort
    $s.Snapshots = Get-SnapshotInfo $Paths
    return $s
}

# Read-only database checks (only when the database already runs; never started here).
function Test-DatabaseState([hashtable]$Paths, [bool]$ExpectInstalled) {
    $r = [ordered]@{ Checked = $false; Problems = @(); Notes = @(); Tables = @() }
    if (-not (Test-TcpPort (Get-DatabasePort $Paths))) { $r.Notes += 'Database not running; checks skipped (AFK Realm checks when it runs).'; return $r }
    if (-not (Test-Path -LiteralPath $Paths.Cnf)) { $r.Notes += 'DB\launcher.cnf not found; database checks skipped.'; return $r }
    try {
        $schemas = @(Invoke-LauncherSql $Paths "SELECT schema_name FROM information_schema.schemata WHERE schema_name IN ('acore_world','acore_characters') ORDER BY schema_name;")
        if (($schemas -join ',') -ne 'acore_characters,acore_world') { $r.Problems += "Expected databases acore_world and acore_characters; found: $($schemas -join ', ')" }
        $cols = Get-LauncherSqlValue $Paths "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'acore_world' AND table_name = 'gameobject' AND column_name IN ('guid','id','map','rotation0','rotation1','rotation2','rotation3','ScriptName');"
        if ($cols -ne '8') { $r.Problems += 'acore_world.gameobject does not have the expected columns.' }
        $cmd = Get-LauncherSqlValue $Paths "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'acore_world' AND table_name = 'command' AND column_name IN ('name','security','help');"
        if ($cmd -ne '3') { $r.Problems += 'acore_world.command does not have the expected columns.' }
        $r.Tables = @(Invoke-LauncherSql $Paths ("SELECT table_name FROM information_schema.tables WHERE table_schema = 'acore_characters' AND table_name IN ('" + ($script:PlacementTables -join "','") + "') ORDER BY table_name;"))
        $rows = Get-LauncherSqlValue $Paths "SELECT COUNT(*) FROM acore_world.command WHERE name IN ('gobject pitch','gobject roll','gobject save');"
        if (-not $ExpectInstalled) {
            if ($r.Tables.Count -gt 0) { $r.Notes += "Placement tables from an earlier install exist ($($r.Tables -join ', ')); they are kept as they are." }
            if ($rows -ne '0') { $r.Notes += 'Help rows for .gobject pitch/roll/save already exist; the module SQL replaces exactly these three rows.' }
        }
        $r.Checked = $true
    } catch { $r.Problems += "Database check failed: $($_.Exception.Message)" }
    return $r
}

function Get-EngineCommand([hashtable]$Paths, [string]$Arguments) {
    return ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallRoot "{1}" -Mode Modules {2}' -f $Paths.Engine, $Paths.Root, $Arguments)
}

# AFK Realm's output goes straight to the console (it asks for the database password itself).
function Invoke-Engine([hashtable]$Paths, [string[]]$ModeArguments) {
    $engine = $Paths.Engine
    $extra = @()
    # Tests: run FakeEngine.ps1 next to the engine this script resolved (the real engine's own functions, see
    # tests\packaging), so the test proves which engine would have run.
    if ($script:TestMode -and $env:GP_TEST_ENGINE -eq 'sibling') { $engine = Join-Path (Split-Path $Paths.Engine -Parent) 'FakeEngine.ps1'; $extra = @('-DatabasePort', [string](Get-DatabasePort $Paths)) }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-InstallRoot', $Paths.Root) + $extra + @('-Mode', 'Modules') + $ModeArguments
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe @arguments | Out-Host
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
}
