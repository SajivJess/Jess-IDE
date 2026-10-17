param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CliArgs)
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = 'E:\local-data\antigravity-home'
$env:APPDATA = 'E:\local-data\antigravity-home\appdata'
$env:LOCALAPPDATA = 'E:\local-data\antigravity-home\localappdata'
$env:TEMP = 'E:\local-data\antigravity-home\tmp'
$env:TMP = $env:TEMP
$env:npm_config_cache = 'E:\local-data\npm-cache'
$env:npm_config_prefix = 'E:\tools\npm-global'
$env:Path = 'E:\tools\node-v24.22.0-win-x64;E:\tools\git\cmd;' + $env:Path
New-Item -ItemType Directory -Force $env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:TEMP | Out-Null
& E:\tools\antigravity-cli\agy.exe @CliArgs
exit $LASTEXITCODE
