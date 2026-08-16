$ErrorActionPreference = 'Stop'

$projectDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectDirectory

$envPath = Join-Path $projectDirectory '.env'
if (-not (Test-Path -LiteralPath $envPath)) {
    Copy-Item -LiteralPath (Join-Path $projectDirectory '.env.example') -Destination $envPath
}

function Import-DotEnv {
    param([Parameter(Mandatory)][string]$Path)

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

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return -join ($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        } finally {
            $sha256.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Set-DotEnvValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        [void]$lines.Add($line)
    }

    $updated = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^\s*$([regex]::Escape($Name))\s*=") {
            $lines[$index] = "$Name=$Value"
            $updated = $true
            break
        }
    }
    if (-not $updated) { [void]$lines.Add("$Name=$Value") }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function New-RandomHex {
    param([int]$ByteCount = 32)

    $bytes = New-Object byte[] $ByteCount
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Ensure-LocalSecret {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $value -or $value.StartsWith('change-me-', [StringComparison]::OrdinalIgnoreCase)) {
        $value = New-RandomHex
        Set-DotEnvValue -Path $envPath -Name $Name -Value $value
        [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
        Write-Host "Generated local secret: $Name"
    } elseif ($value.Length -lt 32) {
        throw "$Name must contain at least 32 characters."
    }
}

function Get-IntegerEnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Default,
        [int]$Minimum = 1,
        [int]$Maximum = [int]::MaxValue
    )

    $rawValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $rawValue) { return $Default }

    $parsedValue = 0
    if (-not [int]::TryParse($rawValue, [ref]$parsedValue) -or $parsedValue -lt $Minimum -or $parsedValue -gt $Maximum) {
        throw "$Name must be an integer from $Minimum to $Maximum, got: $rawValue"
    }
    return $parsedValue
}

function Assert-BooleanEnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = 'true'
    )

    $rawValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $rawValue) { $rawValue = $Default }
    $normalizedValue = $rawValue.Trim().ToLowerInvariant()
    if ($normalizedValue -notin @('true', 'false')) {
        throw "$Name must be true or false, got: $rawValue"
    }
}

Import-DotEnv -Path $envPath
Ensure-LocalSecret -Name 'WEBUI_SECRET_KEY'
Ensure-LocalSecret -Name 'OPEN_TERMINAL_API_KEY'

$webuiPort = Get-IntegerEnvironmentValue -Name 'WEBUI_PORT' -Default 3000 -Maximum 65535
[void](Get-IntegerEnvironmentValue -Name 'LLM_SERVER_PORT' -Default 8080 -Maximum 65535)
$contextSize = Get-IntegerEnvironmentValue -Name 'MODEL_CONTEXT_SIZE' -Default 65536 -Minimum 1024
[void](Get-IntegerEnvironmentValue -Name 'MODEL_PARALLEL' -Default 1)
[void](Get-IntegerEnvironmentValue -Name 'MODEL_IMAGE_MIN_TOKENS' -Default 1024)
[void](Get-IntegerEnvironmentValue -Name 'MODEL_SPECULATIVE_TOKENS' -Default 2 -Minimum 0)
$compactionThreshold = Get-IntegerEnvironmentValue -Name 'CONTEXT_COMPACTION_TOKEN_THRESHOLD' -Default 40000
$compactionCap = Get-IntegerEnvironmentValue -Name 'CONTEXT_COMPACTION_TOKEN_CAP' -Default 40000
[void](Get-IntegerEnvironmentValue -Name 'CONTEXT_COMPACTION_RETENTION_PERCENTAGE' -Default 25 -Minimum 10 -Maximum 50)

foreach ($booleanVariable in @(
    'WEBUI_AUTH',
    'CONTEXT_COMPACTION_ENABLED',
    'COMPUTER_USE_DESTRUCTIVE_REQUIRES_APPROVAL'
)) {
    Assert-BooleanEnvironmentValue -Name $booleanVariable
}

if ($compactionThreshold -ge $contextSize) {
    throw 'CONTEXT_COMPACTION_TOKEN_THRESHOLD must be smaller than MODEL_CONTEXT_SIZE.'
}
if ($compactionCap -gt $compactionThreshold) {
    throw 'CONTEXT_COMPACTION_TOKEN_CAP must not exceed CONTEXT_COMPACTION_TOKEN_THRESHOLD.'
}

$gpuLayers = [Environment]::GetEnvironmentVariable('MODEL_GPU_LAYERS', 'Process')
if ($gpuLayers -and $gpuLayers -notmatch '^(auto|all|\d+)$') {
    throw "MODEL_GPU_LAYERS must be auto, all, or a non-negative integer, got: $gpuLayers"
}

$modelGgufFile = [Environment]::GetEnvironmentVariable('MODEL_GGUF_FILE', 'Process')
$modelGgufUrl = [Environment]::GetEnvironmentVariable('MODEL_GGUF_URL', 'Process')
$modelGgufSha256 = [Environment]::GetEnvironmentVariable('MODEL_GGUF_SHA256', 'Process')
$modelMmprojFile = [Environment]::GetEnvironmentVariable('MODEL_MMPROJ_FILE', 'Process')
$modelMmprojUrl = [Environment]::GetEnvironmentVariable('MODEL_MMPROJ_URL', 'Process')
$modelMmprojSha256 = [Environment]::GetEnvironmentVariable('MODEL_MMPROJ_SHA256', 'Process')

foreach ($requiredVariable in @(
    'MODEL_API_ID',
    'MODEL_DISPLAY_NAME',
    'MODEL_GGUF_FILE',
    'MODEL_GGUF_URL',
    'MODEL_GGUF_SHA256',
    'MODEL_MMPROJ_FILE',
    'MODEL_MMPROJ_URL',
    'MODEL_MMPROJ_SHA256'
)) {
    if (-not [Environment]::GetEnvironmentVariable($requiredVariable, 'Process')) {
        throw "$requiredVariable must be set in .env."
    }
}

$modelCache = Join-Path $projectDirectory '.model-cache'

function Ensure-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )

    New-Item -ItemType Directory -Force -Path $modelCache | Out-Null
    $downloadPath = Join-Path $modelCache $FileName
    $partialPath = "$downloadPath.partial"

    if (Test-Path -LiteralPath $downloadPath) {
        Write-Host "Verifying cached file: $FileName"
        $existingHash = Get-FileSha256 -Path $downloadPath
        if ($existingHash.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "Using verified cached file: $FileName"
            return
        }

        Write-Warning "Removing invalid cached file: $FileName"
        Remove-Item -LiteralPath $downloadPath -Force
    }

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'curl.exe is required to download model files.'
    }

    if (Test-Path -LiteralPath $partialPath) {
        Write-Host "Checking existing partial download: $FileName"
        $partialHash = Get-FileSha256 -Path $partialPath
        if ($partialHash.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            Move-Item -LiteralPath $partialPath -Destination $downloadPath -Force
            return
        }
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($attempt -eq 2 -and (Test-Path -LiteralPath $partialPath)) {
            Remove-Item -LiteralPath $partialPath -Force
            Write-Warning "Retrying $FileName from the beginning after a checksum mismatch."
        }

        Write-Host "Downloading (resumable): $FileName"
        curl.exe -L --fail --retry 8 --retry-delay 3 --retry-all-errors --continue-at - --output $partialPath $Url
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to download $FileName. The partial file was kept for the next start."
        }

        Write-Host "Verifying SHA-256: $FileName"
        $actualHash = Get-FileSha256 -Path $partialPath
        if ($actualHash.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            Move-Item -LiteralPath $partialPath -Destination $downloadPath -Force
            return
        }
    }

    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
    throw "SHA-256 mismatch for $FileName after a clean retry. Expected $ExpectedSha256."
}

$mcpHostStarted = $false

try {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop is not running.' }

    Ensure-VerifiedDownload -FileName $modelGgufFile -Url $modelGgufUrl -ExpectedSha256 $modelGgufSha256
    Ensure-VerifiedDownload -FileName $modelMmprojFile -Url $modelMmprojUrl -ExpectedSha256 $modelMmprojSha256

    docker compose config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Compose configuration is invalid.' }

    Write-Host 'Starting host-side Chrome and Windows MCP servers...'
    & (Join-Path $projectDirectory 'scripts\Start-McpHost.ps1')
    $mcpHostStarted = $true

    Write-Host 'Starting the CUDA vision model, Open WebUI and Open Terminal...'
    docker compose up -d --wait --wait-timeout 600
    if ($LASTEXITCODE -ne 0) { throw 'Failed to start the Compose project.' }

    docker compose ps
    Write-Host "Open WebUI: http://localhost:$webuiPort"
    Write-Host 'Open Terminal workspace: configured by PROJECTS_DIR in .env (default: .\projects)'
    Write-Host 'Vision: enabled through the mounted MODEL_MMPROJ_FILE.'
    Write-Host 'MCP tools: enable Chrome and/or Computer from the Tools button in each chat.'
} catch {
    if ($mcpHostStarted) {
        & (Join-Path $projectDirectory 'scripts\Stop-McpHost.ps1')
    }
    throw
}
