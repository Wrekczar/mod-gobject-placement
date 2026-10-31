#requires -Version 5.1
<#
.SYNOPSIS
    Builds the portable installation ZIP from a committed revision of this repository.
.DESCRIPTION
    Everything in the ZIP comes from the commit (git archive + git bundle), never from
    uncommitted files, so the package matches COMMIT.txt exactly. Refuses to overwrite a ZIP.
#>
[CmdletBinding()]
param(
    [string]$OutDir = [Environment]::GetFolderPath('Desktop'),
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\GObjectPlacement.Common.ps1')
$repo = Split-Path $PSScriptRoot -Parent
$git = (Get-Command git.exe).Source

function Git([string[]]$Arguments) {
    $out = & $git -C $repo -c core.longpaths=true @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("git " + ($Arguments -join ' ') + ": " + (($out | ForEach-Object { "$_" }) -join ' ')) }
    return (($out | ForEach-Object { "$_" }) -join "`n").Trim()
}

if (Git @('status', '--porcelain')) { throw 'The repository has uncommitted changes; commit them first so the package matches a commit.' }
$branch = Git @('rev-parse', '--abbrev-ref', 'HEAD')
if ($branch -ne 'main') { throw "Package from branch main (current: $branch)." }
$commit = Git @('rev-parse', 'HEAD')
$name = 'GObjectPlacement-{0}-{1}' -f $script:PackageVersion, $commit.Substring(0, 8)
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path -LiteralPath $zip) { throw "$zip already exists; not overwriting." }

if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ("gp-package-" + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
$stage = Join-Path $WorkDir $name
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    $source = Join-Path $stage 'payload\mod-gobject-placement'
    New-Item -ItemType Directory -Force -Path $source | Out-Null
    $tar = Join-Path $WorkDir 'source.zip'
    Git @('archive', '--format=zip', "--output=$tar", $commit) | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($tar, $source)
    Remove-Item -LiteralPath $tar

    Copy-Item -LiteralPath (Join-Path $source 'packaging\Install-GObjectPlacement.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $source 'packaging\Uninstall-GObjectPlacement.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $source 'packaging\lib') -Destination (Join-Path $stage 'lib') -Recurse
    foreach ($doc in Get-ChildItem -LiteralPath (Join-Path $source 'packaging\docs') -File) { Copy-Item -LiteralPath $doc.FullName -Destination $stage }
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'tools') | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'tools\export_placements.py') -Destination (Join-Path $stage 'tools')

    Git @('bundle', 'create', (Join-Path $stage "payload\$script:ModuleName.bundle"), 'HEAD', 'main') | Out-Null
    [IO.File]::WriteAllText((Join-Path $stage 'payload\COMMIT.txt'), "$commit`r`n")

    $sums = Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
    }
    [IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS.txt'), [string[]]$sums)

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host "Package: $zip"
    Write-Host "Commit:  $commit"
    return $zip
} finally {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
