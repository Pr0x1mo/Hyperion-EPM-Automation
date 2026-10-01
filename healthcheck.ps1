# healthcheck.ps1
# hyperion epm health check script - dev environment
# vpm us technology pilot
#
# usage:
#   .\healthcheck.ps1           - standard health check
#   .\healthcheck.ps1 -Detailed - includes access group and service account info
#
# returns exit 0 if all checks pass, exit 1 if any check fails

param(
    [string]$Environment = "DEV",
    [switch]$Detailed
)

. "$PSScriptRoot\.env.ps1"
. "$PSScriptRoot\.secrets.ps1"
. "$PSScriptRoot\.functions.ps1"

New-LogFile -Prefix "healthcheck" | Out-Null
Import-Secrets

$failures = @()

Write-Log "Starting Hyperion health check"
Write-Log "environment: $Environment"
Write-ConfigurationSummary

# ============================================================================
# http endpoint checks
# ============================================================================
Write-Log "--- HTTP Endpoint Checks ---"

if (Test-HttpEndpoint -Url $Global:HyperionConfig.Urls.Workspace) {
    Write-Log "Workspace URL is reachable: $($Global:HyperionConfig.Urls.Workspace)" "PASS"
}
else {
    Write-Log "Workspace URL is not reachable: $($Global:HyperionConfig.Urls.Workspace)" "FAIL"
    $failures += "Workspace URL"
}

if (Test-HttpEndpoint -Url $Global:HyperionConfig.Urls.Essbase) {
    Write-Log "Essbase URL is reachable: $($Global:HyperionConfig.Urls.Essbase)" "PASS"
}
else {
    Write-Log "Essbase URL is not reachable: $($Global:HyperionConfig.Urls.Essbase)" "FAIL"
    $failures += "Essbase URL"
}

if (Test-HttpEndpoint -Url $Global:HyperionConfig.Urls.DodecaTomcat) {
    Write-Log "Dodeca Tomcat is reachable: $($Global:HyperionConfig.Urls.DodecaTomcat)" "PASS"
}
else {
    Write-Log "Dodeca Tomcat is not reachable: $($Global:HyperionConfig.Urls.DodecaTomcat)" "FAIL"
    $failures += "Dodeca Tomcat URL"
}

if (Test-HttpEndpoint -Url $Global:HyperionConfig.Urls.DodecaMeta) {
    Write-Log "Dodeca Metadata Service is reachable: $($Global:HyperionConfig.Urls.DodecaMeta)" "PASS"
}
else {
    Write-Log "Dodeca Metadata Service is not reachable: $($Global:HyperionConfig.Urls.DodecaMeta)" "FAIL"
    $failures += "Dodeca Metadata URL"
}

# ============================================================================
# connectivity checks - WARN only, do not fail the health check
# known connectivity limitations exist in DEV for repository and SQL MI
# ============================================================================
Write-Log "--- Connectivity Checks ---"

if (-not (Test-RepositoryConnectivity)) {
    Write-Log "Repository connectivity check failed - treating as warning, not failing health check" "WARN"
}

if (-not (Test-SqlMiDependency)) {
    Write-Log "SQL MI connectivity check failed - treating as warning, not failing health check" "WARN"
}

# ============================================================================
# service state checks
# ============================================================================
Write-Log "--- Service State Checks (Sequence Order) ---"

$orderedServices = $Global:HyperionConfig.Services | Sort-Object Sequence
foreach ($svc in $orderedServices) {
    $stateText = Get-RemoteServiceStateText -Server $svc.Server -ServiceName $svc.ServiceName
    if ($stateText -eq "RUNNING") {
        Write-Log "[Seq $($svc.Sequence)] $($svc.StepName) is RUNNING on $($svc.Server)" "PASS"
    }
    else {
        Write-Log "[Seq $($svc.Sequence)] $($svc.StepName) is not confirmed RUNNING on $($svc.Server) (State: $stateText)" "WARN"
    }
}

# ============================================================================
# native log check
# ============================================================================
Write-Log "--- Log Directory Check ---"

if (-not (Test-HyperionNativeLogs)) {
    Write-Log "Native log validation did not confirm expected evidence" "WARN"
}

# ============================================================================
# detailed output
# ============================================================================
if ($Detailed) {
    Write-Log "Known access groups: $($Global:HyperionConfig.AccessGroups -join ', ')"
    Write-Log "Known service account naming pattern: $($Global:HyperionConfig.ServiceAccountPattern)"
}

# ============================================================================
# result
# ============================================================================
if ($failures.Count -gt 0) {
    Write-Log "Health check FAILED for: $($failures -join ', ')" "ERROR"
    exit 1
}

Write-Log "All configured health checks passed" "PASS"
exit 0
