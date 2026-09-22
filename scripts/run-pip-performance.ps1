[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Environment,

    [ValidateRange(0, 100)]
    [int]$WarmIterations = 5,

    [ValidateRange(0, 60000)]
    [int]$DelayMs = 250,

    [ValidateRange(1000, 900000)]
    [int]$RequestTimeoutMs = 180000,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot "..\results\performance")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceId = "wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3"
$performanceFolderId = "fld_20a4f3e6b9784d1c8ea10fbe6729a501"
$collectionFile = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\insomnia.wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3.yaml")).Path
$expectedRequestsPerRun = 6

$targets = @(
    [pscustomobject]@{ Name = "Local"; Id = "env_1aa0ac83930048d2ae39983fd194ff23"; BaseUrl = "http://127.0.0.1:8080/api/v1"; IsGateway = $false }
    [pscustomobject]@{ Name = "Dev - Gateway"; Id = "env_2fdc6a2c8e6148b5bcff1f65f04eabd6"; BaseUrl = "https://apiv2dev.worldbank.org/pip/v1"; IsGateway = $true }
    [pscustomobject]@{ Name = "Dev - VM1"; Id = "env_b631255845de4a989b6f4a9f8fcc0b91"; BaseUrl = "http://wzlxdpip01.worldbank.org/api/v1"; IsGateway = $false }
    [pscustomobject]@{ Name = "QA - Gateway"; Id = "env_308cc551c5734a96ada11d1fb8d4d3e3"; BaseUrl = "https://apiv2qa.worldbank.org/pip/v1"; IsGateway = $true }
    [pscustomobject]@{ Name = "QA - VM1"; Id = "env_c5b2808184034d7b8952b8209650e5e4"; BaseUrl = "http://wzlxqpip01.worldbank.org/api/v1"; IsGateway = $false }
    [pscustomobject]@{ Name = "QA - VM2"; Id = "env_8d2cf0336c2645f4b50264332d73d608"; BaseUrl = "http://wzlxqpip02.worldbank.org/api/v1"; IsGateway = $false }
    [pscustomobject]@{ Name = "Prod - Gateway"; Id = "env_2f404d334d4e45198c75ec339a192e39"; BaseUrl = "https://api.worldbank.org/pip/v1"; IsGateway = $true }
    [pscustomobject]@{ Name = "Prod - VM1"; Id = "env_f4c749f676be4e47aff9803eee5d1bb3"; BaseUrl = "http://wzlxppip01.worldbank.org/api/v1"; IsGateway = $false }
    [pscustomobject]@{ Name = "Prod - VM2"; Id = "env_5e40f167f49741538f2b81b7bccbcccb"; BaseUrl = "http://wzlxppip02.worldbank.org/api/v1"; IsGateway = $false }
    [pscustomobject]@{ Name = "Prod - VM3"; Id = "env_7475b41083f0406d92dae9d626575ba1"; BaseUrl = "http://wzlxppip03.worldbank.org/api/v1"; IsGateway = $false }
)

function Get-Target {
    param([string]$Value)

    $matches = @($targets | Where-Object { $_.Name -ceq $Value -or $_.Id -ceq $Value })
    if ($matches.Count -ne 1) {
        $validValues = $targets | ForEach-Object { "'$($_.Name)' or '$($_.Id)'" }
        throw "Unknown environment '$Value'. Valid existing name/ID pairs are: $($validValues -join ', ')."
    }

    return $matches[0]
}

function Test-GatewayTarget {
    param($Target)

    return $Target.Name -like "* - Gateway"
}

function Get-ArrayResponse {
    param($Value)

    if ($null -eq $Value) {
        throw "/versions returned no JSON data."
    }
    if ($Value -is [System.Array]) {
        return @($Value)
    }
    foreach ($propertyName in @("data", "results")) {
        $property = $Value.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $property.Value -is [System.Array]) {
            return @($property.Value)
        }
    }
    return @($Value)
}

function Get-RequiredString {
    param($Value, [string]$PropertyName)

    $property = $Value.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "/versions PROD row does not contain a non-empty '$PropertyName' value."
    }
    return ([string]$property.Value).Trim()
}

function Get-TargetVersionSnapshot {
    param([string]$BaseUrl)

    try {
        $versions = Get-ArrayResponse (Invoke-RestMethod -Method Get -Uri "$BaseUrl/versions" -Headers @{ Accept = "application/json" })
    }
    catch {
        throw "Version discovery failed at '$BaseUrl/versions': $($_.Exception.Message)"
    }

    if ($versions.Count -eq 0) {
        throw "/versions returned an empty list for '$BaseUrl'."
    }

    $prodVersions = @($versions | Where-Object { (Get-RequiredString $_ "identity") -eq "PROD" })
    if ($prodVersions.Count -eq 0) {
        throw "/versions returned no PROD rows for '$BaseUrl'."
    }

    $selected = foreach ($group in ($prodVersions | Group-Object { Get-RequiredString $_ "ppp_version" })) {
        $latest = $group.Group | Sort-Object -Property @{ Expression = { Get-RequiredString $_ "release_version" }; Descending = $true } | Select-Object -First 1
        "$(Get-RequiredString $latest 'ppp_version')|$(Get-RequiredString $latest 'release_version')|$(Get-RequiredString $latest 'version')"
    }

    return @($selected | Sort-Object)
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)

    if ($Values.Count -eq 0) {
        return $null
    }

    $sorted = @($Values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Ceiling($sorted.Count * $Percentile) - 1)
    return [double]$sorted[$index]
}

function Write-JsonFile {
    param([string]$Path, $Value)

    ConvertTo-Json -InputObject $Value -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-RecordValue {
    param($Record, [string[]]$Names)

    foreach ($name in $Names) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function Get-PerformanceEvents {
    param(
        [string]$ConsoleText,
        [string]$TargetName,
        [string]$Phase,
        [int]$Iteration,
        [string[]]$VersionSnapshot
    )

    $events = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($ConsoleText -split "`r?`n")) {
        $cleanLine = [regex]::Replace($line, "$([char]27)\[[0-?]*[ -/]*[@-~]", "")
        $match = [regex]::Match($cleanLine, "PIP_PERFORMANCE_RESULT\s*:?\s*(\{.*\})")
        if (-not $match.Success) {
            continue
        }

        try {
            $payload = $match.Groups[1].Value | ConvertFrom-Json
            $performanceProperty = $payload.PSObject.Properties["performance"]
            $record = if ($null -ne $performanceProperty) { $performanceProperty.Value } else { $payload }
            $endpoint = [string](Get-RecordValue $record @("endpoint", "scenario"))
            if ([string]::IsNullOrWhiteSpace($endpoint)) {
                throw "The record does not contain an endpoint or scenario."
            }

            $statusValue = Get-RecordValue $record @("status", "httpStatus", "http_status")
            $responseTimeValue = Get-RecordValue $record @("responseTime", "responseTimeMs", "response_time_ms")
            $reportedError = Get-RecordValue $record @("error", "failed")
            $status = if ($null -eq $statusValue) { $null } else { [int]$statusValue }
            $responseTime = if ($null -eq $responseTimeValue) { $null } else { [double]$responseTimeValue }
            $isError = ($null -eq $status -or $status -lt 200 -or $status -gt 299)
            if ($reportedError -is [bool]) {
                $isError = $isError -or $reportedError
            }
            elseif ($null -ne $reportedError -and -not [string]::IsNullOrWhiteSpace([string]$reportedError)) {
                $isError = $true
            }

            $recordTimestamp = [string](Get-RecordValue $record @("timestampUtc", "timestamp_utc", "timestamp"))
            if ([string]::IsNullOrWhiteSpace($recordTimestamp)) {
                $recordTimestamp = (Get-Date).ToUniversalTime().ToString("o")
            }

            $events.Add([pscustomobject]@{
                timestamp_utc = $recordTimestamp
                target = $TargetName
                endpoint = $endpoint
                format = [string](Get-RecordValue $record @("format"))
                phase = $Phase
                iteration = $Iteration
                http_status = $status
                error = $isError
                response_time_ms = $responseTime
                response_size_bytes = Get-RecordValue $record @("responseSize", "responseSizeBytes", "response_size_bytes")
                resolved_versions = @($VersionSnapshot)
                pipapi_cache = Get-RecordValue $record @("pipapiCache", "pipapi_cache")
                gateway_cache_signal = Get-RecordValue $record @("gatewayCacheSignal", "gateway_cache_signal")
            })
        }
        catch {
            Write-Warning "Could not parse one performance console record: $($_.Exception.Message)"
        }
    }

    return @($events)
}

function Invoke-PerformanceRun {
    param(
        $Target,
        [string]$Phase,
        [int]$Iteration,
        [string[]]$VersionSnapshot,
        [string]$Timestamp
    )

    $safeTargetName = ($Target.Name -replace "[^A-Za-z0-9]+", "-").Trim("-")
    $safePhase = ($Phase -replace "[^A-Za-z0-9]+", "-").Trim("-")
    $prefix = "performance-$safeTargetName-$safePhase-$Iteration-$Timestamp"
    $insoOutputPath = Join-Path $OutputDirectory "$prefix.json"
    $consolePath = Join-Path $OutputDirectory "$prefix.console.txt"
    $arguments = @(
        "--ci",
        "-w", $collectionFile,
        "run", "collection",
        "--item", $performanceFolderId,
        "--env", $Target.Id,
        "--delay-request", $DelayMs,
        "--requestTimeout", $RequestTimeoutMs,
        "--output", $insoOutputPath,
        "--acceptRisk",
        $workspaceId
    )

    Write-Host "Running $Phase iteration $Iteration on $($Target.Name)..."
    $consoleOutput = @()
    $exitCode = 1
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Native stderr must be captured as data on Windows PowerShell 5.1.
        $ErrorActionPreference = "Continue"
        $consoleOutput = @(& $insoCommand.Source @arguments 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    catch {
        $consoleOutput += "Inso invocation failed: $($_.Exception.Message)"
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $consoleText = $consoleOutput | Out-String
    $consoleText | Set-Content -LiteralPath $consolePath -Encoding UTF8
    $consoleOutput | ForEach-Object { Write-Host ([string]$_) }
    $events = @(Get-PerformanceEvents $consoleText $Target.Name $Phase $Iteration $VersionSnapshot)

    return [pscustomobject]@{
        target = $Target.Name
        environment_id = $Target.Id
        base_url = $Target.BaseUrl
        phase = $Phase
        iteration = $Iteration
        inso_output = $insoOutputPath
        console_output = $consolePath
        exit_code = $exitCode
        expected_request_records = $expectedRequestsPerRun
        captured_request_records = $events.Count
        capture_complete = ($events.Count -eq $expectedRequestsPerRun)
        events = $events
    }
}

if (Test-Path -LiteralPath $OutputDirectory -PathType Leaf) {
    throw "OutputDirectory '$OutputDirectory' is a file, not a directory."
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    try {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    catch {
        throw "Could not create OutputDirectory '$OutputDirectory': $($_.Exception.Message)"
    }
}
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$selectedTargets = @($Environment | ForEach-Object { Get-Target $_ })
if (@($selectedTargets | Group-Object Id | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
    throw "Each environment can be specified only once."
}

$insoCommand = Get-Command inso -ErrorAction SilentlyContinue
if ($null -eq $insoCommand) {
    throw "Inso CLI was not found. Install it with 'npm install --global insomnia-inso', then open a new PowerShell session."
}

$versionSnapshots = @{}
foreach ($target in $selectedTargets) {
    $versionSnapshots[$target.Id] = Get-TargetVersionSnapshot $target.BaseUrl
}
$referenceSnapshot = $versionSnapshots[$selectedTargets[0].Id]
$skewedTargets = @($selectedTargets | Where-Object {
    [bool](Compare-Object -ReferenceObject $referenceSnapshot -DifferenceObject $versionSnapshots[$_.Id])
})
if ($skewedTargets.Count -gt 0) {
    $details = $selectedTargets | ForEach-Object { "$($_.Name): $($versionSnapshots[$_.Id] -join ', ')" }
    throw "Deployment-version skew prevents a latency comparison. $($details -join ' | ')"
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$insoVersion = (& $insoCommand.Source --version 2>&1 | Out-String).Trim()
$runRecords = New-Object System.Collections.Generic.List[object]
foreach ($target in $selectedTargets) {
    $firstPassPhase = if (Test-GatewayTarget $target) { "gateway-empty first-pass" } else { "VM first-pass" }
    $runRecords.Add((Invoke-PerformanceRun $target $firstPassPhase 1 $versionSnapshots[$target.Id] $timestamp))
    for ($iteration = 1; $iteration -le $WarmIterations; $iteration++) {
        $runRecords.Add((Invoke-PerformanceRun $target "presumed-warm" $iteration $versionSnapshots[$target.Id] $timestamp))
    }
}

$failedRuns = @($runRecords | Where-Object { $_.exit_code -ne 0 -or -not $_.capture_complete })
$events = @($runRecords | ForEach-Object { $_.events })
$rawPath = Join-Path $OutputDirectory "performance-raw-$timestamp.json"
$csvPath = Join-Path $OutputDirectory "performance-summary-$timestamp.csv"
$summaryPath = Join-Path $OutputDirectory "performance-summary-$timestamp.json"

$raw = [ordered]@{
    generated_utc = (Get-Date).ToUniversalTime().ToString("o")
    inso_version = $insoVersion
    settings = [ordered]@{
        warm_iterations = $WarmIterations
        delay_ms = $DelayMs
        request_timeout_ms = $RequestTimeoutMs
        request_order = @($selectedTargets | ForEach-Object { $_.Name })
    }
    resolved_versions = $referenceSnapshot
    runs = $runRecords
    request_events = $events
}
Write-JsonFile $rawPath $raw

$summary = foreach ($group in ($events | Where-Object { $null -ne $_.response_time_ms } | Group-Object target, endpoint, format, phase)) {
    $samples = @($group.Group | ForEach-Object { [double]$_.response_time_ms })
    [pscustomobject]@{
        target = $group.Group[0].target
        endpoint = $group.Group[0].endpoint
        format = $group.Group[0].format
        phase = $group.Group[0].phase
        count = $samples.Count
        errors = @($group.Group | Where-Object { $_.error }).Count
        min_ms = [double](($samples | Measure-Object -Minimum).Minimum)
        median_ms = Get-Percentile $samples 0.5
        p90_ms = Get-Percentile $samples 0.9
        p95_ms = Get-Percentile $samples 0.95
        max_ms = [double](($samples | Measure-Object -Maximum).Maximum)
    }
}

@($summary) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
Write-JsonFile $summaryPath @($summary)

Write-Host "Raw results: $rawPath"
Write-Host "Summary CSV: $csvPath"
Write-Host "Summary JSON: $summaryPath"
if ($events.Count -eq 0) {
    throw "Inso did not emit parseable performance console records. Raw Inso and console artifacts were saved, but no latency summary was produced."
}
elseif ($events.Count -ne ($runRecords.Count * 6)) {
    throw "Inso reported $($events.Count) performance request records; expected $($runRecords.Count * 6). Review '$rawPath'."
}
if ($failedRuns.Count -gt 0) {
    throw "$($failedRuns.Count) performance run(s) failed. Review '$rawPath'."
}
