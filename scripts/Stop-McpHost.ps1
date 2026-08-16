[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectDirectory = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $projectDirectory '.runtime\mcp-host-processes.json'

function Stop-VerifiedProcessTree {
    param([Parameter(Mandatory)][int]$RootProcessId)

    $allProcesses = @(Get-CimInstance Win32_Process)
    $root = $allProcesses | Where-Object { $_.ProcessId -eq $RootProcessId } | Select-Object -First 1
    if (-not $root) { return }

    if ([string]$root.CommandLine -notlike "*$projectDirectory*") {
        Write-Warning "Not stopping PID $RootProcessId because it no longer belongs to this project."
        return
    }

    $descendants = [System.Collections.Generic.List[int]]::new()
    $pending = [System.Collections.Generic.Queue[int]]::new()
    $pending.Enqueue($RootProcessId)

    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($child in $allProcesses | Where-Object { $_.ParentProcessId -eq $parentId }) {
            $childId = [int]$child.ProcessId
            $descendants.Add($childId)
            $pending.Enqueue($childId)
        }
    }

    $descendantIds = @($descendants)
    [array]::Reverse($descendantIds)
    foreach ($childId in $descendantIds) {
        Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $RootProcessId -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $statePath)) { return }

try {
    $entries = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $entries) {
        $processId = [int]$entry.processId
        Stop-VerifiedProcessTree -RootProcessId $processId
        Write-Host "Stopped $($entry.name) (PID $processId)."
    }
} finally {
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
}
