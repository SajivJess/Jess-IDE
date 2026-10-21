$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $repo.StartsWith('E:\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Run this laptop workflow from E: only.' }
$env:Path = 'E:\tools\node-v24.22.0-win-x64;E:\tools\git\cmd;' + $env:Path
$env:TEMP = 'E:\local-data\tmp'
$env:TMP = $env:TEMP
$env:npm_config_cache = 'E:\local-data\npm-cache'
$env:PLAYWRIGHT_BROWSERS_PATH = 'E:\tools\playwright-browsers'
$env:REQUIRE_DATABASE_TESTS = '1'
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
$pgCtl = 'E:\tools\postgresql-17\pgsql\bin\pg_ctl.exe'
$data = 'E:\local-data\jess\pgdata'
$startedDatabase = $false
Push-Location $repo
try {
    & $pgCtl status -D $data *> $null
    if ($LASTEXITCODE -ne 0) {
        & $pgCtl start -D $data -l 'E:\local-data\jess\postgres.log' -w
        if ($LASTEXITCODE -ne 0) { throw 'Test database startup failed' }
        $startedDatabase = $true
    }
    & npm.cmd run check
    if ($LASTEXITCODE -ne 0) { throw 'Backend/frontend checks failed' }
    & npm.cmd run test:browser
    if ($LASTEXITCODE -ne 0) { throw 'Browser checks failed; inspect .local/browser-results' }
} finally {
    if ($startedDatabase) { & $pgCtl stop -D $data -m fast -w }
    Pop-Location
}
