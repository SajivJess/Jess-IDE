$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$local = Join-Path $repo '.local'
$env:TEMP = 'E:\local-data\tmp'
$env:TMP = $env:TEMP
$env:npm_config_cache = 'E:\local-data\npm-cache'
$env:USERPROFILE = 'E:\local-data\cloudflared-home'
New-Item -ItemType Directory -Force $local,$env:TEMP,$env:USERPROFILE | Out-Null
$node = 'E:\tools\node-v24.22.0-win-x64\node.exe'
$tunnel = 'E:\tools\cloudflared.exe'
if (!(Test-Path $node) -or !(Test-Path $tunnel)) { throw 'Install the E: drive tools described in docs/remote-access.md' }
$configPath = Join-Path $local 'remote-config.json'
if (Test-Path $configPath) { $config = Get-Content $configPath -Raw | ConvertFrom-Json }
else {
    $config = [pscustomobject]@{ password = ([guid]::NewGuid().ToString('N')); owner = ([guid]::NewGuid().ToString()); origin = '' }
}
$tunnelPid = Join-Path $local 'tunnel.pid'
$existing = $null
if (Test-Path $tunnelPid) { $existing = Get-Process -Id ([int](Get-Content $tunnelPid)) -ErrorAction SilentlyContinue }
if (!$existing -or $existing.Path -ne $tunnel) {
    $log = Join-Path $local ('tunnel-' + [guid]::NewGuid().ToString('N') + '.log')
    $proc = Start-Process $tunnel -ArgumentList @('tunnel','--no-autoupdate','--protocol','http2','--url','http://127.0.0.1:3001','--logfile',$log) -WorkingDirectory $repo -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $local 'tunnel.stdout.log') -RedirectStandardError (Join-Path $local 'tunnel.error.log')
    Set-Content $tunnelPid $proc.Id
    $found = ''
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Path $log) { $found = [regex]::Match((Get-Content $log -Raw),'https://[a-z0-9-]+\.trycloudflare.com').Value }
        if ($found) { break }
        if ($proc.HasExited) { throw 'Tunnel exited; inspect .local/tunnel.error.log' }
        Start-Sleep -Seconds 1
    }
    if (!$found) { throw 'Tunnel URL not ready; inspect .local tunnel logs' }
    $config.origin = $found
    $portalPid = Join-Path $local 'portal.pid'
    if (Test-Path $portalPid) {
        $old = Get-CimInstance Win32_Process -Filter "ProcessId=$([int](Get-Content $portalPid))"
        if ($old.ExecutablePath -eq $node -and $old.CommandLine -like '*remote/server.mjs*') { Stop-Process -Id $old.ProcessId }
    }
}
$config | ConvertTo-Json | Set-Content $configPath
$portalPid = Join-Path $local 'portal.pid'
$portal = $null
if (Test-Path $portalPid) { $portal = Get-Process -Id ([int](Get-Content $portalPid)) -ErrorAction SilentlyContinue }
if (!$portal -or $portal.Path -ne $node) {
    $portal = Start-Process $node -ArgumentList @('--env-file=.env','remote/server.mjs') -WorkingDirectory $repo -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $local 'portal.log') -RedirectStandardError (Join-Path $local 'portal.error.log')
    Set-Content $portalPid $portal.Id
}
Write-Output "Public link: $($config.origin)"
Write-Output "Password is stored locally in $configPath"
