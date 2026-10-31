# Appended to the REAL AFK Realm engine's functions (everything before its "$exitCode = 0" main block)
# to make tests\packaging\FakeEngine.ps1. It runs the engine's own module code -
# Edit-ModuleFolders, Undo-ModuleFolders, Complete-ModuleChange (registration and undo), Install-ModuleJournal,
# Repair-ModuleJournal, Invoke-ModuleSql, Save-ModuleList - in the order of a real "-Mode Modules" run,
# and skips only the snapshot and the compile. Test databases only (root without password).
$exitCode = 0
try {
    Write-Log "===== TEST ENGINE (snapshot and compile skipped) - $InstallRoot ====="
    if ($Mode -ne 'Modules') { throw 'The test engine only supports -Mode Modules.' }
    Read-Revisions
    Assert-ServerStopped
    $git = Resolve-Git
    $moduleAdd = @($AddModules.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $moduleRemove = @($RemoveModules.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($moduleAdd.Count -eq 0 -and $moduleRemove.Count -eq 0) { throw (Tr 'No module was chosen.') }
    $password = ''
    $moduleState = Edit-ModuleFolders $git $moduleAdd $moduleRemove
    Write-Log 'TEST ENGINE: backup snapshot and compile skipped'
    if ($env:GP_TEST_BUILD_FAIL -eq '1') {
        Undo-ModuleFolders $moduleState
        throw 'TEST ENGINE: simulated compile failure; the module was taken out again'
    }
    Complete-ModuleChange $password $moduleState
    $root = New-ClientOptions 'root' $password
    try {
        Install-ModuleJournal $root
        $managed = @(Get-ManagedModules $root | Where-Object { Test-Path $_.Folder })
        Restore-ModuleLedgers $root
        Repair-ModuleJournal $root
        foreach ($m in $managed) { Invoke-ModuleSql $root $m }
        Save-ModuleList $root
    } finally { Remove-Item $root -Force -ErrorAction SilentlyContinue }
    foreach ($r in $moduleState.Removed) { if ($r.Aside) { Remove-Item $r.Aside -Recurse -Force -ErrorAction SilentlyContinue } }
    Send-Event 'DONE' 'ok'
} catch {
    $exitCode = 1
    Write-Log ('ERROR: ' + $_.Exception.Message) Red
    Send-Event 'FAIL' $_.Exception.Message
}
exit $exitCode
