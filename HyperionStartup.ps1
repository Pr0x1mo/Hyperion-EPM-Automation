# HyperionStartup.ps1
# hyperion epm sequential service startup script - dev environment
# vpm us technology pilot - post patch startup & validation
#
# runs as NT AUTHORITY\SYSTEM via task scheduler on startup
# dot-sources .env.ps1, .secrets.ps1, .functions.ps1 from same directory
#
# deploy this script plus the three dot-sourced files to D:\Oracle\scripts\
# on each of the three hyperion dev servers. task scheduler calls this file
# on each server at startup with a 2 minute delay.

param([string]$Environment = "DEV")

. "$PSScriptRoot\.env.ps1"
. "$PSScriptRoot\.secrets.ps1"
. "$PSScriptRoot\.functions.ps1"

# ============================================================================
# initialize log file for this run
# ============================================================================
New-LogFile -Prefix "HyperionStartup" | Out-Null
Import-Secrets

$Global:MaxLValidLog = "$Global:LogDir\ValidateEssbase_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Log "running as: $currentUser"
Write-Log "orchestrating from: $env:COMPUTERNAME"
Write-Log "environment: $Environment"
Write-Log "=============================================="
Write-Log "Hyperion EPM Sequential Service Startup - DEV"
Write-Log "VPM US Technology Pilot - Post Patch Startup"
Write-Log "services to start: $($Global:StartupSequence.Count) (+ OHS component)"
Write-Log "=============================================="
Write-Log "servers:"
Write-Log "  $Global:FOU  (foundation/weblogic/ohs/FR/calcmgr)"
Write-Log "  $Global:HFM  (hfm java/hfm web/fdmee)"
Write-Log "  $Global:ESS  (tomcat/essbase)"
Write-Log "=============================================="

$startedServices = @()
$skippedServices = @()

# ============================================================================
# startup sequence
# ============================================================================
for ($i = 0; $i -lt $Global:StartupSequence.Count; $i++) {
    $item   = $Global:StartupSequence[$i]
    $svc    = $item.Service
    $server = $item.Server
    $wait   = $item.Wait
    $desc   = $item.Desc
    $step   = $i + 1
    $total  = $Global:StartupSequence.Count

    Write-Log "[$step/$total] starting $desc ($svc) on $server..."

    try {
        $result = Start-RemoteService -Server $server -ServiceName $svc -Timeout $Global:TimeoutSeconds

        if ($result -eq "ALREADY_RUNNING") {
            Write-Log "[$step/$total] $desc already running. skipping." "SUCCESS"
        }
        else {
            Write-Log "[$step/$total] $desc is RUNNING." "SUCCESS"
        }
        $startedServices += "$desc on $server"
    }
    catch {
        $err = $_.Exception.Message
        Write-Log "[$step/$total] FAILED - $($desc): $err" "ERROR"

        $skippedServices = @("$desc on $server")
        if ($i + 1 -lt $Global:StartupSequence.Count) {
            $skippedServices += ($Global:StartupSequence[($i + 1)..($Global:StartupSequence.Count - 1)] | ForEach-Object { "$($_.Desc) on $($_.Server)" })
        }

        Send-FailureAlert -FailedService $desc -FailedServer $server -FailedStep $step -TotalSteps $total `
            -StartedServices $startedServices -SkippedServices $skippedServices -ErrorDetail $err

        Write-Log "HALTING - remaining services will NOT be started." "ERROR"
        exit 1
    }

    # special case: after OHS node manager, fire startComponent.cmd
    if ($svc -eq "Oracle Weblogic ohs NodeManager (D_Oracle_Middleware_ohs_wlserver)") {
        Write-Log "[$step/$total] starting OHS component via startComponent.cmd on $Global:OHSServer..."
        try {
            Invoke-OHSStartComponent -Server $Global:OHSServer -Path $Global:OHSStartComponentPath `
                -Component $Global:OHSComponentName -WaitSeconds $Global:OHSWaitAfterStart
        }
        catch {
            $err = "OHS startComponent.cmd failed: $($_.Exception.Message)"
            Write-Log "[$step/$total] $err" "ERROR"

            $remaining = $Global:StartupSequence[($i + 1)..($Global:StartupSequence.Count - 1)] | ForEach-Object { "$($_.Desc) on $($_.Server)" }
            Send-FailureAlert -FailedService "OHS Component Start" -FailedServer $Global:OHSServer -FailedStep $step -TotalSteps $total `
                -StartedServices $startedServices -SkippedServices $remaining -ErrorDetail $err

            Write-Log "HALTING - remaining services will NOT be started." "ERROR"
            exit 1
        }
    }

    Write-Log "waiting ${wait}s before next service..."
    Start-Sleep -Seconds $wait
}

Write-Log "=============================================="
Write-Log "ALL SERVICES STARTED SUCCESSFULLY" "SUCCESS"
Write-Log "=============================================="

# ============================================================================
# post startup validation
# step 1: status.cmd - confirms essbase_server1 RUNNING
# step 2: maxl       - confirms essbase accepting connections
# ============================================================================

Write-Log ""
Write-Log "=============================================="
Write-Log "running essbase validation against $Global:EssbaseServer..."
Write-Log "=============================================="

$validationFailed = $false

$statusOk = Invoke-EssbaseStatusCheck -Server $Global:EssbaseServer -MaxWaitSeconds $Global:EssbaseStatusTimeout
if (-not $statusOk) {
    $err = "status.cmd did not confirm essbase_server1 RUNNING within $($Global:EssbaseStatusTimeout)s"
    Write-Log $err "ERROR"
    Send-FailureAlert -FailedService "Essbase (status.cmd)" -FailedServer $Global:EssbaseServer `
        -FailedStep 0 -TotalSteps 0 -StartedServices $startedServices -SkippedServices @() `
        -ErrorDetail $err -Phase "POST-STARTUP VALIDATION"
    $validationFailed = $true
}

try {
    Write-Log "running maxl validation on $Global:EssbaseServer..."
    $maxlOutput = Invoke-MaxLValidation -Server $Global:EssbaseServer -ValidationLog $Global:MaxLValidLog

    if ($maxlOutput -match "essmsh error|Cannot connect|Login failed|Unable to connect") {
        $err = "essbase maxl validation returned errors. check log: $Global:MaxLValidLog"
        Write-Log $err "ERROR"
        Write-Log "maxl output:`n$maxlOutput" "ERROR"
        Send-FailureAlert -FailedService "Essbase (MaxL Validation)" -FailedServer $Global:EssbaseServer `
            -FailedStep 0 -TotalSteps 0 -StartedServices $startedServices -SkippedServices @() `
            -ErrorDetail $err -Phase "POST-STARTUP VALIDATION"
        $validationFailed = $true
    }
    else {
        Write-Log "essbase maxl validation passed. log: $Global:MaxLValidLog" "SUCCESS"
        Write-Log "maxl output:`n$maxlOutput" "INFO"
    }
}
catch {
    $err = "maxl execution failed: $($_.Exception.Message)"
    Write-Log $err "ERROR"
    Send-FailureAlert -FailedService "Essbase (MaxL Validation)" -FailedServer $Global:EssbaseServer `
        -FailedStep 0 -TotalSteps 0 -StartedServices $startedServices -SkippedServices @() `
        -ErrorDetail $err -Phase "POST-STARTUP VALIDATION"
    $validationFailed = $true
}

Write-Log ""
Write-Log "=============================================="
if ($validationFailed) {
    Write-Log "hyperion dev startup complete but post-startup validation FAILED." "ERROR"
    Write-Log "log file: $Global:LogFile" "INFO"
    Write-Log "=============================================="
    exit 1
}

Write-Log "hyperion dev post-patch startup and validation complete." "SUCCESS"
Write-Log "log file: $Global:LogFile" "INFO"
Write-Log "=============================================="
exit 0
