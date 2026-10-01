# .secrets.ps1
# hyperion epm credentials - dev
# keep this file out of source control
# note: replace with CyberArk or Azure Key Vault integration for UAT/PROD

if (-not $Global:HyperionSecrets) {
    $Global:HyperionSecrets = @{}
}

# windows service account - used for WinRM remote operations across all 3 servers
$Global:HyperionSecrets.WinRM = @{
    User     = "ADP1\SVC-CBU-Hyperion"
    Password = "ask pr0x1mo"
}

# essbase native account - used for MaxL validation
$Global:HyperionSecrets.Application = @{
    User     = "svc-maxl"
    Password = "ask pr0x1mo"
}

# repository (chi-dhypsql.adp1.cibc.pte) - uses integrated security, no credentials needed
$Global:HyperionSecrets.Repository = @{
    User     = ""
    Password = ""
}

# sql mi (dsql-canc-61856b-dev-01) - uses integrated security, no credentials needed
$Global:HyperionSecrets.SqlMi = @{
    User     = ""
    Password = ""
}

function Import-Secrets {
    $Global:RemoteCredential = New-Object System.Management.Automation.PSCredential(
        $Global:HyperionSecrets.WinRM.User,
        (ConvertTo-SecureString $Global:HyperionSecrets.WinRM.Password -AsPlainText -Force)
    )
    $Global:MaxLUser     = $Global:HyperionSecrets.Application.User
    $Global:MaxLPassword = $Global:HyperionSecrets.Application.Password
}
