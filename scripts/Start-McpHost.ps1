[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectDirectory = Split-Path -Parent $PSScriptRoot
$mcpDirectory = Join-Path $projectDirectory 'mcp-host'
$runtimeDirectory = Join-Path $projectDirectory '.runtime'
$logDirectory = Join-Path $projectDirectory 'logs'
$statePath = Join-Path $runtimeDirectory 'mcp-host-processes.json'

function Import-DotEnv {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }

        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function Get-PortValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Default
    )

    $rawValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $rawValue) { return $Default }

    $parsedValue = 0
    if (-not [int]::TryParse($rawValue, [ref]$parsedValue) -or $parsedValue -lt 1 -or $parsedValue -gt 65535) {
        throw "$Name must be an integer between 1 and 65535, got: $rawValue"
    }

    return $parsedValue
}

function Test-ListeningPort {
    param([Parameter(Mandatory)][int]$Port)

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $asyncResult = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne(1000)) {
            $client.Close()
            return $false
        }
        $client.EndConnect($asyncResult)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

function Wait-ListeningPort {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-ListeningPort -Port $Port) { return $true }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    return $false
}

function Start-LoggedProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $stdoutPath = Join-Path $logDirectory "$Name.log"
    $stderrPath = Join-Path $logDirectory "$Name.error.log"

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $mcpDirectory `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru

    return [pscustomobject]@{
        name = $Name
        processId = $process.Id
        executable = $FilePath
        startedAt = [DateTimeOffset]::Now.ToString('o')
    }
}

function Get-ChromeExecutable {
    $configuredExecutable = [Environment]::GetEnvironmentVariable('CHROME_EXECUTABLE', 'Process')
    if ($configuredExecutable) {
        $resolvedExecutable = [System.IO.Path]::GetFullPath($configuredExecutable)
        if (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) {
            return $resolvedExecutable
        }
        throw "CHROME_EXECUTABLE does not point to a file: $resolvedExecutable"
    }

    $candidates = @(
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    throw 'Google Chrome was not found. Install Chrome Stable before starting Agent Chrome.'
}

function Start-AgentChrome {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$ProfileDirectory,
        [Parameter(Mandatory)][int]$DebugPort
    )

    if (Test-ListeningPort -Port $DebugPort) {
        $existing = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
            Where-Object { $_.CommandLine -like "*--user-data-dir=$ProfileDirectory*" } |
            Select-Object -First 1
        if (-not $existing) {
            throw "Port $DebugPort is already occupied by another process. Set AGENT_CHROME_DEBUG_PORT to a free local port."
        }

        return [pscustomobject]@{
            name = 'agent-chrome'
            processId = [int]$existing.ProcessId
            executable = $Executable
            startedAt = [DateTimeOffset]::Now.ToString('o')
        }
    }

    New-Item -ItemType Directory -Force -Path $ProfileDirectory | Out-Null
    $process = Start-Process `
        -FilePath $Executable `
        -ArgumentList @(
            "--remote-debugging-port=$DebugPort",
            '--remote-debugging-address=127.0.0.1',
            "--user-data-dir=$ProfileDirectory",
            '--no-first-run',
            '--no-default-browser-check',
            '--new-window',
            'about:blank'
        ) `
        -WorkingDirectory $projectDirectory `
        -PassThru

    if (-not (Wait-ListeningPort -Port $DebugPort -TimeoutSeconds 30)) {
        throw "Agent Chrome did not start its DevTools endpoint on port $DebugPort."
    }

    return [pscustomobject]@{
        name = 'agent-chrome'
        processId = $process.Id
        executable = $Executable
        startedAt = [DateTimeOffset]::Now.ToString('o')
    }
}

Import-DotEnv -Path (Join-Path $projectDirectory '.env')

$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
$npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $nodeCommand -or -not $npmCommand) {
    throw 'Node.js LTS with node.exe and npm.cmd is required.'
}

New-Item -ItemType Directory -Force -Path $runtimeDirectory, $logDirectory | Out-Null

& (Join-Path $PSScriptRoot 'Stop-McpHost.ps1')

Write-Host 'Installing pinned host MCP dependencies...'
Push-Location -LiteralPath $mcpDirectory
try {
    # npm 11 `ci` currently rejects lock files containing platform-specific
    # optional native packages. Exact dependency versions and package-lock.json
    # still make regular install deterministic for this Windows host.
    & $npmCommand.Source install --omit=dev --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'npm dependency installation failed.' }
} finally {
    Pop-Location
}

$computerPort = Get-PortValue -Name 'COMPUTER_USE_MCP_PORT' -Default 8932
$chromeDevtoolsPort = Get-PortValue -Name 'CHROME_DEVTOOLS_MCP_PORT' -Default 8933
$agentChromeDebugPort = Get-PortValue -Name 'AGENT_CHROME_DEBUG_PORT' -Default 9333
$webuiPort = Get-PortValue -Name 'WEBUI_PORT' -Default 3000

$duplicateHostPorts = @(
    $computerPort,
    $chromeDevtoolsPort,
    $agentChromeDebugPort,
    $webuiPort
) | Group-Object | Where-Object Count -gt 1
if ($duplicateHostPorts) {
    $duplicates = ($duplicateHostPorts | ForEach-Object Name) -join ', '
    throw "Host ports must be unique. Duplicate value(s): $duplicates"
}

[Environment]::SetEnvironmentVariable('AGENT_CHROME_DEBUG_PORT', "$agentChromeDebugPort", 'Process')
$agentChromeProfile = Join-Path $runtimeDirectory 'agent-chrome-profile'

$configuredProjectsDirectory = [Environment]::GetEnvironmentVariable('PROJECTS_DIR', 'Process')
if (-not $configuredProjectsDirectory) { $configuredProjectsDirectory = 'projects' }
if ([System.IO.Path]::IsPathRooted($configuredProjectsDirectory)) {
    $projectsDirectory = [System.IO.Path]::GetFullPath($configuredProjectsDirectory)
} else {
    $projectsDirectory = [System.IO.Path]::GetFullPath((Join-Path $projectDirectory $configuredProjectsDirectory))
}
New-Item -ItemType Directory -Force -Path $projectsDirectory | Out-Null

$workspaceRoot = [Environment]::GetEnvironmentVariable('COMPUTER_USE_FS_ROOTS', 'Process')
if (-not $workspaceRoot) {
    $workspaceRoot = $projectsDirectory
    [Environment]::SetEnvironmentVariable('COMPUTER_USE_FS_ROOTS', $workspaceRoot, 'Process')
}

if (-not [Environment]::GetEnvironmentVariable('COMPUTER_USE_DESTRUCTIVE_REQUIRES_APPROVAL', 'Process')) {
    [Environment]::SetEnvironmentVariable('COMPUTER_USE_DESTRUCTIVE_REQUIRES_APPROVAL', 'true', 'Process')
}

if (-not [Environment]::GetEnvironmentVariable('COMPUTER_USE_AUDIT_LOG', 'Process')) {
    [Environment]::SetEnvironmentVariable(
        'COMPUTER_USE_AUDIT_LOG',
        (Join-Path $logDirectory 'computer-use-audit.jsonl'),
        'Process'
    )
}

$supergatewayScript = Join-Path $mcpDirectory 'run-supergateway.mjs'
$computerLauncher = Join-Path $mcpDirectory 'run-computer-server.cmd'
$chromeDevtoolsLauncher = Join-Path $mcpDirectory 'run-chrome-devtools-server.cmd'
$chromeExecutable = Get-ChromeExecutable

$processes = @()
try {
    $processes += Start-AgentChrome `
        -Executable $chromeExecutable `
        -ProfileDirectory $agentChromeProfile `
        -DebugPort $agentChromeDebugPort

    Write-Host "Agent Chrome: http://127.0.0.1:$agentChromeDebugPort (profile: $agentChromeProfile)"

    $processes += Start-LoggedProcess `
        -Name 'computer-use-mcp' `
        -FilePath $nodeCommand.Source `
        -Arguments @(
            $supergatewayScript,
            '--stdio', $computerLauncher,
            '--outputTransport', 'streamableHttp',
            '--stateful',
            '--sessionTimeout', '600000',
            '--port', "$computerPort"
        )

    $processes += Start-LoggedProcess `
        -Name 'chrome-devtools-mcp' `
        -FilePath $nodeCommand.Source `
        -Arguments @(
            $supergatewayScript,
            '--stdio', $chromeDevtoolsLauncher,
            '--outputTransport', 'streamableHttp',
            '--stateful',
            '--sessionTimeout', '600000',
            '--port', "$chromeDevtoolsPort"
        )

    $processes | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

    foreach ($entry in @(
        @{ Name = 'Computer Use MCP'; Port = $computerPort },
        @{ Name = 'Chrome DevTools MCP'; Port = $chromeDevtoolsPort }
    )) {
        if (-not (Wait-ListeningPort -Port $entry.Port)) {
            throw "$($entry.Name) did not start on port $($entry.Port). See logs in $logDirectory."
        }
        Write-Host "$($entry.Name): http://127.0.0.1:$($entry.Port)/mcp"
    }
} catch {
    if ($processes.Count -gt 0) {
        $processes | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        & (Join-Path $PSScriptRoot 'Stop-McpHost.ps1')
    }
    throw
}

Write-Host "Computer Use filesystem root: $workspaceRoot"
Write-Host "Projects directory: $projectsDirectory"
