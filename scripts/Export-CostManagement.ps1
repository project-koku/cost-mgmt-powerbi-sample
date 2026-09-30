#Requires -Version 5.1
<#
.SYNOPSIS
Exports Red Hat Cost Management data to CSV for Power BI.

.DESCRIPTION
Dates use yyyy-MM-dd. -StartDate defaults to 30 days before today, local time. -EndDate defaults to yesterday, local time.
-ApiBaseUrl defaults to https://console.redhat.com.
-TokenUrl defaults to https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token.
-Scope defaults to api.console.
-TestProxy reports the system proxy and does not read auth.csv.
-Test checks the proxy, then the service account.

.PARAMETER Help
Print usage and exit. No auth file is read and no network call is made.

.PARAMETER TestProxy
Report the proxy choice for -TokenUrl and -ApiBaseUrl, then exit.

.PARAMETER StartDate
First day to request, yyyy-MM-dd.

.PARAMETER EndDate
Last day to request, yyyy-MM-dd.

.PARAMETER AuthFile
Path to auth.csv.

.PARAMETER OutDir
Directory for CSV output.

.PARAMETER Dataset
Optional dataset id. When omitted, every dataset is exported.

.PARAMETER ApiBaseUrl
Cost Management origin. Default: https://console.redhat.com.

.PARAMETER TokenUrl
Keycloak token endpoint. Default: https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token.

.PARAMETER Scope
OAuth scope. Default: api.console.

.EXAMPLE
powershell.exe -File scripts/Export-CostManagement.ps1

.EXAMPLE
powershell.exe -File scripts/Export-CostManagement.ps1 -Dataset OS_Costs_Daily

.EXAMPLE
powershell.exe -File scripts/Export-CostManagement.ps1 -TokenUrl https://keycloak.example.com/token -ApiBaseUrl https://cost.example.com

.EXAMPLE
powershell.exe -File scripts/Export-CostManagement.ps1 -TestProxy

.EXAMPLE
powershell.exe -File scripts/Export-CostManagement.ps1 -Test
#>
[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$TestProxy,
    [switch]$Test,
    [string]$StartDate,
    [string]$EndDate,
    [string]$AuthFile,
    [string]$OutDir,
    [string]$Dataset,
    [string]$ApiBaseUrl = 'https://console.redhat.com',
    [string]$TokenUrl = 'https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token',
    [string]$Scope = 'api.console'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CostManagementExport.ps1')

if ($Help) {
    Write-Output (Get-CostManagementHelpText)
    exit 0
}

if ($TestProxy -and -not $Test) {
    $proxyResult = Test-CostManagementProxy -TokenUrl $TokenUrl -ApiBaseUrl $ApiBaseUrl -GetProxy ${function:Get-CostManagementSystemProxy} -Connect ${function:Connect-CostManagementEndpoint}
    Write-Output $proxyResult.Message
    exit $proxyResult.ExitCode
}

if ($Test) {
    $gate = Invoke-CostManagementTest -TokenUrl $TokenUrl -ApiBaseUrl $ApiBaseUrl -GetProxy ${function:Get-CostManagementSystemProxy} -Connect ${function:Connect-CostManagementEndpoint} -ReadAuth {
        if (-not $AuthFile) {
            $AuthFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'data\auth.csv'
        }
        return @(Import-Csv -LiteralPath $AuthFile) | Select-Object -First 1
    }
    if ($gate.ExitCode -ne 0) {
        Write-Output $gate.Message
        exit 1
    }
    $result = Test-CostManagementCredentials -ClientId $gate.Auth.client_id -ClientSecret $gate.Auth.client_secret -ApiBaseUrl $ApiBaseUrl -TokenUrl $TokenUrl -Scope $Scope -Invoke ${function:Invoke-CostManagementWebRequest}
    Write-Output $gate.Message
    Write-Output $result.Message
    exit $result.ExitCode
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $AuthFile) { $AuthFile = Join-Path $repoRoot 'data\auth.csv' }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'data\export' }
if (-not $StartDate) { $StartDate = (Get-Date).Date.AddDays(-30).ToString('yyyy-MM-dd') }
if (-not $EndDate) { $EndDate = (Get-Date).Date.AddDays(-1).ToString('yyyy-MM-dd') }
$authRow = @(Import-Csv -LiteralPath $AuthFile) | Select-Object -First 1
Export-CostManagementData -StartDate $StartDate -EndDate $EndDate -ClientId $authRow.client_id -ClientSecret $authRow.client_secret -OutDir $OutDir -Dataset $Dataset -ApiBaseUrl $ApiBaseUrl -TokenUrl $TokenUrl -Scope $Scope -Invoke ${function:Invoke-CostManagementWebRequest} -Now { Get-Date } -Sleep { param($Seconds) Start-Sleep -Seconds $Seconds }
exit 0
