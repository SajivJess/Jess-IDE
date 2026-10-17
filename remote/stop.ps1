$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($name in @('tunnel','portal')) {
    $file = Join-Path $repo ".local\$name.pid"
    if (Test-Path $file) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$([int](Get-Content $file))"
        $matches = if ($name -eq 'tunnel') { $proc.ExecutablePath -eq 'E:\tools\cloudflared.exe' } else { $proc.ExecutablePath -eq 'E:\tools\node-v24.22.0-win-x64\node.exe' -and $proc.CommandLine -like '*remote/server.mjs*' }
        if ($matches) { Stop-Process -Id $proc.ProcessId }
        Remove-Item -LiteralPath $file
    }
}
Write-Output 'Public access stopped. Local backend and database remain running.'
