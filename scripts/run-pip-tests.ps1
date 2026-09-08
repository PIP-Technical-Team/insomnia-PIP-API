[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Local", "Dev", "QA", "Prod")]
    [string]$Stage,

    [ValidateSet("Smoke", "Full")]
    [string]$Suite = "Smoke"
)

$insoCommand = Get-Command inso -ErrorAction SilentlyContinue
if ($null -eq $insoCommand) {
    Write-Error "Inso CLI was not found. Install it with 'npm install --global insomnia-inso', then open a new PowerShell session."
    exit 127
}

$collectionFile = Join-Path $PSScriptRoot "..\insomnia.wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3.yaml"
$collectionFile = (Resolve-Path -LiteralPath $collectionFile -ErrorAction Stop).Path

$workspaceId = "wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3"
$gatewayFolderId = "fld_3f40b490f9fe4776861207329443e521"
$smokeFolderId = "fld_bf574077466b41efa91f2f0c299c44a8"
$directFolderId = "fld_536bbd4bd50f42d3ae995f7b2e1144e3"
$requestTimeout = 120000

$allTargets = @{
    Local = @(
        [pscustomobject]@{ Name = "Local"; Environment = "env_1aa0ac83930048d2ae39983fd194ff23"; IsGateway = $false }
    )
    Dev = @(
        [pscustomobject]@{ Name = "Dev - Gateway"; Environment = "env_2fdc6a2c8e6148b5bcff1f65f04eabd6"; IsGateway = $true }
        [pscustomobject]@{ Name = "Dev - VM1"; Environment = "env_b631255845de4a989b6f4a9f8fcc0b91"; IsGateway = $false }
    )
    QA = @(
        [pscustomobject]@{ Name = "QA - Gateway"; Environment = "env_308cc551c5734a96ada11d1fb8d4d3e3"; IsGateway = $true }
        [pscustomobject]@{ Name = "QA - VM1"; Environment = "env_c5b2808184034d7b8952b8209650e5e4"; IsGateway = $false }
        [pscustomobject]@{ Name = "QA - VM2"; Environment = "env_8d2cf0336c2645f4b50264332d73d608"; IsGateway = $false }
    )
    Prod = @(
        [pscustomobject]@{ Name = "Prod - Gateway"; Environment = "env_2f404d334d4e45198c75ec339a192e39"; IsGateway = $true }
        [pscustomobject]@{ Name = "Prod - VM1"; Environment = "env_f4c749f676be4e47aff9803eee5d1bb3"; IsGateway = $false }
        [pscustomobject]@{ Name = "Prod - VM2"; Environment = "env_5e40f167f49741538f2b81b7bccbcccb"; IsGateway = $false }
        [pscustomobject]@{ Name = "Prod - VM3"; Environment = "env_7475b41083f0406d92dae9d626575ba1"; IsGateway = $false }
    )
}

$results = foreach ($target in $allTargets[$Stage]) {
    $folderIds = if ($Suite -eq "Smoke") {
        @($smokeFolderId)
    }
    elseif ($target.IsGateway) {
        @($gatewayFolderId)
    }
    else {
        @($gatewayFolderId, $directFolderId)
    }

    $arguments = @("--ci", "-w", $collectionFile, "run", "collection")
    foreach ($folderId in $folderIds) {
        $arguments += @("-i", $folderId)
    }
    $arguments += @(
        "-e", $target.Environment,
        "--requestTimeout", $requestTimeout,
        $workspaceId
    )

    Write-Host "Running $Suite on $($target.Name)..."
    try {
        & $insoCommand.Source @arguments
        $targetExitCode = $LASTEXITCODE
        if ($null -eq $targetExitCode) {
            $targetExitCode = 0
        }
    }
    catch {
        Write-Error "Inso could not run $($target.Name): $($_.Exception.Message)"
        $targetExitCode = 1
    }

    [pscustomobject]@{
        Target = $target.Name
        Suite = $Suite
        Result = if ($targetExitCode -eq 0) { "PASS" } else { "FAIL" }
        ExitCode = $targetExitCode
    }
}

Write-Host ""
Write-Host "PIP API test summary"
$results | Format-Table -AutoSize

if (@($results | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0) {
    exit 1
}

exit 0
