# .functions.ps1
# hyperion epm reusable functions
# shared across start.ps1, stop.ps1, and healthcheck.ps1
# dot-source this file at the top of each script

function New-LogFile {
    param([string]$Prefix = "hyperion")
    $Global:LogFile = "$Global:LogDir\${Prefix}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    return $Global:LogFile
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "PASS"    { "Green" }
        "FAIL"    { "Red" }
        default   { "White" }
    }
    Write-Host $entry -ForegroundColor $color
    if ($Global:LogFile) { $entry | Out-File -Append -FilePath $Global:LogFile -Encoding UTF8 }
}

function Write-ConfigurationSummary {
    Write-Log "=============================================="
    Write-Log "Hyperion EPM - DEV Environment"
    Write-Log "Orchestrating from: $env:COMPUTERNAME"
    Write-Log "FOU: $Global:FOU"
    Write-Log "HFM: $Global:HFM"
    Write-Log "ESS: $Global:ESS"
    Write-Log "Repository: $($Global:HyperionConfig.Repository.Server)"
    Write-Log "SQL MI: $($Global:HyperionConfig.SqlMi.Server)"
    Write-Log "=============================================="
}

function Send-FailureAlert {
    param(
        [string]$FailedService,
        [string]$FailedServer,
        [int]$FailedStep,
        [int]$TotalSteps,
        [string[]]$StartedServices,
        [string[]]$SkippedServices,
        [string]$ErrorDetail,
        [string]$Phase = "SERVICE STARTUP"
    )

    $body = @"
$Phase FAILURE ALERT - HYPERION DEV
=============================
Orchestrating Server: $env:COMPUTERNAME
Failed Server:   $FailedServer
Time:            $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Failed Service:  $FailedService
Failed At Step:  $FailedStep of $TotalSteps
Error:           $ErrorDetail

STARTED SUCCESSFULLY:
$(if ($StartedServices.Count -gt 0) { ($StartedServices | ForEach-Object { "  [OK] $_" }) -join "`n" } else { "  (none)" })

NOT STARTED (halted):
$(if ($SkippedServices.Count -gt 0) { ($SkippedServices | ForEach-Object { "  [SKIPPED] $_" }) -join "`n" } else { "  (none)" })

ACTION REQUIRED: Investigate and manually start remaining services after resolving the failure.
Log file: $Global:LogFile
"@

    Write-Log "sending failure alert email..." "WARN"

    if ($Global:SendEmail) {
        try {
            Send-MailMessage -From $Global:EmailFrom -To $Global:EmailTo -Subject $Global:EmailSubject `
                -Body $body -SmtpServer $Global:SmtpServer -Priority High
            Write-Log "alert email sent to $($Global:EmailTo -join ', ')" "INFO"
        }
        catch {
            Write-Log "FAILED to send email alert: $_" "ERROR"
            Write-Log "alert body:`n$body" "ERROR"
        }
    }
    else {
        Write-Log "email disabled. alert body:`n$body" "WARN"
    }
}

function Test-HttpEndpoint {
    param([string]$Url)
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Timeout = 15000
        $request.Method = "GET"
        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $response.Close()
        return ($statusCode -lt 500)
    }
    catch {
        Write-Log "HTTP check failed for $Url - $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Test-RepositoryConnectivity {
    $server   = $Global:HyperionConfig.Repository.Server
    $database = $Global:HyperionConfig.Repository.Database
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$server,1433;Database=$database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
        $conn.Open()
        $conn.Close()
        Write-Log "Repository connectivity confirmed: $server ($database)" "PASS"
        return $true
    }
    catch {
        Write-Log "Repository connectivity FAILED: $server ($database) - $($_.Exception.Message)" "FAIL"
        return $false
    }
}

function Test-SqlMiDependency {
    $server   = $Global:HyperionConfig.SqlMi.Server
    $database = $Global:HyperionConfig.SqlMi.Database
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$server,1433;Database=$database;User ID=TPAdmin;Password={EncryptedPassword};Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
        $conn.Open()
        $conn.Close()
        Write-Log "SQL MI connectivity confirmed: $server ($database)" "PASS"
        return $true
    }
    catch {
        Write-Log "SQL MI connectivity FAILED: $server ($database) - $($_.Exception.Message)" "FAIL"
        return $false
    }
}

function Get-RemoteServiceStateText {
    param([string]$Server, [string]$ServiceName)
    try {
        $serverShortName = $Server.Split('.')[0].ToUpper()
        $localHost       = $env:COMPUTERNAME.ToUpper()

        if ($ServiceName -eq "EssbaseService") {
            if ($serverShortName -eq $localHost) {
                $proc = Get-Process -Name "EssbaseService" -ErrorAction SilentlyContinue
                if ($proc) { return "RUNNING" } else { return "STOPPED" }
            }
            else {
                $result = Invoke-Command -ComputerName $Server -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
                    $proc = Get-Process -Name "EssbaseService" -ErrorAction SilentlyContinue
                    if ($proc) { return "RUNNING" } else { return "STOPPED" }
                } -ErrorAction Stop
                return $result
            }
        }

        if ($serverShortName -eq $localHost) {
            $result = (sc.exe query "$ServiceName" 2>&1) -join ' '
        }
        else {
            $result = Invoke-Command -ComputerName $Server -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
                param($svc)
                sc.exe query "$svc" 2>&1
            } -ArgumentList $ServiceName -ErrorAction Stop
            $result = ($result -join ' ')
        }

        if ($result -match "STATE\s+:\s+4\s+RUNNING") { return "RUNNING" }
        if ($result -match "FAILED 1060") { return "NOT FOUND" }
        if ($result -match "FAILED 1722") { return "RPC ERROR" }
        return "STOPPED"
    }
    catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

function Test-HyperionNativeLogs {
    $logPath = $Global:HyperionConfig.NativeLogs.EssbaseLog
    $pattern = $Global:HyperionConfig.NativeLogs.Pattern
    try {
        $serverShortName = $Global:ESS.Split('.')[0].ToUpper()
        $localHost       = $env:COMPUTERNAME.ToUpper()

        if ($serverShortName -eq $localHost) {
            $match = Select-String -Path $logPath -Pattern $pattern -ErrorAction Stop | Select-Object -Last 1
        }
        else {
            $match = Invoke-Command -ComputerName $Global:ESS -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
                param($path, $pat)
                Select-String -Path $path -Pattern $pat -ErrorAction Stop | Select-Object -Last 1
            } -ArgumentList $logPath, $pattern -ErrorAction Stop
        }

        if ($match) {
            Write-Log "Native log check passed. Last RUNNING MODE entry: $($match.Line.Trim())" "PASS"
            return $true
        }
        else {
            Write-Log "Native log check: no RUNNING MODE entry found in Essbase log." "WARN"
            return $false
        }
    }
    catch {
        Write-Log "Native log check failed: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Get-ServiceStatus {
    param([string]$Server, [string]$ServiceName)
    return Get-RemoteServiceStateText -Server $Server -ServiceName $ServiceName
}

function Start-RemoteService {
    param([string]$Server, [string]$ServiceName, [int]$Timeout)

    $status = Get-ServiceStatus -Server $Server -ServiceName $ServiceName

    if ($status -eq "NOT FOUND") { throw "service '$ServiceName' not found on $Server" }
    if ($status -eq "RPC ERROR") { throw "cannot reach $Server via RPC" }
    if ($status -eq "RUNNING")   { return "ALREADY_RUNNING" }

    $serverShortName = $Server.Split('.')[0].ToUpper()
    $localHost       = $env:COMPUTERNAME.ToUpper()

    if ($serverShortName -eq $localHost) {
        $scResult = (sc.exe start "$ServiceName" 2>&1) -join ' '
    }
    else {
        $scResult = Invoke-Command -ComputerName $Server -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
            param($svc)
            sc.exe start "$svc" 2>&1
        } -ArgumentList $ServiceName -ErrorAction Stop
        $scResult = ($scResult -join ' ')
    }

    if ($scResult -match "FAILED" -and $scResult -notmatch "1056") {
        throw "failed to start '$ServiceName' on $Server - $scResult"
    }

    if ($ServiceName -eq "EssbaseService") {
        Write-Log "EssbaseService started. skipping state polling due to known oracle 11.2.25 reporting bug. status.cmd will validate." "WARN"
        return "STARTED"
    }

    $elapsed = 0
    $pollInterval = 5
    while ($elapsed -lt $Timeout) {
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
        if ((Get-ServiceStatus -Server $Server -ServiceName $ServiceName) -eq "RUNNING") { return "STARTED" }
    }

    throw "service '$ServiceName' on $Server did not reach Running within ${Timeout}s"
}

function Invoke-OHSStartComponent {
    param([string]$Server, [string]$Path, [string]$Component, [int]$WaitSeconds)

    $serverShortName = $Server.Split('.')[0].ToUpper()
    $localHost       = $env:COMPUTERNAME.ToUpper()

    if ($serverShortName -eq $localHost) {
        Start-Process -FilePath $Path -ArgumentList $Component -NoNewWindow -Wait
    }
    else {
        Invoke-Command -ComputerName $Server -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
            param($path, $component)
            Start-Process -FilePath $path -ArgumentList $component -NoNewWindow -Wait
        } -ArgumentList $Path, $Component -ErrorAction Stop
    }

    Write-Log "OHS startComponent.cmd executed. waiting ${WaitSeconds}s..." "SUCCESS"
    Start-Sleep -Seconds $WaitSeconds
}

function Invoke-EssbaseStatusCheck {
    param([string]$Server, [int]$MaxWaitSeconds = 600)

    $serverShortName = $Server.Split('.')[0].ToUpper()
    $localHost       = $env:COMPUTERNAME.ToUpper()
    $isLocal         = $serverShortName -eq $localHost

    Write-Log "running status.cmd on $Server to verify essbase_server1 is RUNNING..."
    $elapsed = 0
    $pollInterval = 30

    while ($elapsed -lt $MaxWaitSeconds) {
        if ($isLocal) {
            $result = & $Global:StatusCmdPath 2>&1
        }
        else {
            $result = Invoke-Command -ComputerName $Server -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
                param($cmd)
                & $cmd 2>&1
            } -ArgumentList $Global:StatusCmdPath -ErrorAction Stop
        }

        $output = ($result | ForEach-Object { "$_" }) -join "`n"
        Write-Log "status.cmd output:`n$output"

        $essbaseServerLine = ($output -split "`n") | Where-Object { $_ -match "essbase_server1" }
        if ($essbaseServerLine -match "RUNNING") {
            Write-Log "essbase_server1 confirmed RUNNING via status.cmd." "SUCCESS"
            return $true
        }

        Write-Log "essbase_server1 not RUNNING yet. waiting ${pollInterval}s... (${elapsed}s elapsed of ${MaxWaitSeconds}s max)"
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
    }

    return $false
}

function Invoke-MaxLValidation {
    param([string]$Server, [string]$ValidationLog)

    $serverShortName = $Server.Split('.')[0].ToUpper()
    $localHost       = $env:COMPUTERNAME.ToUpper()
    $isLocal         = $serverShortName -eq $localHost

    $maxlContent = @"
login $($Global:MaxLUser) identified by '$($Global:MaxLPassword)' on localhost;
display system version;
display application all;
logout;
exit;
"@

    if ($isLocal) {
        $maxlContent | Out-File -FilePath $Global:MaxLScript -Encoding ASCII
        $maxlResult = & $Global:MaxLPath $Global:MaxLScript 2>&1
    }
    else {
        $maxlResult = Invoke-Command -ComputerName $Server -Credential $Global:RemoteCredential -HideComputerName -ScriptBlock {
            param($maxl, $script, $content)
            $content | Out-File -FilePath $script -Encoding ASCII
            & $maxl $script 2>&1
        } -ArgumentList $Global:MaxLPath, $Global:MaxLScript, $maxlContent -ErrorAction Stop
    }

    $maxlResult | Out-File -FilePath $ValidationLog -Encoding UTF8
    return ($maxlResult | ForEach-Object { "$_" }) -join "`n"
}
