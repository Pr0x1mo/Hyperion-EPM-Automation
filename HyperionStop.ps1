# HyperionStop.ps1
# hyperion epm sequential service stop script - dev environment
# vpm us technology pilot - pre-patch shutdown
#
# runs as NT AUTHORITY\SYSTEM via task scheduler or ansible
# dot-sources .env.ps1, .secrets.ps1, .functions.ps1 from same directory
#
# stop sequence:
#   phase 1 - essbase graceful quiesce (maxl: kill sessions, unload apps)
#   phase 2 - stop all 10 windows services in reverse startup order
#   phase 3 - kill stray processes (XFMDataSource.exe, httpd.exe)

param([string]$Environment = "DEV")

. "$PSScriptRoot\.env.ps1"
. "$PSScriptRoot\.secrets.ps1"
. "$PSScriptRoot\.functions.ps1"

# ============================================================================
# initialize
# ============================================================================
New-LogFile -Prefix "HyperionStop" | Out-Null
Import-Secrets

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Log "running as: $currentUser"
Write-Log "orchestrating from: $env:COMPUTERNAME"
Write-Log "environment: $Environment"
Write-Log "=============================================="
Write-Log "Hyperion EPM Sequential Service Stop - DEV"
Write-Log "VPM US Technology Pilot - Pre-Patch Shutdown"
Write-Log "=============================================="
Write-Log "servers:"
Write-Log "  $Global:FOU  (foundation/weblogic/ohs/FR/calcmgr)"
Write-Log "  $Global:HFM  (hfm java/hfm web/fdmee)"
Write-Log "  $Global:ESS  (tomcat/essbase)"
Write-Log "=============================================="

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ============================================================================
# phase 1: essbase graceful quiesce
# disable connects, kill requests, logout sessions, unload apps
# uses correct essbase 21c maxl syntax from KillSessionsStopApps.mxl
# ============================================================================

Write-Log ""
Write-Log "=============================================="
Write-Log "PHASE 1: Essbase graceful quiesce"
Write-Log "=============================================="

$maxlScriptPath = "D:\scripts\EssbaseStop.mxl"
$serverShortName = $Global:ESS.Split('.')[0].ToUpper()
$localHost = $env:COMPUTERNAME.ToUpper()
$essbaseIsLocal = $serverShortName -eq $localHost

$maxlContent = @"
login $($Global:MaxLUser) identified by '$($Global:MaxLPassword)' on localhost;
alter application US_SBU disable connects;
alter application CUSO disable connects;
alter system kill request on database CUSO.CUSO;
alter system kill request on database US_SBU.US_SBU;
alter system logout session on application CUSO force;
alter system logout session on application US_SBU force;
alter system unload application CUSO;
alter system unload application US_SBU;
logout;
exit;
"@

Write-Log "writing maxl quiesce script to $Global:ESS..."

try {
    if ($essbaseIsLocal) {
        $maxlContent | Out-File -FilePath $maxlScriptPath -Encoding ASCII
        Write-Log "running maxl quiesce locally on $Global:ESS..."
        $maxlResult = & $Global:MaxLPath $maxlScriptPath 2>&1
    }
    else {
        $maxlResult = Invoke-Command -ComputerName $Global:ESS -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
            param($maxl, $script, $content)
            $content | Out-File -FilePath $script -Encoding ASCII
            & $maxl $script 2>&1
        } -ArgumentList $Global:MaxLPath, $maxlScriptPath, $maxlContent -ErrorAction Stop
    }

    $maxlOutput = ($maxlResult | ForEach-Object { "$_" }) -join "`n"
    Write-Log "maxl quiesce output:`n$maxlOutput"

    $errorLines = ($maxlOutput -split "`n") | Where-Object { $_ -match "ERROR -" }
    $realErrors = $errorLines | Where-Object { $_ -notmatch "1054004" }

    if ($realErrors.Count -gt 0) {
        Write-Log "maxl quiesce returned real errors:" "WARN"
        $realErrors | ForEach-Object { Write-Log "  $_" "WARN" }
        Write-Log "continuing with service stop despite maxl warnings..." "WARN"
    }
    else {
        Write-Log "essbase graceful quiesce complete." "SUCCESS"
    }
}
catch {
    Write-Log "maxl quiesce failed: $($_.Exception.Message) - continuing with service stop..." "WARN"
}

# ============================================================================
# phase 2: stop windows services in reverse startup order
# ============================================================================

Write-Log ""
Write-Log "=============================================="
Write-Log "PHASE 2: stopping windows services (reverse order)"
Write-Log "=============================================="

$StopSequence = @(
    @{ Server = $Global:ESS; Service = "EssbaseService";                                                                  Wait = 60;  Desc = "Essbase 21C" }
    @{ Server = $Global:ESS; Service = "Tomcat10";                                                                        Wait = 30;  Desc = "Apache Tomcat 10.1" }
    @{ Server = $Global:FOU; Service = "HyS9CALC_epmsystem1";                                                             Wait = 15;  Desc = "Calc Manager" }
    @{ Server = $Global:HFM; Service = "HyS9aifWeb_epmsystem1";                                                           Wait = 15;  Desc = "FDMEE" }
    @{ Server = $Global:FOU; Service = "HyS9FRReports_epmsystem1";                                                        Wait = 15;  Desc = "Financial Reporting" }
    @{ Server = $Global:HFM; Service = "HyS9FinancialManagementWeb_epmsystem1";                                           Wait = 15;  Desc = "HFM Web" }
    @{ Server = $Global:HFM; Service = "HyS9FinancialManagementJavaServer_epmsystem1";                                    Wait = 15;  Desc = "HFM Java Server" }
    @{ Server = $Global:FOU; Service = "Oracle Weblogic ohs NodeManager (D_Oracle_Middleware_ohs_wlserver)";              Wait = 15;  Desc = "OHS Node Manager" }
    @{ Server = $Global:FOU; Service = "HyS9FoundationServices_epmsystem1";                                               Wait = 30;  Desc = "Foundation Services" }
    @{ Server = $Global:FOU; Service = "Oracle WebLogic_AdminServer";                                                     Wait = 30;  Desc = "WebLogic Admin Server" }
)

Write-Log "[OHS] stopping OHS component via stopComponent.cmd on $Global:FOU..."
try {
    $ohsStopPath = "D:\Oracle\Middleware\user_projects\epmsystem1\httpConfig\ohs\bin\stopComponent.cmd"
    $ohsStopName = $Global:OHSComponentName
    $fouShortName = $Global:FOU.Split('.')[0].ToUpper()

    if ($fouShortName -eq $localHost) {
        Start-Process -FilePath $ohsStopPath -ArgumentList $ohsStopName -NoNewWindow -Wait
    }
    else {
        Invoke-Command -ComputerName $Global:FOU -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
            param($path, $component)
            Start-Process -FilePath $path -ArgumentList $component -NoNewWindow -Wait
        } -ArgumentList $ohsStopPath, $ohsStopName -ErrorAction Stop
    }
    Write-Log "[OHS] OHS stopComponent.cmd executed." "SUCCESS"
    Start-Sleep -Seconds 10
}
catch {
    Write-Log "[OHS] stopComponent.cmd failed: $($_.Exception.Message) - continuing..." "WARN"
}

$failed = $false

for ($i = 0; $i -lt $StopSequence.Count; $i++) {
    $item   = $StopSequence[$i]
    $svc    = $item.Service
    $server = $item.Server
    $wait   = $item.Wait
    $desc   = $item.Desc
    $step   = $i + 1
    $total  = $StopSequence.Count

    Write-Log "[$step/$total] stopping $desc ($svc) on $server..."

    try {
        $svrShort = $server.Split('.')[0].ToUpper()

        if ($svrShort -eq $localHost) {
            $scResult = (sc.exe stop "$svc" 2>&1) -join ' '
        }
        else {
            $scResult = Invoke-Command -ComputerName $server -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
                param($s)
                sc.exe stop "$s" 2>&1
            } -ArgumentList $svc -ErrorAction Stop
            $scResult = ($scResult -join ' ')
        }

        if ($scResult -match "FAILED 1062") {
            Write-Log "[$step/$total] $desc already stopped." "SUCCESS"
        }
        elseif ($scResult -match "FAILED") {
            Write-Log "[$step/$total] $desc stop returned: $scResult" "WARN"
        }
        else {
            Write-Log "[$step/$total] $desc stop command sent." "SUCCESS"
        }
    }
    catch {
        Write-Log "[$step/$total] FAILED to stop $desc - $($_.Exception.Message)" "ERROR"
        $failed = $true
    }

    Write-Log "waiting ${wait}s..."
    Start-Sleep -Seconds $wait
}

# ============================================================================
# phase 3: kill stray processes
# ============================================================================

Write-Log ""
Write-Log "=============================================="
Write-Log "PHASE 3: killing stray processes"
Write-Log "=============================================="

Write-Log "killing XFMDataSource.exe on $Global:HFM..."
try {
    $hfmShort = $Global:HFM.Split('.')[0].ToUpper()
    if ($hfmShort -eq $localHost) {
        $procs = Get-Process -Name "XFMDataSource" -ErrorAction SilentlyContinue
        if ($procs) { $procs | Stop-Process -Force; Write-Log "XFMDataSource.exe killed." "SUCCESS" }
        else { Write-Log "XFMDataSource.exe not running." "SUCCESS" }
    }
    else {
        Invoke-Command -ComputerName $Global:HFM -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
            $procs = Get-Process -Name "XFMDataSource" -ErrorAction SilentlyContinue
            if ($procs) { $procs | Stop-Process -Force }
        } -ErrorAction Stop
        Write-Log "XFMDataSource.exe killed on $Global:HFM." "SUCCESS"
    }
}
catch {
    Write-Log "failed to kill XFMDataSource.exe: $($_.Exception.Message)" "WARN"
}

Write-Log "killing httpd.exe on $Global:FOU..."
try {
    $fouShort = $Global:FOU.Split('.')[0].ToUpper()
    if ($fouShort -eq $localHost) {
        $procs = Get-Process -Name "httpd" -ErrorAction SilentlyContinue
        if ($procs) { $procs | Stop-Process -Force; Write-Log "httpd.exe killed." "SUCCESS" }
        else { Write-Log "httpd.exe not running." "SUCCESS" }
    }
    else {
        Invoke-Command -ComputerName $Global:FOU -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
            $procs = Get-Process -Name "httpd" -ErrorAction SilentlyContinue
            if ($procs) { $procs | Stop-Process -Force }
        } -ErrorAction Stop
        Write-Log "httpd.exe killed on $Global:FOU." "SUCCESS"
    }
}
catch {
    Write-Log "failed to kill httpd.exe: $($_.Exception.Message)" "WARN"
}

# ============================================================================
# result
# ============================================================================

Write-Log ""
Write-Log "=============================================="
if ($failed) {
    Write-Log "hyperion dev shutdown FAILED - one or more services did not stop." "ERROR"
    Write-Log "log file: $Global:LogFile"
    Write-Log "=============================================="
    exit 1
}

Write-Log "hyperion dev shutdown complete." "SUCCESS"
Write-Log "log file: $Global:LogFile"
Write-Log "=============================================="
exit 0
