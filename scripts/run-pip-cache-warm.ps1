[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BaseUrl,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Environment,

    [ValidateRange(0, 60000)]
    [int]$DelayMs = 250,

    [ValidateRange(1000, 900000)]
    [int]$RequestTimeoutMs = 180000,

    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path (Join-Path $PSScriptRoot "..") (Join-Path "results" "cache-warm")),

    [switch]$GenerateOnly,

    [ValidateRange(0, 100000)]
    [int]$Limit = 0,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceId = "wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3"
$cacheWarmRequestId = "req_b5d107e4c8394a62bf1e7530d8962ca4"
$collectionPath = Join-Path (Join-Path $PSScriptRoot "..") "insomnia.wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3.yaml"
$collectionFile = (Resolve-Path -LiteralPath $collectionPath -ErrorAction Stop).Path
$requestTimeoutSeconds = [int][Math]::Ceiling($RequestTimeoutMs / 1000.0)

$targets = @(
    [pscustomobject]@{ Name = "Local"; Id = "env_1aa0ac83930048d2ae39983fd194ff23"; BaseUrl = "http://127.0.0.1:8080/api/v1" }
    [pscustomobject]@{ Name = "Dev - Gateway"; Id = "env_2fdc6a2c8e6148b5bcff1f65f04eabd6"; BaseUrl = "https://apiv2dev.worldbank.org/pip/v1" }
    [pscustomobject]@{ Name = "Dev - VM1"; Id = "env_b631255845de4a989b6f4a9f8fcc0b91"; BaseUrl = "http://wzlxdpip01.worldbank.org/api/v1" }
    [pscustomobject]@{ Name = "QA - Gateway"; Id = "env_308cc551c5734a96ada11d1fb8d4d3e3"; BaseUrl = "https://apiv2qa.worldbank.org/pip/v1" }
    [pscustomobject]@{ Name = "QA - VM1"; Id = "env_c5b2808184034d7b8952b8209650e5e4"; BaseUrl = "http://wzlxqpip01.worldbank.org/api/v1" }
    [pscustomobject]@{ Name = "QA - VM2"; Id = "env_8d2cf0336c2645f4b50264332d73d608"; BaseUrl = "http://wzlxqpip02.worldbank.org/api/v1" }
    [pscustomobject]@{ Name = "Prod - Gateway"; Id = "env_2f404d334d4e45198c75ec339a192e39"; BaseUrl = "https://api.worldbank.org/pip/v1" }
    [pscustomobject]@{ Name = "Prod - VM1"; Id = "env_f4c749f676be4e47aff9803eee5d1bb3"; BaseUrl = "http://wzlxppip01.worldbank.org/api/v1" }
    [pscustomobject]@{ Name = "Prod - VM2"; Id = "env_5e40f167f49741538f2b81b7bccbcccb"; BaseUrl = "http://wzlxppip02.worldbank.org/api/v1" }
    [pscustomobject]@{ Name = "Prod - VM3"; Id = "env_7475b41083f0406d92dae9d626575ba1"; BaseUrl = "http://wzlxppip03.worldbank.org/api/v1" }
)

function Get-EnvironmentKey {
    param([string]$Value)

    return (($Value.Trim().ToLowerInvariant()) -replace "[\s_-]+", "")
}

function Get-Target {
    param([string]$Value)

    $trimmedValue = $Value.Trim()
    $matches = @($targets | Where-Object { $_.Name -ieq $trimmedValue -or $_.Id -ceq $trimmedValue })
    if ($matches.Count -eq 0) {
        $environmentKey = Get-EnvironmentKey $trimmedValue
        $matches = @($targets | Where-Object { (Get-EnvironmentKey $_.Name) -eq $environmentKey })
    }

    if ($matches.Count -ne 1) {
        $knownNames = ($targets | ForEach-Object { $_.Name }) -join ", "
        throw "Unknown environment '$Value'. Use an existing collection environment name or ID. Known names: $knownNames."
    }

    return $matches[0]
}

function Get-NormalizedBaseUrl {
    param([string]$Value)

    $parsedUri = $null
    if (-not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$parsedUri)) {
        throw "BaseUrl '$Value' is not an absolute URL."
    }

    if ($parsedUri.Scheme -notin @("http", "https")) {
        throw "BaseUrl '$Value' must use HTTP or HTTPS."
    }

    if (-not [string]::IsNullOrEmpty($parsedUri.Query) -or -not [string]::IsNullOrEmpty($parsedUri.Fragment)) {
        throw "BaseUrl '$Value' must not contain a query string or fragment."
    }

    return $parsedUri.AbsoluteUri.TrimEnd("/")
}

function Get-ArrayResponse {
    param($Value, [string]$Description)

    if ($null -eq $Value) {
        throw "$Description returned no JSON data."
    }

    if ($Value -is [System.Array]) {
        return $Value
    }

    foreach ($propertyName in @("data", "results")) {
        $property = $Value.PSObject.Properties[$propertyName]
        if ($null -ne $property) {
            if ($null -eq $property.Value) {
                return @()
            }
            return @($property.Value)
        }
    }

    return @($Value)
}

function Get-RequiredString {
    param($Value, [string]$PropertyName, [string]$Description)

    $property = $Value.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "$Description does not contain a non-empty '$PropertyName' value."
    }

    return ([string]$property.Value).Trim()
}

function ConvertTo-InvariantDecimal {
    param([string]$Value, [string]$Description)

    [decimal]$number = 0
    $style = [Globalization.NumberStyles]::Number
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not [decimal]::TryParse($Value, $style, $culture, [ref]$number)) {
        throw "$Description value '$Value' is not a valid invariant-culture number."
    }

    return $number
}

function Invoke-PipJson {
    param([string]$Uri, [string]$Description)

    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers @{ Accept = "application/json" } -TimeoutSec $requestTimeoutSeconds
    }
    catch {
        throw "$Description failed at '$Uri': $($_.Exception.Message)"
    }
}

function Get-SelectedVersions {
    param([string]$TargetBaseUrl)

    $versions = @(Get-ArrayResponse (Invoke-PipJson "$TargetBaseUrl/versions" "Version discovery") "/versions")
    if ($versions.Count -eq 0) {
        throw "/versions returned an empty list."
    }

    $prodVersions = @(
        foreach ($version in $versions) {
            $identity = Get-RequiredString $version "identity" "/versions row"
            if ($identity -ceq "PROD") {
                $pppVersion = Get-RequiredString $version "ppp_version" "/versions PROD row"
                $releaseVersion = Get-RequiredString $version "release_version" "/versions PROD row"
                $resolvedVersion = Get-RequiredString $version "version" "/versions PROD row"
                [pscustomobject]@{
                    PppVersion = $pppVersion
                    PppSort = ConvertTo-InvariantDecimal $pppVersion "/versions ppp_version"
                    ReleaseVersion = $releaseVersion
                    ReleaseSort = ConvertTo-InvariantDecimal $releaseVersion "/versions release_version"
                    ResolvedVersion = $resolvedVersion
                }
            }
        }
    )

    if ($prodVersions.Count -eq 0) {
        throw "/versions returned no rows with identity 'PROD'."
    }

    $selected = @(
        foreach ($group in ($prodVersions | Group-Object -Property PppVersion)) {
            $orderedGroup = @(
                $group.Group | Sort-Object `
                    @{ Expression = { $_.ReleaseSort }; Descending = $true }, `
                    @{ Expression = { $_.ResolvedVersion }; Descending = $true }
            )
            $latest = $orderedGroup[0]
            [pscustomobject]@{
                PppVersion = $latest.PppVersion
                ReleaseVersion = $latest.ReleaseVersion
                ResolvedVersion = $latest.ResolvedVersion
            }
        }
    )

    return @($selected | Sort-Object @{ Expression = { ConvertTo-InvariantDecimal $_.PppVersion "/versions ppp_version" } })
}

function Get-VersionSnapshot {
    param([object[]]$Versions)

    return @(
        $Versions |
            ForEach-Object { "$($_.PppVersion)|$($_.ReleaseVersion)|$($_.ResolvedVersion)" } |
            Sort-Object
    )
}

function Write-JsonFile {
    param(
        [string]$Path,
        $Value,
        [switch]$AsArray,
        [switch]$Compress
    )

    if ($AsArray) {
        $jsonValue = @($Value)
    }
    else {
        $jsonValue = $Value
    }
    $json = ConvertTo-Json -InputObject $jsonValue -Depth 10 -Compress:$Compress
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8WithoutBom)
}

if ($GenerateOnly -and $Execute) {
    throw "Use either -GenerateOnly or -Execute, not both. Execution requires only -Execute."
}

$target = Get-Target $Environment
if ($target.Name -notlike "* - Gateway" -and $target.Name -ne "Local") {
    throw "Cache warming supports gateway environments only. '$($target.Name)' is a direct API target and cannot warm the gateway cache."
}
if ($target.Name -eq "Local" -and $Execute -and $Limit -eq 0) {
    throw "Local execution is only for a small verification run. Specify -Limit before using -Execute."
}
$normalizedBaseUrl = Get-NormalizedBaseUrl $BaseUrl
$knownBaseUrl = Get-NormalizedBaseUrl $target.BaseUrl
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($normalizedBaseUrl, $knownBaseUrl)) {
    throw "BaseUrl '$BaseUrl' does not match '$($target.Name)' ($($target.BaseUrl)). Inso uses the selected collection environment, so correct this drift before generation or execution."
}

Write-Host "Environment: $($target.Name) ($($target.Id))"
Write-Host "BaseUrl: $normalizedBaseUrl"

try {
    $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
}
catch {
    throw "OutputDirectory '$OutputDirectory' is invalid: $($_.Exception.Message)"
}

if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
    throw "OutputDirectory '$OutputDirectory' is a file, not a directory."
}

try {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Container)) {
        New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
    }
    $OutputDirectory = (Resolve-Path -LiteralPath $outputPath -ErrorAction Stop).Path
}
catch {
    throw "OutputDirectory '$OutputDirectory' could not be created or resolved: $($_.Exception.Message)"
}

$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ", [Globalization.CultureInfo]::InvariantCulture)
$selectedVersions = @(Get-SelectedVersions $normalizedBaseUrl)
$versionSnapshot = @(Get-VersionSnapshot $selectedVersions)
$rows = New-Object System.Collections.Generic.List[object]
$povertyLineCounts = New-Object System.Collections.Generic.List[object]
$seenRows = @{}
$totalPovertyLineCount = 0

foreach ($version in $selectedVersions) {
    $encodedVersion = [Uri]::EscapeDataString($version.ResolvedVersion)
    $povertyLines = @(
        Get-ArrayResponse `
            (Invoke-PipJson "$normalizedBaseUrl/poverty-lines?version=$encodedVersion" "Poverty-line discovery") `
            "/poverty-lines"
    )
    if ($povertyLines.Count -eq 0) {
        throw "/poverty-lines returned no rows for '$($version.ResolvedVersion)'."
    }

    $names = New-Object System.Collections.Generic.List[string]
    $seenNames = @{}
    foreach ($povertyLine in $povertyLines) {
        $name = Get-RequiredString $povertyLine "name" "/poverty-lines row for '$($version.ResolvedVersion)'"
        $null = ConvertTo-InvariantDecimal $name "/poverty-lines name"
        if (-not $seenNames.ContainsKey($name)) {
            $seenNames[$name] = $true
            $names.Add($name)
        }
    }

    if ($names.Count -eq 0) {
        throw "/poverty-lines returned no named rows for '$($version.ResolvedVersion)'."
    }

    $totalPovertyLineCount += $names.Count
    $povertyLineCounts.Add([pscustomobject]@{
        ppp_version = $version.PppVersion
        count = $names.Count
    })

    foreach ($name in $names) {
        foreach ($format in @("json", "csv")) {
            $rowKey = "$($version.PppVersion)|$name|$format"
            if (-not $seenRows.ContainsKey($rowKey)) {
                $seenRows[$rowKey] = $true
                $rows.Add([pscustomobject]@{
                    povline = $name
                    ppp_version = $version.PppVersion
                    format = $format
                    release_version = $version.ReleaseVersion
                    resolved_version = $version.ResolvedVersion
                })
            }
        }
    }
}

$expectedRows = 2 * $totalPovertyLineCount
if ($rows.Count -ne $expectedRows) {
    throw "Generated $($rows.Count) unique cache-warm rows, but expected $expectedRows rows (two formats for each of $totalPovertyLineCount unique poverty lines)."
}

$sortedRows = @(
    $rows | Sort-Object `
        @{ Expression = { ConvertTo-InvariantDecimal $_.ppp_version "iteration ppp_version" } }, `
        @{ Expression = { ConvertTo-InvariantDecimal $_.povline "iteration povline" } }, `
        @{ Expression = { $_.format } }, `
        @{ Expression = { $_.povline } }
)

if ($Limit -gt 0) {
    $sortedRows = @($sortedRows | Select-Object -First $Limit)
}

$expectedIterationRows = if ($Limit -gt 0) { [Math]::Min($Limit, $expectedRows) } else { $expectedRows }
if ($sortedRows.Count -ne $expectedIterationRows -or $sortedRows.Count -eq 0) {
    throw "Generated $($sortedRows.Count) iteration rows after -Limit $Limit, but expected $expectedIterationRows."
}

$iterationDataPath = Join-Path $OutputDirectory "cache-warm-iterations-$timestamp.json"
$resultPath = Join-Path $OutputDirectory "cache-warm-inso-$timestamp.json"
$consolePath = Join-Path $OutputDirectory "cache-warm-console-$timestamp.log"
$recordsPath = Join-Path $OutputDirectory "cache-warm-records-$timestamp.json"
$manifestPath = Join-Path $OutputDirectory "cache-warm-manifest-$timestamp.json"
Write-JsonFile -Path $iterationDataPath -Value $sortedRows -AsArray

$manifest = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    mode = if ($Execute) { "execute" } else { "generate-only" }
    status = "generated"
    environment = $target.Name
    environment_id = $target.Id
    base_url = $normalizedBaseUrl
    workspace_id = $workspaceId
    request_id = $cacheWarmRequestId
    selected_versions = @($selectedVersions)
    poverty_line_counts = @($povertyLineCounts)
    unique_poverty_lines = $totalPovertyLineCount
    source_expected_rows = $expectedRows
    iteration_rows = $sortedRows.Count
    limit = $Limit
    delay_ms = $DelayMs
    request_timeout_ms = $RequestTimeoutMs
    iteration_data = $iterationDataPath
    inso_output = if ($Execute) { $resultPath } else { $null }
    console_output = if ($Execute) { $consolePath } else { $null }
    compact_records = if ($Execute) { $recordsPath } else { $null }
}
Write-JsonFile -Path $manifestPath -Value $manifest -Compress

Write-Host "Selected latest PROD versions:"
$selectedVersions | Format-Table PppVersion, ReleaseVersion, ResolvedVersion -AutoSize
Write-Host "Generated $($sortedRows.Count) iteration rows ($expectedRows rows before -Limit)."
Write-Host "Iteration data: $iterationDataPath"
Write-Host "Manifest: $manifestPath"

if (-not $Execute) {
    Write-Host "Discovery and generation only. Use -Execute only after the release is healthy and ITS confirms the gateway cache reset."
    return
}

$insoCommand = Get-Command inso -ErrorAction SilentlyContinue
if ($null -eq $insoCommand) {
    throw "Inso CLI was not found. Iteration data was generated, but execution requires 'npm install --global insomnia-inso'."
}

$arguments = @(
    "--ci",
    "-w", $collectionFile,
    "run", "collection",
    "--item", $cacheWarmRequestId,
    "--env", $target.Id,
    "--iteration-data", $iterationDataPath,
    "--delay-request", [string]$DelayMs,
    "--requestTimeout", [string]$RequestTimeoutMs,
    "--output", $resultPath,
    $workspaceId
)

Write-Host "Running cache warming for $($target.Name)..."
$insoExitCode = 1
$insoError = $null
$insoOutput = @()
try {
    $LASTEXITCODE = 0
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $insoOutput = @(& $insoCommand.Source @arguments 2>&1 | ForEach-Object { $_.ToString() })
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $insoExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
}
catch {
    $insoError = $_.Exception.Message
    if ($null -ne $LASTEXITCODE) {
        $insoExitCode = [int]$LASTEXITCODE
    }
}

foreach ($line in $insoOutput) {
    Write-Host $line
}
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllLines($consolePath, [string[]]$insoOutput, $utf8WithoutBom)

$compactRecords = New-Object System.Collections.Generic.List[object]
$recordParseErrors = New-Object System.Collections.Generic.List[string]
$recordPattern = "PIP_CACHE_WARM_RESULT\s+(\{.*\})"
foreach ($line in $insoOutput) {
    if ($line -match $recordPattern) {
        try {
            $record = $Matches[1] | ConvertFrom-Json
            $compactRecords.Add([pscustomobject][ordered]@{
                environment = $target.Name
                environment_id = $target.Id
                timestamp_utc = $record.timestampUtc
                povline = $record.povline
                ppp_version = $record.pppVersion
                format = $record.format
                release_version = $record.releaseVersion
                resolved_version = $record.resolvedVersion
                response_time_ms = $record.responseTime
                status = $record.status
                response_size = $record.responseSize
                pipapi_cache = $record.pipapiCache
                gateway_cache_signal = $record.gatewayCacheSignal
            })
        }
        catch {
            $recordParseErrors.Add($_.Exception.Message)
        }
    }
}
Write-JsonFile -Path $recordsPath -Value $compactRecords -AsArray

$successfulRecords = @($compactRecords | Where-Object { [int]$_.status -eq 200 }).Count
$errorRecords = @($compactRecords | Where-Object { [int]$_.status -ne 200 }).Count
$missingRecords = [Math]::Max(0, $sortedRows.Count - $compactRecords.Count)

$versionCheckError = $null
$versionSetChanged = $false
try {
    $afterVersions = @(Get-SelectedVersions $normalizedBaseUrl)
    $afterSnapshot = @(Get-VersionSnapshot $afterVersions)
    $versionDifferences = @(Compare-Object -ReferenceObject $versionSnapshot -DifferenceObject $afterSnapshot)
    $versionSetChanged = $versionDifferences.Count -gt 0
}
catch {
    $versionCheckError = $_.Exception.Message
}

$manifest["execution_completed_utc"] = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
$manifest["inso_exit_code"] = $insoExitCode
$manifest["inso_error"] = $insoError
$manifest["version_set_changed_during_run"] = $versionSetChanged
$manifest["version_check_error"] = $versionCheckError
$manifest["result_summary"] = [ordered]@{
    expected_rows = $sortedRows.Count
    recorded_rows = $compactRecords.Count
    successful_rows = $successfulRecords
    error_rows = $errorRecords
    missing_rows = $missingRecords
    parse_errors = @($recordParseErrors)
}
$manifest["status"] = if ($null -ne $versionCheckError) {
    "version-check-failed"
}
elseif ($versionSetChanged) {
    "version-set-changed"
}
elseif ($null -ne $insoError -or $insoExitCode -ne 0) {
    "inso-failed"
}
elseif ($recordParseErrors.Count -gt 0 -or $compactRecords.Count -ne $sortedRows.Count) {
    "result-records-incomplete"
}
else {
    "completed"
}
Write-JsonFile -Path $manifestPath -Value $manifest -Compress

if ($null -ne $versionCheckError) {
    throw "Cache warming finished, but the post-run /versions check failed: $versionCheckError Review '$manifestPath'."
}

if ($versionSetChanged) {
    throw "The selected PROD version set changed during cache warming. Review '$manifestPath' and rerun against a stable release."
}

if ($null -ne $insoError) {
    throw "Inso could not complete cache warming: $insoError Review '$resultPath' and '$manifestPath'."
}

if ($insoExitCode -ne 0) {
    throw "Inso reported cache-warm failures (exit code $insoExitCode). Review '$resultPath' and '$manifestPath'."
}

if ($recordParseErrors.Count -gt 0 -or $compactRecords.Count -ne $sortedRows.Count) {
    throw "Cache warming did not produce one valid compact result record per iteration. Review '$consolePath', '$recordsPath', and '$manifestPath'."
}

Write-Host "Cache warming completed. Manifest: $manifestPath"
