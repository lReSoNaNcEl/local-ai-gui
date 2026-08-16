$ErrorActionPreference = 'Stop'

$projectDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectDirectory

docker compose down
if ($LASTEXITCODE -ne 0) { throw 'Failed to stop the Compose project.' }

& (Join-Path $projectDirectory 'scripts\Stop-McpHost.ps1')
