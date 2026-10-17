param([Parameter(Mandatory=$true)][string]$PromptFile)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$env:TEMP = 'E:\local-data\tmp'
$env:TMP = $env:TEMP
$env:AGENT_PROVIDER = 'antigravity'
$env:ANTIGRAVITY_CLI_PATH = 'E:\tools\antigravity-cli\agy.exe'
$env:AGENT_GIT_PATH = 'E:\tools\git\cmd\git.exe'
$env:AGENT_NODE_PATH = 'E:\tools\node-v24.22.0-win-x64\node.exe'
$env:AGENT_NPM_CLI_PATH = 'E:\tools\node-v24.22.0-win-x64\node_modules\npm\bin\npm-cli.js'
$env:AGENT_SOURCE_REPO = $repo
$env:AGENT_WORKSPACE_ROOT = 'E:\local-data\jess\workspaces'
$env:AGENT_PROFILE = 'E:\local-data\antigravity-home'
Push-Location $repo
try {
    & $env:AGENT_NODE_PATH --env-file=.env dist/tools/local-task.js $PromptFile
    if ($LASTEXITCODE -ne 0) { throw 'Task failed; inspect authentication and local CLI logs' }
} finally { Pop-Location }
