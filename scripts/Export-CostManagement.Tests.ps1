$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CostManagementExport.ps1')

$script:Failed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        Write-Host "PASS $Name"
    } else {
        Write-Host "FAIL $Name"
        $script:Failed++
    }
}

$help = Get-CostManagementHelpText
Assert-True 'help mentions yyyy-MM-dd' ($help -match 'yyyy-MM-dd')
foreach ($id in (Get-CostManagementDatasetIds)) {
    Assert-True "help lists $id" ($help -like "*$id*")
}
Assert-True 'help shows saas api default' ($help -match 'https://console.redhat.com')
Assert-True 'help shows token default' ($help -match 'openid-connect/token')
Assert-True 'help shows on-prem example' ($help -match '-TokenUrl' -and $help -match '-ApiBaseUrl')
Assert-True 'help mentions Test' ($help -match '-Test')
Assert-True 'help mentions TestProxy' ($help -match '-TestProxy')

Assert-True 'null field is empty' ((ConvertTo-CostManagementField $null) -eq '')
Assert-True 'null list is empty' ((ConvertTo-CostManagementField @($null, 'a')) -eq 'a')
$tmp = Join-Path $env:TEMP ("cm-csv-" + [guid]::NewGuid().ToString() + '.csv')
Write-CostManagementCsv -Path $tmp -Header @('Name','values.source_uuid') -Rows @(
    [ordered]@{ Name = 'web'; 'values.source_uuid' = $null }
)
$bytes = [IO.File]::ReadAllBytes($tmp)
Assert-True 'csv has utf-8 bom' ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$text = [IO.File]::ReadAllText($tmp)
Assert-True 'csv header and empty null' ($text -match 'Name,values.source_uuid' -and $text -match 'web,')
Remove-Item $tmp

$entry = Join-Path $PSScriptRoot 'Export-CostManagement.ps1'
$out = & powershell.exe -NoProfile -File $entry -Help
Assert-True 'help switch exit 0' ($LASTEXITCODE -eq 0)
Assert-True 'help switch prints a dataset' ($out -join "`n" -match 'OS_Costs_Daily')

$script:TokenCalls = 0
$script:TokenUris = @()
$script:TokenBodies = @()
$script:Clock = [datetime]'2026-09-01T00:00:00Z'
$tokenInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $script:TokenCalls++
    $script:TokenUris += [string]$Uri
    $script:TokenBodies += [string]$Body
    $token = 'tok-1'
    if ($script:TokenCalls -gt 1) { $token = 'tok-2' }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = $token; expires_in = 300 } }
}
$tokenSession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'client-id' -ClientSecret 'client-secret-value' -Scope 'api.console' -Invoke $tokenInvoke -Now { $script:Clock }
$firstToken = Get-CostManagementAccessToken -Session $tokenSession
Assert-True 'first token uri' ($script:TokenUris[0] -eq 'https://keycloak.example.com/token')
Assert-True 'body has grant' ($script:TokenBodies[0] -match 'grant_type=client_credentials')
Assert-True 'body has scope' ($script:TokenBodies[0] -match 'scope=api.console')
Assert-True 'body has client id' ($script:TokenBodies[0] -match 'client_id=client-id')
Assert-True 'token body is not logged' ($null -eq $tokenSession.Log)
Assert-True 'first token' ($firstToken -eq 'tok-1')
$script:Clock = $script:Clock.AddMinutes(5)
$secondToken = Get-CostManagementAccessToken -Session $tokenSession
Assert-True 'refreshed token' ($secondToken -eq 'tok-2')

$rejectedInvoke = {
    param($Method, $Uri, $Headers, $Body)
    return [pscustomobject]@{ StatusCode = 401; Json = $null }
}
$rejected = Test-CostManagementCredentials -ClientId 'id' -ClientSecret 'client-secret-value' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $rejectedInvoke
Assert-True 'rejected exit' ($rejected.ExitCode -eq 1)
Assert-True 'rejected message' ($rejected.Message.StartsWith('credentials: rejected'))
Assert-True 'rejected hides secret' (($rejected.Message -notmatch 'client-secret-value') -and ($rejected.Message -notmatch 'access_token'))

$script:DeniedUris = @()
$deniedInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $script:DeniedUris += [string]$Uri
    if ([string]$Uri -like '*/token') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' } }
    }
    return [pscustomobject]@{ StatusCode = 403; Json = $null }
}
$denied = Test-CostManagementCredentials -ClientId 'id' -ClientSecret 'client-secret-value' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $deniedInvoke
Assert-True 'denied message' ($denied.Message.StartsWith('permissions: denied'))
Assert-True 'denied settings uri' ($script:DeniedUris -contains 'https://cost.example.com/api/cost-management/v1/account-settings/')
Assert-True 'denied hides secret' (($denied.Message -notmatch 'client-secret-value') -and ($denied.Message -notmatch 'access_token'))

$acceptedInvoke = {
    param($Method, $Uri, $Headers, $Body)
    if ([string]$Uri -like '*/token') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' } }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{} }
}
$accepted = Test-CostManagementCredentials -ClientId 'id' -ClientSecret 'client-secret-value' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $acceptedInvoke
Assert-True 'accepted exit' ($accepted.ExitCode -eq 0)
Assert-True 'accepted message' ($accepted.Message.StartsWith('credentials: accepted'))
Assert-True 'accepted hides secret' (($accepted.Message -notmatch 'client-secret-value') -and ($accepted.Message -notmatch 'access_token'))

$disconnectInvoke = {
    param($Method, $Uri, $Headers, $Body)
    throw 'no route'
}
$disconnected = Test-CostManagementCredentials -ClientId 'id' -ClientSecret 'client-secret-value' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $disconnectInvoke
Assert-True 'connection message' ($disconnected.Message.StartsWith('connection: failed'))
Assert-True 'connection hides secret' (($disconnected.Message -notmatch 'client-secret-value') -and ($disconnected.Message -notmatch 'access_token'))

$helpAndTest = & powershell.exe -NoProfile -File $entry -Help -Test
Assert-True 'help wins over test' ($LASTEXITCODE -eq 0)
Assert-True 'help wins prints dates' (($helpAndTest -join "`n") -match 'yyyy-MM-dd')

$directProxy = Test-CostManagementProxy -TokenUrl 'https://keycloak.example.com/token' -ApiBaseUrl 'https://cost.example.com' -GetProxy { param($Uri) return $null } -Connect { param($Uri, $ProxyUri) return 200 }
$directLines = $directProxy.Message -split "`r?`n"
Assert-True 'proxy direct token' ($directLines[0] -eq 'proxy token: direct')
Assert-True 'proxy direct api' ($directLines[1] -eq 'proxy api: direct')
Assert-True 'proxy direct exit' ($directProxy.ExitCode -eq 0)

$bypassProxy = Test-CostManagementProxy -TokenUrl 'https://keycloak.example.com/token' -ApiBaseUrl 'https://cost.example.com' -GetProxy {
    param($Uri)
    if ([string]$Uri -like '*keycloak*') { return [pscustomobject]@{ Bypassed = $true; Proxy = $null } }
    return $null
} -Connect { param($Uri, $ProxyUri) return 200 }
Assert-True 'proxy bypass token' ((($bypassProxy.Message -split "`r?`n")[0]) -eq 'proxy token: bypassed')

$userInfoProxy = Test-CostManagementProxy -TokenUrl 'https://keycloak.example.com/token' -ApiBaseUrl 'https://cost.example.com' -GetProxy {
    param($Uri)
    return 'http://user:secret@proxy.example.com:8080'
} -Connect { param($Uri, $ProxyUri) return 200 }
Assert-True 'proxy prints host' ($userInfoProxy.Message -match 'http://proxy.example.com:8080')
Assert-True 'proxy hides userinfo' ($userInfoProxy.Message -notmatch 'user:secret')

$failedProxy = Test-CostManagementProxy -TokenUrl 'https://keycloak.example.com/token' -ApiBaseUrl 'https://cost.example.com' -GetProxy {
    param($Uri)
    return 'http://user:secret@proxy.example.com:8080'
} -Connect { param($Uri, $ProxyUri) throw 'proxy down' }
Assert-True 'proxy failed token' ((($failedProxy.Message -split "`r?`n")[0]) -eq 'proxy token: failed http://proxy.example.com:8080')
Assert-True 'proxy failed exit' ($failedProxy.ExitCode -eq 1)
$script:ProxyAuthReads = 0
Invoke-CostManagementTest -TokenUrl 'https://keycloak.example.com/token' -ApiBaseUrl 'https://cost.example.com' -GetProxy {
    param($Uri)
    return 'http://proxy.example.com:8080'
} -Connect { param($Uri, $ProxyUri) throw 'proxy down' } -ReadAuth { $script:ProxyAuthReads++ }
Assert-True 'failed proxy skips auth' ($script:ProxyAuthReads -eq 0)

$helpProxy = & powershell.exe -NoProfile -File $entry -Help -TestProxy
Assert-True 'help wins over testproxy' ($LASTEXITCODE -eq 0)

$script:PageOffsets = @()
$pageRows = Get-CostManagementPages -GetPage {
    param([int]$Offset)
    $script:PageOffsets += $Offset
    if ($Offset -eq 0) { return [pscustomobject]@{ Count = 250; Data = @(1..100) } }
    if ($Offset -eq 100) { return [pscustomobject]@{ Count = 250; Data = @(1..100) } }
    return [pscustomobject]@{ Count = 250; Data = @(1..50) }
}
Assert-True 'page offsets' (($script:PageOffsets -join ',') -eq '0,100,200')
Assert-True 'page row count' (@($pageRows).Count -eq 250)

$script:Sleeps = @()
$script:OneDayCalls = 0
$oneDayInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $script:OneDayCalls++
    return [pscustomobject]@{ StatusCode = 500; Json = $null; Body = 'unavailable' }
}
$oneDaySession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke $oneDayInvoke -Now { Get-Date }
$oneDaySession.AccessToken = 'tok'
$oneDaySession.IssuedAt = Get-Date
$oneDayThrew = $false
try {
    Get-CostManagementWindowData -StartDate ([datetime]'2026-09-01') -EndDate ([datetime]'2026-09-01') -ApiBaseUrl 'https://cost.example.com' -RelativeUrl '/api/cost-management/v1/reports/openshift/costs/' -Session $oneDaySession -Invoke $oneDayInvoke -Sleep { param($Seconds) $script:Sleeps += $Seconds }
} catch {
    $oneDayThrew = $true
}
Assert-True 'one day 500 throws' $oneDayThrew
Assert-True 'one day slept 2 4 8' (($script:Sleeps -join ',') -eq '2,4,8')

$script:BadWindowUrls = @()
$badWindowInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $script:BadWindowUrls += [string]$Uri
    return [pscustomobject]@{ StatusCode = 400; Json = $null; Body = 'bad request' }
}
$badWindowSession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke $badWindowInvoke -Now { Get-Date }
$badWindowSession.AccessToken = 'tok'
$badWindowSession.IssuedAt = Get-Date
$badWindowThrew = $false
try {
    Get-CostManagementWindowData -StartDate ([datetime]'2026-09-01') -EndDate ([datetime]'2026-09-04') -ApiBaseUrl 'https://cost.example.com' -RelativeUrl '/api/cost-management/v1/reports/openshift/costs/' -Session $badWindowSession -Invoke $badWindowInvoke -Sleep { }
} catch {
    $badWindowThrew = $true
}
Assert-True 'http 400 throws' $badWindowThrew
$badWindowJoined = $script:BadWindowUrls -join "`n"
Assert-True 'http 400 calls the full window' ($badWindowJoined.Contains('start_date=2026-09-01') -and $badWindowJoined.Contains('end_date=2026-09-04'))
Assert-True 'http 400 is not split' (-not $badWindowJoined.Contains('end_date=2026-09-02'))

$script:HalfCalls = @()
$halfInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $text = [string]$Uri
    $script:HalfCalls += $text
    if ($text -like '*start_date=2026-09-01*' -and $text -like '*end_date=2026-09-04*') {
        return [pscustomobject]@{ StatusCode = 500; Json = $null; Body = 'unavailable' }
    }
    $day = '2026-09-01'
    if ($text -like '*start_date=2026-09-03*') { $day = '2026-09-03' }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ date = $day }); meta = @{ count = 1 } }; Body = '' }
}
$halfSession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke $halfInvoke -Now { Get-Date }
$halfSession.AccessToken = 'tok'
$halfSession.IssuedAt = Get-Date
$halfRows = @(Get-CostManagementWindowData -StartDate ([datetime]'2026-09-01') -EndDate ([datetime]'2026-09-04') -ApiBaseUrl 'https://cost.example.com' -RelativeUrl '/api/cost-management/v1/reports/openshift/costs/' -Session $halfSession -Invoke $halfInvoke -Sleep { })
Assert-True 'halves in date order' (($halfRows[0].date -eq '2026-09-01') -and ($halfRows[1].date -eq '2026-09-03'))

$script:Auth401 = @()
$invoke401 = {
    param($Method, $Uri, $Headers, $Body)
    $script:Auth401 += [string]$Uri
    if ([string]$Uri -like '*/token') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok-2' }; Body = '' }
    }
    $apiHits = @($script:Auth401 | Where-Object { $_ -like '*reports/openshift/costs/*' })
    if ($apiHits.Count -le 1) {
        return [pscustomobject]@{ StatusCode = 401; Json = $null; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$session401 = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke $invoke401 -Now { Get-Date }
$session401.AccessToken = 'tok-1'
$session401.IssuedAt = Get-Date
Invoke-CostManagementGet -ApiBaseUrl 'https://cost.example.com' -RelativeUrl '/api/cost-management/v1/reports/openshift/costs/?filter[limit]=100' -Session $session401 -Invoke $invoke401 -Sleep { } | Out-Null
$apiUrls = @($script:Auth401 | Where-Object { $_ -like '*reports/openshift/costs/*' })
$tokenUrls = @($script:Auth401 | Where-Object { $_ -like '*/token' })
Assert-True '401 retried same api url' ($apiUrls.Count -eq 2 -and $apiUrls[0] -eq $apiUrls[1])
Assert-True '401 refresh uses token url' ($tokenUrls.Count -eq 1 -and $tokenUrls[0] -eq 'https://keycloak.example.com/token')
Assert-True '401 refresh avoids console host' (($tokenUrls -join ' ') -notmatch 'console.redhat.com')

$script:Joined = @()
$joinInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $script:Joined += [string]$Uri
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$joinSession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke $joinInvoke -Now { Get-Date }
$joinSession.AccessToken = 'tok'
$joinSession.IssuedAt = Get-Date
Invoke-CostManagementGet -ApiBaseUrl 'https://cost.example.com' -RelativeUrl '/api/cost-management/v1/reports/openshift/costs/?filter[limit]=100' -Session $joinSession -Invoke $joinInvoke -Sleep { } | Out-Null
Assert-True 'get joins base and path' ($script:Joined[0] -eq 'https://cost.example.com/api/cost-management/v1/reports/openshift/costs/?filter[limit]=100')

$header = Get-CostManagementSchemaHeader 'OS_Costs_Daily'
Assert-True 'os costs has source_uuid' ($header -contains 'values.source_uuid')
Assert-True 'os costs has clusters' ($header -contains 'values.clusters')
Assert-True 'static group by file exists' (Test-Path (Join-Path (Get-CostManagementRepoRoot) 'data/static/OpenShift_Group_Bys.csv'))
$overhead = Get-Content -Raw (Join-Path (Get-CostManagementRepoRoot) 'data/static/Project_Overhead_Cost_Types.csv')
Assert-True 'overhead keeps two spaces' ($overhead.Contains("Don't distribute  overhead costs"))

$value = [pscustomobject]@{
    date = '2026-09-01'
    classification = 'OpenShift'
    source_uuid = @($null, 'uuid-1')
    clusters = $null
    infrastructure = [pscustomobject]@{ total = [pscustomobject]@{ value = 1.5; units = 'USD' } }
    supplementary = $null
    cost = [pscustomobject]@{ total = [pscustomobject]@{ value = 2; units = 'USD' } }
    delta_percent = $null
}
$row = ConvertTo-OpenShiftCostRow -CurrencyCode 'USD' -GroupByCode 'project' -DistributedOverhead $false -Day '2026-09-01' -Name 'web' -ValueRecord $value -TagKey $null
Assert-True 'source_uuid drops null item' ($row['values.source_uuid'] -eq 'uuid-1')
Assert-True 'clusters null is empty' ($row['values.clusters'] -eq '')
Assert-True 'missing markup is empty' ($row['values.infrastructure.markup.value'] -eq '')

$publishDir = Join-Path $env:TEMP ("cm-publish-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $publishDir | Out-Null
$publishHeader = Get-CostManagementSchemaHeader 'OS_Costs_Daily'
Publish-CostManagementDataset -OutDir $publishDir -DatasetId 'OS_Costs_Daily' -Header $publishHeader -Rows @($row)
$published = Get-Content -Raw (Join-Path $publishDir 'OS_Costs_Daily.csv')
$publishThrew = $false
try {
    Publish-CostManagementDataset -OutDir $publishDir -DatasetId 'OS_Costs_Daily' -Header $publishHeader -Rows { throw 'stop before rows' }
} catch {
    $publishThrew = $true
}
Assert-True 'publish throw is caught by test' $publishThrew
Assert-True 'previous csv kept' ((Get-Content -Raw (Join-Path $publishDir 'OS_Costs_Daily.csv')) -eq $published)
Remove-Item $publishDir -Recurse -Force

$settingsDir = Join-Path $env:TEMP ("cm-settings-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $settingsDir | Out-Null
$settingsInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD'; name = 'US Dollar'; symbol = '$'; description = 'United States dollar' }) }; Body = '' }
    }
    if ($u -like '*/account-settings/*') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $settingsDir -Dataset 'Default_Master_Settings' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $settingsInvoke -Now { Get-Date } -Sleep { }
$settingsRow = Import-Csv (Join-Path $settingsDir 'Default_Master_Settings.csv')
Assert-True 'settings currency code' ($settingsRow.code -eq 'USD')
Assert-True 'settings cost type' ($settingsRow.'Default_Configurations.data.cost_type' -eq 'calculated')
Assert-True 'data period written with one dataset' ((Get-Content -Raw (Join-Path $settingsDir 'Data_Period.csv')) -match '2026-09-01')
Remove-Item $settingsDir -Recurse -Force

$script:CostUrls = @()
$costDir = Join-Path $env:TEMP ("cm-cost-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $costDir | Out-Null
$costInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD'; name = 'US Dollar'; symbol = '$'; description = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u -like '*/tags/openshift/*' -and -not $u.Contains('filter[project]=')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' } }
    if ($u -like '*reports/openshift/costs/*') {
        $script:CostUrls += $u
        if (-not $u.Contains('group_by[project]')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' } }
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ project = 'web'; values = @(@{ date = '2026-09-01'; source_uuid = @($null, 'uuid-1'); clusters = $null; infrastructure = @{ total = @{ value = 1.5; units = 'USD' } }; cost = @{ total = @{ value = 2; units = 'USD' } } }) }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-01' -ClientId 'id' -ClientSecret 'secret' -OutDir $costDir -Dataset 'OS_Costs_Daily' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $costInvoke -Now { Get-Date } -Sleep { }
$costRow = Import-Csv (Join-Path $costDir 'OS_Costs_Daily.csv')
Assert-True 'cost source uuid' ($costRow.'values.source_uuid' -eq 'uuid-1')
Assert-True 'cost host' (@($script:CostUrls | Where-Object { $_.StartsWith('https://cost.example.com/api/cost-management/v1/reports/openshift/costs/') }).Count -ge 1)
Remove-Item $costDir -Recurse -Force

$tagCostDir = Join-Path $env:TEMP ("cm-tag-cost-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tagCostDir | Out-Null
$tagCostInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD'; name = 'US Dollar'; symbol = '$'; description = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u -like '*/tags/openshift/*' -and -not $u.Contains('filter[project]=')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ key = 'env'; enabled = $true }); meta = @{ count = 1 } }; Body = '' } }
    if ($u -like '*reports/openshift/costs/*' -and $u.Contains('group_by[tag:env]')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-09-02'; envs = @(@{ env = 'prod'; values = @(@{ date = '2026-09-02'; cost = @{ total = @{ value = 4; units = 'USD' } } }) }) }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-02' -ClientId 'id' -ClientSecret 'secret' -OutDir $tagCostDir -Dataset 'OS_Costs_Daily' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $tagCostInvoke -Now { Get-Date } -Sleep { }
$tagCostRows = @(Import-Csv (Join-Path $tagCostDir 'OS_Costs_Daily.csv'))
$tagCostRow = $tagCostRows | Where-Object { $_.'Group By Code' -eq 'tag' } | Select-Object -First 1
Assert-True 'tag cost row written' ($null -ne $tagCostRow)
Assert-True 'tag cost key' ($tagCostRow.key -eq 'env')
Assert-True 'tag cost value name' ($tagCostRow.Name -eq 'prod')
Assert-True 'tag cost total' ($tagCostRow.'values.cost.total.value' -eq '4')
Remove-Item $tagCostDir -Recurse -Force

$tagDir = Join-Path $env:TEMP ("cm-tags-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tagDir | Out-Null
$tagInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u.Contains('filter[project]=web')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ key = 'env'; enabled = $true; values = @('prod') }); meta = @{ count = 1 } }; Body = '' } }
    if ($u.Contains('group_by[project]')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ project = 'web'; values = @(@{ date = '2026-09-30' }) }) }; Body = '' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $tagDir -Dataset 'OS_Cost_Project_Tags' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $tagInvoke -Now { Get-Date } -Sleep { }
$tagRow = Import-Csv (Join-Path $tagDir 'OS_Cost_Project_Tags.csv')
Assert-True 'filter month is 2026-9' ($tagRow.'Filter Month' -eq '2026-9')
Remove-Item $tagDir -Recurse -Force

$recDir = Join-Path $env:TEMP ("cm-rec-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $recDir | Out-Null
$recInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*recommendations/openshift*') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ cluster_uuid = 'cu-1'; short_term = $null; recommendations = @{ short_term = $null } }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-01' -ClientId 'id' -ClientSecret 'secret' -OutDir $recDir -Dataset 'Recommendations' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $recInvoke -Now { Get-Date } -Sleep { }
$recRow = Import-Csv (Join-Path $recDir 'Recommendations.csv')
Assert-True 'recommendation cluster uuid' ($recRow.cluster_uuid -eq 'cu-1')
Assert-True 'null short term is empty' ($recRow.'ST Rec Cost Config' -eq '')
Remove-Item $recDir -Recurse -Force

$recShapeDir = Join-Path $env:TEMP ("cm-rec-shape-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $recShapeDir | Out-Null
$recShapeInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*recommendations/openshift*') {
        $config = {
            param($cpu, $memory)
            return @{
                limits = @{ cpu = @{ amount = $cpu; format = 'cores' }; memory = @{ amount = $memory; format = 'Mi' } }
                requests = @{ cpu = @{ amount = $cpu; format = 'cores' }; memory = @{ amount = $memory; format = 'Mi' } }
            }
        }
        $term = {
            param($hours, $cpu, $memory)
            return @{
                duration_in_hours = $hours
                monitoring_start_time = '2026-09-01T00:00:00Z'
                recommendation_engines = @{
                    cost = @{ config = (& $config $cpu $memory) }
                    performance = @{ config = (& $config ($cpu + 1) $memory) }
                }
            }
        }
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{
            cluster_uuid = 'cu-2'
            last_reported = '2026-09-05T12:00:00Z'
            recommendations = @{
                monitoring_end_time = '2026-09-05T00:00:00Z'
                current = (& $config 2 512)
                recommendation_terms = @{
                    short_term = (& $term 24 1 256)
                    medium_term = (& $term 168 3 1024)
                }
            }
        }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-01' -ClientId 'id' -ClientSecret 'secret' -OutDir $recShapeDir -Dataset 'Recommendations' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $recShapeInvoke -Now { Get-Date } -Sleep { }
$recShape = Import-Csv (Join-Path $recShapeDir 'Recommendations.csv')
Assert-True 'recommendation renames last reported' ($recShape.last_reported_time -eq '2026-09-05T12:00:00Z')
Assert-True 'recommendation monitoring end' ($recShape.monitoring_end_time -eq '2026-09-05T00:00:00Z')
Assert-True 'recommendation current configuration' ($recShape.'Current configuration' -eq "limits:          cpu: 2cores      memory: 512Mi`nrequests:     cpu: 2cores     memory: 512Mi")
Assert-True 'recommendation short term duration' ($recShape.'st.duration_in_hours' -eq '24')
Assert-True 'recommendation short term cost' ($recShape.'ST Rec Cost Config' -eq "limits:           cpu: 1cores     memory: 256Mi`nrequests:     cpu: 1cores     memory: 256Mi")
Assert-True 'recommendation short term performance' ($recShape.'ST Rec Perf Config' -eq "limits:         cpu: 2cores    memory: 256Mi`nrequests:   cpu: 2cores    memory: 256Mi")
Assert-True 'recommendation medium term duration' ($recShape.'mt.duration_in_hours' -eq '168')
Assert-True 'recommendation long term stays empty' ($recShape.'LT Rec Cost Config' -eq '' -and $recShape.'lt.duration_in_hours' -eq '')
Remove-Item $recShapeDir -Recurse -Force

$failDir = Join-Path $env:TEMP ("cm-export-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $failDir | Out-Null
$previous = "previous-row`n"
Set-Content -Path (Join-Path $failDir 'OS_Costs_Daily.csv') -Value $previous -NoNewline
$failInvoke = {
    param($Method, $Uri, $Headers, $Body)
    if ([string]$Uri -like '*/token') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok'; expires_in = 300 }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 500; Json = $null; Body = 'unavailable' }
}
try {
    Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-01' -ClientId 'id' -ClientSecret 'secret' -OutDir $failDir -Dataset 'OS_Costs_Daily' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $failInvoke -Now { Get-Date } -Sleep { }
    Assert-True 'failed day throws' $false
} catch {
    Assert-True 'failed day throws' $true
}
Assert-True 'failed day keeps previous csv' ((Get-Content -Raw (Join-Path $failDir 'OS_Costs_Daily.csv')) -eq $previous)
Assert-True 'log has status 500' ((Get-Content -Raw (Join-Path $failDir 'export.log')) -match 'status=500')
Remove-Item $failDir -Recurse -Force

$awsDir = Join-Path $env:TEMP ("cm-aws-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $awsDir | Out-Null
$script:AwsCostUrls = @()
$awsInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('/tags/aws/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ key = 'env' }); meta = @{ count = 1 } }; Body = '' } }
    if ($u.Contains('/aws-categories/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ key = 'CostCenter' }); meta = @{ count = 1 } }; Body = '' } }
    if ($u.Contains('/organizations/aws/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ org_unit_id = 'r-f22a' }); meta = @{ count = 1 } }; Body = '' } }
    if ($u.Contains('/reports/aws/costs/')) {
        $script:AwsCostUrls += $u
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-01' -ClientId 'id' -ClientSecret 'secret' -OutDir $awsDir -Dataset 'AWS_Daily_Costs' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $awsInvoke -Now { Get-Date } -Sleep { }
$awsJoined = $script:AwsCostUrls -join "`n"
Assert-True 'aws account group' ($awsJoined.Contains('group_by[account]=*'))
Assert-True 'aws tag group' ($awsJoined.Contains('group_by[tag:env]=*'))
Assert-True 'aws category group' ($awsJoined.Contains('group_by[aws_category:CostCenter]=*'))
Assert-True 'aws org group' ($awsJoined.Contains('group_by[org_unit_id]=r-f22a'))
Remove-Item $awsDir -Recurse -Force

$orgDenySession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke { param($Method, $Uri, $Headers, $Body) return [pscustomobject]@{ StatusCode = 403; Json = $null; Body = 'denied' } } -Now { Get-Date }
$orgDenySession.AccessToken = 'tok'
$orgDenySession.IssuedAt = Get-Date
$orgDenyThrew = $false
try {
    Get-CostManagementOrgRows -ApiBaseUrl 'https://cost.example.com' -Session $orgDenySession -Invoke { param($Method, $Uri, $Headers, $Body) return [pscustomobject]@{ StatusCode = 403; Json = $null; Body = 'denied' } } -Sleep { } -StartDate ([datetime]'2026-09-01') -EndDate ([datetime]'2026-09-01')
} catch {
    $orgDenyThrew = $true
}
Assert-True 'org 403 throws' $orgDenyThrew

$script:OrgCostUrls = @()
$orgCostInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('/tags/aws/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' } }
    if ($u.Contains('/aws-categories/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' } }
    if ($u.Contains('/organizations/aws/')) { return [pscustomobject]@{ StatusCode = 403; Json = $null; Body = 'denied' } }
    if ($u.Contains('/reports/aws/costs/')) { $script:OrgCostUrls += $u }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$orgCostSession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke $orgCostInvoke -Now { Get-Date }
$orgCostSession.AccessToken = 'tok'
$orgCostSession.IssuedAt = Get-Date
$orgCostThrew = $false
try {
    Get-CostManagementAwsCostRows -ApiBaseUrl 'https://cost.example.com' -Session $orgCostSession -Invoke $orgCostInvoke -Sleep { } -StartDate ([datetime]'2026-09-01') -EndDate ([datetime]'2026-09-01')
} catch {
    $orgCostThrew = $true
}
Assert-True 'aws org 403 throws' $orgCostThrew
Assert-True 'aws org 403 skips cost calls' ($script:OrgCostUrls.Count -eq 0)

$usageDir = Join-Path $env:TEMP ("cm-usage-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $usageDir | Out-Null
$script:UsageUrls = @()
$usageInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('/tags/openshift/') -and -not $u.Contains('filter[project]=')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ key = 'env' }); meta = @{ count = 1 } }; Body = '' } }
    if ($u.Contains('/reports/openshift/')) {
        $script:UsageUrls += $u
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-01' -ClientId 'id' -ClientSecret 'secret' -OutDir $usageDir -Dataset 'OS_Daily_Usage' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $usageInvoke -Now { Get-Date } -Sleep { }
Assert-True 'usage tag group' (($script:UsageUrls -join "`n").Contains('group_by[tag:env]=*'))
Remove-Item $usageDir -Recurse -Force

$nestedDays = @(
    @{
        date = '2026-08-15'
        projects = @(@{
            project = 'web'
            values = @(@{ date = '2026-08-15'; source_uuid = @('uuid-aug'); cost = @{ total = @{ value = 8; units = 'USD' } } })
        })
    },
    @{
        date = '2026-09-02'
        projects = @(@{
            project = 'web'
            values = @(@{ date = '2026-09-02'; source_uuid = @('uuid-sep'); cost = @{ total = @{ value = 9; units = 'USD' } } })
        })
    }
)
$script:NestedDays = $nestedDays
$nestedNamed = @(Get-CostManagementNamedValues -Items $nestedDays -GroupName 'project')
$nestedDates = @($nestedNamed | ForEach-Object { [string](Get-CostManagementJsonField -Object $_.Value -Name 'date') })
$nestedUuids = @($nestedNamed | ForEach-Object {
    $ids = Get-CostManagementJsonField -Object $_.Value -Name 'source_uuid'
    if ($null -eq $ids) { '' } else { [string](@($ids) -join ',') }
})
Assert-True 'nested project count' ($nestedNamed.Count -eq 2)
Assert-True 'nested project names' (($nestedNamed[0].Name -eq 'web') -and ($nestedNamed[1].Name -eq 'web'))
Assert-True 'nested value dates' (($nestedDates -contains '2026-08-15') -and ($nestedDates -contains '2026-09-02') -and ($nestedUuids -contains 'uuid-aug') -and ($nestedUuids -contains 'uuid-sep'))

$orgDays = @(@{
    date = '2026-08-01'
    org_entities = @(@{ org_unit_id = 'r-f22a'; values = @(@{ date = '2026-08-01' }) })
})
$orgNamed = @(Get-CostManagementNamedValues -Items $orgDays -GroupName 'org_unit_id')
Assert-True 'org entity name' ($orgNamed.Count -eq 1 -and $orgNamed[0].Name -eq 'r-f22a')

$categoryDays = @(@{
    date = '2026-08-01'
    CostCenters = @(@{ CostCenter = 'Platform'; values = @(@{ date = '2026-08-01' }) })
})
$categoryNamed = @(Get-CostManagementNamedValues -Items $categoryDays -GroupName 'CostCenter')
Assert-True 'category name' ($categoryNamed.Count -eq 1 -and $categoryNamed[0].Name -eq 'Platform')

$script:SpanUrls = @()
$spanInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $script:SpanUrls += [string]$Uri
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$spanSession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke $spanInvoke -Now { Get-Date }
$spanSession.AccessToken = 'tok'
$spanSession.IssuedAt = Get-Date
Get-CostManagementWindowData -StartDate ([datetime]'2026-08-01') -EndDate ([datetime]'2026-09-05') -ApiBaseUrl 'https://cost.example.com' -RelativeUrl '/api/cost-management/v1/reports/openshift/costs/' -Session $spanSession -Invoke $spanInvoke -Sleep { } | Out-Null
$spanJoined = $script:SpanUrls -join "`n"
Assert-True 'august month request' ($spanJoined.Contains('start_date=2026-08-01') -and $spanJoined.Contains('end_date=2026-08-31'))
Assert-True 'september month request' ($spanJoined.Contains('start_date=2026-09-01') -and $spanJoined.Contains('end_date=2026-09-05'))
$spanFull = @($script:SpanUrls | Where-Object { $_.Contains('start_date=2026-08-01') -and $_.Contains('end_date=2026-09-05') })
Assert-True 'no full span request' ($spanFull.Count -eq 0)

$script:ClipUrls = @()
$clipInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $script:ClipUrls += [string]$Uri
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$clipSession = New-CostManagementTokenSession -TokenUrl 'https://keycloak.example.com/token' -ClientId 'id' -ClientSecret 'secret' -Scope 'api.console' -Invoke $clipInvoke -Now { Get-Date }
$clipSession.AccessToken = 'tok'
$clipSession.IssuedAt = Get-Date
Get-CostManagementWindowData -StartDate ([datetime]'2026-08-15') -EndDate ([datetime]'2026-09-05') -ApiBaseUrl 'https://cost.example.com' -RelativeUrl '/api/cost-management/v1/reports/openshift/costs/' -Session $clipSession -Invoke $clipInvoke -Sleep { } | Out-Null
$clipJoined = $script:ClipUrls -join "`n"
Assert-True 'clipped august request' ($clipJoined.Contains('start_date=2026-08-15') -and $clipJoined.Contains('end_date=2026-08-31'))
Assert-True 'clipped september request' ($clipJoined.Contains('start_date=2026-09-01') -and $clipJoined.Contains('end_date=2026-09-05'))

$monthDir = Join-Path $env:TEMP ("cm-month-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $monthDir | Out-Null
$monthInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('/tags/openshift/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' } }
    if ($u.Contains('group_by[project]') -and $u.Contains('start_date=2026-08-01') -and $u.Contains('end_date=2026-08-31')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @($script:NestedDays[0]) }; Body = '' }
    }
    if ($u.Contains('group_by[project]') -and $u.Contains('start_date=2026-09-01') -and $u.Contains('end_date=2026-09-05')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @($script:NestedDays[1]) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-08-01' -EndDate '2026-09-05' -ClientId 'id' -ClientSecret 'secret' -OutDir $monthDir -Dataset 'OS_Costs_Daily' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $monthInvoke -Now { Get-Date } -Sleep { }
$monthRows = @(Import-Csv (Join-Path $monthDir 'OS_Costs_Daily.csv'))
$augustCost = @($monthRows | Where-Object { $_.date -eq '2026-08-15' })
$septemberCost = @($monthRows | Where-Object { $_.date -eq '2026-09-02' })
Assert-True 'august cost date' ($augustCost.Count -eq 1 -and $augustCost[0].'values.date' -eq '2026-08-15' -and $augustCost[0].'values.source_uuid' -eq 'uuid-aug')
Assert-True 'september cost date' ($septemberCost.Count -eq 1 -and $septemberCost[0].'values.date' -eq '2026-09-02' -and $septemberCost[0].Name -eq 'web')
Remove-Item $monthDir -Recurse -Force

$multiTagDir = Join-Path $env:TEMP ("cm-multitag-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $multiTagDir | Out-Null
$script:ProjectTagUrls = @()
$multiTagInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('filter[project]=web')) {
        $script:ProjectTagUrls += $u
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ key = 'env'; enabled = $true; values = @('prod') }); meta = @{ count = 1 } }; Body = '' }
    }
    if ($u.Contains('group_by[project]') -and $u.Contains('start_date=2026-08-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @($script:NestedDays[0]) }; Body = '' }
    }
    if ($u.Contains('group_by[project]') -and $u.Contains('start_date=2026-09-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @($script:NestedDays[1]) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-08-01' -EndDate '2026-09-05' -ClientId 'id' -ClientSecret 'secret' -OutDir $multiTagDir -Dataset 'OS_Cost_Project_Tags' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $multiTagInvoke -Now { Get-Date } -Sleep { }
$multiTagRows = @(Import-Csv (Join-Path $multiTagDir 'OS_Cost_Project_Tags.csv'))
$augustTag = @($multiTagRows | Where-Object { $_.'Filter Month' -eq '2026-8' })
$septemberTag = @($multiTagRows | Where-Object { $_.'Filter Month' -eq '2026-9' })
Assert-True 'august tag month' ($augustTag.Count -eq 1 -and $augustTag[0].date -eq '2026-08-01' -and $augustTag[0].key -eq 'env')
Assert-True 'september tag month' ($septemberTag.Count -eq 1 -and $septemberTag[0].date -eq '2026-09-01' -and $septemberTag[0].'Filter Month' -eq '2026-9')
Assert-True 'project tags fetched once' ($script:ProjectTagUrls.Count -eq 1)
Remove-Item $multiTagDir -Recurse -Force

$clusterDir = Join-Path $env:TEMP ("cm-cluster-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $clusterDir | Out-Null
$clusterInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('group_by[cluster]') -and $u.Contains('start_date=2026-08-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-08-15'; clusters = @(@{ cluster = 'prod'; values = @(@{ date = '2026-08-15' }) }) }) }; Body = '' }
    }
    if ($u.Contains('group_by[project]') -and $u.Contains('filter[cluster]=prod') -and $u.Contains('start_date=2026-08-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-08-15'; projects = @(@{ project = 'web'; values = @(@{ date = '2026-08-15'; cost = @{ total = @{ value = 3; units = 'USD' } } }) }) }) }; Body = '' }
    }
    if ($u.Contains('group_by[cluster]') -and $u.Contains('start_date=2026-09-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-09-02'; clusters = @(@{ cluster = 'prod'; values = @(@{ date = '2026-09-02' }) }) }) }; Body = '' }
    }
    if ($u.Contains('group_by[project]') -and $u.Contains('filter[cluster]=prod') -and $u.Contains('start_date=2026-09-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-09-02'; projects = @(@{ project = 'web'; values = @(@{ date = '2026-09-02'; cost = @{ total = @{ value = 4; units = 'USD' } } }) }) }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-08-01' -EndDate '2026-09-05' -ClientId 'id' -ClientSecret 'secret' -OutDir $clusterDir -Dataset 'OS_Cost_Cluster_Projects' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $clusterInvoke -Now { Get-Date } -Sleep { }
$clusterRows = @(Import-Csv (Join-Path $clusterDir 'OS_Cost_Cluster_Projects.csv'))
$augustCluster = @($clusterRows | Where-Object { $_.date -eq '2026-08-15' })
$septemberCluster = @($clusterRows | Where-Object { $_.date -eq '2026-09-02' })
Assert-True 'august cluster day' ($augustCluster.Count -eq 1 -and $augustCluster[0].'Filter Month' -eq '2026-8' -and $augustCluster[0].project -eq 'web' -and $augustCluster[0].cluster -eq 'prod')
Assert-True 'september cluster day' ($septemberCluster.Count -eq 1 -and $septemberCluster[0].'Filter Month' -eq '2026-9' -and $septemberCluster[0].value -eq '4')
Remove-Item $clusterDir -Recurse -Force

$usageMonthDir = Join-Path $env:TEMP ("cm-usage-month-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $usageMonthDir | Out-Null
$usageMonthInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('/tags/openshift/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' } }
    if ($u.Contains('/reports/openshift/compute/') -and $u.Contains('group_by[project]') -and $u.Contains('start_date=2026-08-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-08-15'; projects = @(@{ project = 'web'; values = @(@{ date = '2026-08-15'; usage = @{ value = 1; units = 'cores' } }) }) }) }; Body = '' }
    }
    if ($u.Contains('/reports/openshift/compute/') -and $u.Contains('group_by[project]') -and $u.Contains('start_date=2026-09-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-09-02'; projects = @(@{ project = 'web'; values = @(@{ date = '2026-09-02'; usage = @{ value = 2; units = 'cores' } }) }) }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-08-01' -EndDate '2026-09-05' -ClientId 'id' -ClientSecret 'secret' -OutDir $usageMonthDir -Dataset 'OS_Daily_Usage' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $usageMonthInvoke -Now { Get-Date } -Sleep { }
$usageMonthRows = @(Import-Csv (Join-Path $usageMonthDir 'OS_Daily_Usage.csv'))
Assert-True 'usage keeps both days' ((@($usageMonthRows | Where-Object { $_.date -eq '2026-08-15' })).Count -eq 1 -and (@($usageMonthRows | Where-Object { $_.date -eq '2026-09-02' })).Count -eq 1)
Remove-Item $usageMonthDir -Recurse -Force

$awsMonthDir = Join-Path $env:TEMP ("cm-aws-month-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $awsMonthDir | Out-Null
$awsMonthInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('/tags/aws/') -or $u.Contains('/aws-categories/') -or $u.Contains('/organizations/aws/')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
    }
    if ($u.Contains('/reports/aws/costs/') -and $u.Contains('group_by[account]') -and $u.Contains('start_date=2026-08-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-08-15'; accounts = @(@{ account = '111'; values = @(@{ date = '2026-08-15'; account_alias = 'prod' }) }) }) }; Body = '' }
    }
    if ($u.Contains('/reports/aws/costs/') -and $u.Contains('group_by[account]') -and $u.Contains('start_date=2026-09-01')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-09-02'; accounts = @(@{ account = '111'; values = @(@{ date = '2026-09-02'; account_alias = 'prod' }) }) }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-08-01' -EndDate '2026-09-05' -ClientId 'id' -ClientSecret 'secret' -OutDir $awsMonthDir -Dataset 'AWS_Daily_Costs' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $awsMonthInvoke -Now { Get-Date } -Sleep { }
$awsMonthRows = @(Import-Csv (Join-Path $awsMonthDir 'AWS_Daily_Costs.csv'))
Assert-True 'aws keeps both days' ((@($awsMonthRows | Where-Object { $_.date -eq '2026-08-15' -and $_.'values.date' -eq '2026-08-15' })).Count -eq 1 -and (@($awsMonthRows | Where-Object { $_.date -eq '2026-09-02' })).Count -eq 1)
Remove-Item $awsMonthDir -Recurse -Force

$mergeDir = Join-Path $env:TEMP ("cm-merge-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $mergeDir | Out-Null
$july = New-CostManagementRow 'OS_Costs_Daily'
$july['date'] = '2026-07-10'
$july['Name'] = 'july-web'
$oldAugust = New-CostManagementRow 'OS_Costs_Daily'
$oldAugust['date'] = '2026-08-15'
$oldAugust['Name'] = 'old-august'
Write-CostManagementCsv -Path (Join-Path $mergeDir 'OS_Costs_Daily.csv') -Header (Get-CostManagementSchemaHeader 'OS_Costs_Daily') -Rows @($july, $oldAugust)
$mergeInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('/tags/openshift/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' } }
    if ($u.Contains('group_by[project]') -and $u.Contains('start_date=2026-08-01') -and $u.Contains('end_date=2026-08-31')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-08-20'; projects = @(@{ project = 'web'; values = @(@{ date = '2026-08-20' }) }) }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-08-01' -EndDate '2026-08-31' -ClientId 'id' -ClientSecret 'secret' -OutDir $mergeDir -Dataset 'OS_Costs_Daily' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $mergeInvoke -Now { Get-Date } -Sleep { }
$mergedRows = @(Import-Csv (Join-Path $mergeDir 'OS_Costs_Daily.csv'))
Assert-True 'merge keeps july' ((@($mergedRows | Where-Object { $_.Name -eq 'july-web' -and $_.date -eq '2026-07-10' })).Count -eq 1)
Assert-True 'merge replaces august' ((@($mergedRows | Where-Object { $_.date -eq '2026-08-20' -and $_.Name -eq 'web' })).Count -eq 1)
Assert-True 'merge drops old august' ((@($mergedRows | Where-Object { $_.Name -eq 'old-august' })).Count -eq 0)
Remove-Item $mergeDir -Recurse -Force

$tagMergeDir = Join-Path $env:TEMP ("cm-tag-merge-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tagMergeDir | Out-Null
$oldJulyTag = New-CostManagementRow 'OS_Cost_Project_Tags'
$oldJulyTag['date'] = '2026-07-01'
$oldJulyTag['project'] = 'web'
$oldJulyTag['key'] = 'env'
$oldJulyTag['Filter Month'] = '2026-7'
$oldSeptemberTag = New-CostManagementRow 'OS_Cost_Project_Tags'
$oldSeptemberTag['date'] = '2026-09-01'
$oldSeptemberTag['project'] = 'web'
$oldSeptemberTag['key'] = 'old'
$oldSeptemberTag['Filter Month'] = '2026-9'
Write-CostManagementCsv -Path (Join-Path $tagMergeDir 'OS_Cost_Project_Tags.csv') -Header (Get-CostManagementSchemaHeader 'OS_Cost_Project_Tags') -Rows @($oldJulyTag, $oldSeptemberTag)
$tagMergeInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('filter[project]=web')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ key = 'env'; enabled = $true; values = @('prod') }); meta = @{ count = 1 } }; Body = '' } }
    if ($u.Contains('group_by[project]')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-09-12'; projects = @(@{ project = 'web'; values = @(@{ date = '2026-09-12' }) }) }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-10' -EndDate '2026-09-20' -ClientId 'id' -ClientSecret 'secret' -OutDir $tagMergeDir -Dataset 'OS_Cost_Project_Tags' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $tagMergeInvoke -Now { Get-Date } -Sleep { }
$tagMerged = @(Import-Csv (Join-Path $tagMergeDir 'OS_Cost_Project_Tags.csv'))
Assert-True 'tag merge keeps july' ((@($tagMerged | Where-Object { $_.date -eq '2026-07-01' -and $_.key -eq 'env' })).Count -eq 1)
Assert-True 'tag merge replaces september' ((@($tagMerged | Where-Object { $_.date -eq '2026-09-01' -and $_.key -eq 'env' -and $_.'Filter Month' -eq '2026-9' })).Count -eq 1)
Assert-True 'tag merge drops old september' ((@($tagMerged | Where-Object { $_.key -eq 'old' })).Count -eq 0)
Remove-Item $tagMergeDir -Recurse -Force

$periodDir = Join-Path $env:TEMP ("cm-period-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $periodDir | Out-Null
$periodInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-08-01' -EndDate '2026-09-05' -ClientId 'id' -ClientSecret 'secret' -OutDir $periodDir -Dataset 'Default_Master_Settings' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $periodInvoke -Now { Get-Date } -Sleep { }
Export-CostManagementData -StartDate '2026-09-10' -EndDate '2026-09-20' -ClientId 'id' -ClientSecret 'secret' -OutDir $periodDir -Dataset 'Default_Master_Settings' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $periodInvoke -Now { Get-Date } -Sleep { }
$periodRows = @(Import-Csv (Join-Path $periodDir 'Data_Period.csv'))
Assert-True 'period keeps both windows' ($periodRows.Count -eq 2 -and (@($periodRows | Where-Object { $_.'Start Date' -eq '2026-08-01' -and $_.'End Date' -eq '2026-09-05' })).Count -eq 1 -and (@($periodRows | Where-Object { $_.'Start Date' -eq '2026-09-10' -and $_.'End Date' -eq '2026-09-20' })).Count -eq 1)
Export-CostManagementData -StartDate '2026-09-10' -EndDate '2026-09-20' -ClientId 'id' -ClientSecret 'secret' -OutDir $periodDir -Dataset 'Default_Master_Settings' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $periodInvoke -Now { Get-Date } -Sleep { }
$periodAgain = @(Import-Csv (Join-Path $periodDir 'Data_Period.csv'))
Assert-True 'period does not duplicate a window' ($periodAgain.Count -eq 2)
$settingsAgain = Import-Csv (Join-Path $periodDir 'Default_Master_Settings.csv')
Assert-True 'settings stay one row' (@($settingsAgain).Count -eq 1 -and $settingsAgain.code -eq 'USD')
Remove-Item $periodDir -Recurse -Force

$oneCurrency = [pscustomobject]@{ code = 'USD'; name = 'US Dollar'; symbol = '$'; description = 'USD ($) - US Dollar' }
$oneList = ConvertTo-CostManagementItemList $oneCurrency
Assert-True 'single currency object stays one item' ($oneList.Count -eq 1 -and [string](Get-CostManagementJsonField -Object $oneList[0] -Name 'code') -eq 'USD')

$singleDir = Join-Path $env:TEMP ("cm-currency-object-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $singleDir | Out-Null
$singleInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = $oneCurrency }; Body = '' }
    }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $singleDir -Dataset 'Default_Master_Settings' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $singleInvoke -Now { Get-Date } -Sleep { }
$singleRow = Import-Csv (Join-Path $singleDir 'Default_Master_Settings.csv')
Assert-True 'single currency object copies description' ($singleRow.description -eq 'USD ($) - US Dollar' -and $singleRow.name -eq 'US Dollar' -and $singleRow.symbol -eq '$')
Remove-Item $singleDir -Recurse -Force

function Write-SettingsFixture {
    param([string]$Dir, [string]$Description)
    $row = New-CostManagementRow 'Default_Master_Settings'
    $row['code'] = 'USD'
    $row['name'] = 'US Dollar'
    $row['symbol'] = '$'
    $row['description'] = $Description
    $row['Default_Configurations.data.currency'] = 'USD'
    $row['Default_Configurations.data.cost_type'] = 'calculated'
    Write-CostManagementCsv -Path (Join-Path $Dir 'Default_Master_Settings.csv') -Header (Get-CostManagementSchemaHeader 'Default_Master_Settings') -Rows @($row)
}

$currencyFailDir = Join-Path $env:TEMP ("cm-currency-fail-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $currencyFailDir | Out-Null
Write-SettingsFixture -Dir $currencyFailDir -Description 'keep me'
$currencyFailInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 404; Json = $null; Body = 'missing' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$currencyFailThrew = $false
try {
    Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $currencyFailDir -Dataset 'Default_Master_Settings' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $currencyFailInvoke -Now { Get-Date } -Sleep { }
} catch {
    $currencyFailThrew = $true
}
$currencyFailRow = Import-Csv (Join-Path $currencyFailDir 'Default_Master_Settings.csv')
$currencyFailLog = ''
if (Test-Path (Join-Path $currencyFailDir 'export.log')) { $currencyFailLog = Get-Content -Raw (Join-Path $currencyFailDir 'export.log') }
Assert-True 'currency http failure fails the dataset' $currencyFailThrew
Assert-True 'currency http failure keeps description' ($currencyFailRow.description -eq 'keep me')
Assert-True 'currency http failure logs status' ($currencyFailLog -match 'status=404')
Remove-Item $currencyFailDir -Recurse -Force

$currencyMissDir = Join-Path $env:TEMP ("cm-currency-miss-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $currencyMissDir | Out-Null
Write-SettingsFixture -Dir $currencyMissDir -Description 'keep me'
$currencyMissInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'EUR'; name = 'Euro'; symbol = 'E'; description = 'EUR (E) - Euro' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$currencyMissThrew = $false
try {
    Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $currencyMissDir -Dataset 'Default_Master_Settings' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $currencyMissInvoke -Now { Get-Date } -Sleep { }
} catch {
    $currencyMissThrew = $true
}
$currencyMissRow = Import-Csv (Join-Path $currencyMissDir 'Default_Master_Settings.csv')
$currencyMissLog = ''
if (Test-Path (Join-Path $currencyMissDir 'export.log')) { $currencyMissLog = Get-Content -Raw (Join-Path $currencyMissDir 'export.log') }
Assert-True 'currency miss fails the dataset' $currencyMissThrew
Assert-True 'currency miss keeps description' ($currencyMissRow.description -eq 'keep me')
Assert-True 'currency miss logs status' ($currencyMissLog -match 'status=200' -and $currencyMissLog -match 'currency catalog has no match')
Remove-Item $currencyMissDir -Recurse -Force

$currencyPageDir = Join-Path $env:TEMP ("cm-currency-page-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $currencyPageDir | Out-Null
$currencyPageInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*' -and $u.Contains('offset=100')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD'; name = 'US Dollar'; symbol = '$'; description = 'USD ($) - US Dollar' }); meta = @{ count = 101 } }; Body = '' }
    }
    if ($u -like '*/currency/*') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'EUR'; name = 'Euro'; symbol = 'E'; description = 'EUR (E) - Euro' }); meta = @{ count = 101 } }; Body = '' }
    }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $currencyPageDir -Dataset 'Default_Master_Settings' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $currencyPageInvoke -Now { Get-Date } -Sleep { }
$currencyPageRow = Import-Csv (Join-Path $currencyPageDir 'Default_Master_Settings.csv')
Assert-True 'currency match on the next page copies description' ($currencyPageRow.description -eq 'USD ($) - US Dollar' -and $currencyPageRow.code -eq 'USD')
Remove-Item $currencyPageDir -Recurse -Force

$usagePq = Get-Content -Raw (Join-Path $PSScriptRoot '..\PowerBI\OS_Daily_Usage.pq')
$awsPq = Get-Content -Raw (Join-Path $PSScriptRoot '..\PowerBI\AWS_Daily_Costs.pq')
$osCostPq = Get-Content -Raw (Join-Path $PSScriptRoot '..\PowerBI\OS_Costs_Daily.pq')
$recommendationPq = Get-Content -Raw (Join-Path $PSScriptRoot '..\PowerBI\Recommendations.pq')
Assert-True 'usage capacity imports as a decimal' ($usagePq.Contains('"values.capacity.value", type number') -and $usagePq.Contains('"values.capacity.count", type number'))
Assert-True 'aws usage imports as a decimal' ($awsPq.Contains('"values.infrastructure.usage.value", type number') -and $awsPq.Contains('"values.cost.usage.value", type number') -and $awsPq.Contains('"values.supplementary.total.value", type number'))
Assert-True 'openshift supplementary imports as a decimal' ($osCostPq.Contains('"values.supplementary.raw.value", type number') -and $osCostPq.Contains('"values.supplementary.markup.value", type number'))
Assert-True 'recommendation duration imports as a decimal' ($recommendationPq.Contains('"st.duration_in_hours", type number') -and $recommendationPq.Contains('"source_id", type text'))

$capacityDir = Join-Path $env:TEMP ("cm-capacity-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $capacityDir | Out-Null
$capacityInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u -like '*/currency/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ code = 'USD' }) }; Body = '' } }
    if ($u -like '*/account-settings/*') { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @{ currency = 'USD'; cost_type = 'calculated' } }; Body = '' } }
    if ($u.Contains('/tags/openshift/')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' } }
    if ($u.Contains('/reports/openshift/compute/') -and $u.Contains('group_by[project]')) {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ meta = @{ count = 1 }; data = @(@{ date = '2026-09-02'; projects = @(@{ project = 'web'; values = @(@{ date = '2026-09-02'; request = @{ unused = 0.5; unused_percent = 10 }; capacity = @{ value = 2.5; units = 'cores'; unused = 1.25; unused_percent = 20; count = 3.5; count_units = 'cores' } }) }) }) }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $capacityDir -Dataset 'OS_Daily_Usage' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $capacityInvoke -Now { Get-Date } -Sleep { }
$capacityRow = @(Import-Csv (Join-Path $capacityDir 'OS_Daily_Usage.csv')) | Where-Object { $_.'Usage Name' -eq 'compute' } | Select-Object -First 1
Assert-True 'usage keeps capacity count' ($capacityRow.'values.capacity.value' -eq '2.5' -and $capacityRow.'values.capacity.count' -eq '3.5' -and $capacityRow.'values.capacity.count_units' -eq 'cores' -and $capacityRow.'values.capacity.unused' -eq '1.25' -and $capacityRow.'values.request.unused' -eq '0.5')
Remove-Item $capacityDir -Recurse -Force

$categoryDir = Join-Path $env:TEMP ("cm-category-strings-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $categoryDir | Out-Null
$script:CategoryUrls = @()
$categoryInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u.Contains('/aws-categories/')) {
        $script:CategoryUrls += $u
        return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @('Env', 'Team'); meta = @{ count = 2 } }; Body = '' }
    }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $categoryDir -Dataset 'AWS_Cost_Categories' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $categoryInvoke -Now { Get-Date } -Sleep { }
$categoryRows = @(Import-Csv (Join-Path $categoryDir 'AWS_Cost_Categories.csv'))
Assert-True 'category strings fill data' ((@($categoryRows | Where-Object { $_.data -eq 'Env' })).Count -eq 1 -and (@($categoryRows | Where-Object { $_.data -eq 'Team' })).Count -eq 1)
Assert-True 'category request has no page parameters' ($script:CategoryUrls.Count -eq 1 -and $script:CategoryUrls[0].Contains('key_only=true') -and -not $script:CategoryUrls[0].Contains('offset') -and -not $script:CategoryUrls[0].Contains('limit'))
Remove-Item $categoryDir -Recurse -Force

$script:TagFirstPage = New-Object System.Collections.Generic.List[object]
1..100 | ForEach-Object { $script:TagFirstPage.Add(@{ key = ('k' + $_); enabled = $true }) }
$tagPageDir = Join-Path $env:TEMP ("cm-tag-pages-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tagPageDir | Out-Null
$tagPageInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u.Contains('/tags/openshift/') -and $u.Contains('offset=0') -and -not $u.Contains('filter[offset]')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = $script:TagFirstPage; meta = @{ count = 101 } }; Body = '' } }
    if ($u.Contains('/tags/openshift/') -and $u.Contains('offset=100')) { return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(@{ key = 'last'; enabled = $true }); meta = @{ count = 101 } }; Body = '' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $tagPageDir -Dataset 'OS_Tag_Keys' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $tagPageInvoke -Now { Get-Date } -Sleep { }
$tagPageRows = @(Import-Csv (Join-Path $tagPageDir 'OS_Tag_Keys.csv'))
Assert-True 'tag keys read the next page' ((@($tagPageRows | Where-Object { $_.key -eq 'k1' })).Count -eq 1 -and (@($tagPageRows | Where-Object { $_.key -eq 'last' })).Count -eq 1)
Remove-Item $tagPageDir -Recurse -Force

$tagFailDir = Join-Path $env:TEMP ("cm-tag-fail-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tagFailDir | Out-Null
$keptTag = New-CostManagementRow 'OS_Tag_Keys'
$keptTag['key'] = 'keep'
$keptTag['Group By'] = 'tag'
Write-CostManagementCsv -Path (Join-Path $tagFailDir 'OS_Tag_Keys.csv') -Header (Get-CostManagementSchemaHeader 'OS_Tag_Keys') -Rows @($keptTag)
$tagFailInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u.Contains('/tags/openshift/')) { return [pscustomobject]@{ StatusCode = 404; Json = $null; Body = 'missing' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$tagFailThrew = $false
try {
    Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $tagFailDir -Dataset 'OS_Tag_Keys' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $tagFailInvoke -Now { Get-Date } -Sleep { }
} catch {
    $tagFailThrew = $true
}
$tagFailRow = Import-Csv (Join-Path $tagFailDir 'OS_Tag_Keys.csv')
$tagFailLog = ''
if (Test-Path (Join-Path $tagFailDir 'export.log')) { $tagFailLog = Get-Content -Raw (Join-Path $tagFailDir 'export.log') }
Assert-True 'tag http failure fails the dataset' $tagFailThrew
Assert-True 'tag http failure keeps the key' ($tagFailRow.key -eq 'keep')
Assert-True 'tag http failure logs status' ($tagFailLog -match 'status=404')
Remove-Item $tagFailDir -Recurse -Force

$recommendationFailDir = Join-Path $env:TEMP ("cm-rec-fail-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $recommendationFailDir | Out-Null
$keptRecommendation = New-CostManagementRow 'Recommendations'
$keptRecommendation['cluster_uuid'] = 'keep-cluster'
Write-CostManagementCsv -Path (Join-Path $recommendationFailDir 'Recommendations.csv') -Header (Get-CostManagementSchemaHeader 'Recommendations') -Rows @($keptRecommendation)
$recommendationFailInvoke = {
    param($Method, $Uri, $Headers, $Body)
    $u = [string]$Uri
    if ($u -like '*/token') { return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok' }; Body = '' } }
    if ($u.Contains('/recommendations/openshift')) { return [pscustomobject]@{ StatusCode = 404; Json = $null; Body = 'missing' } }
    return [pscustomobject]@{ StatusCode = 200; Json = @{ data = @(); meta = @{ count = 0 } }; Body = '' }
}
$recommendationFailThrew = $false
try {
    Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-30' -ClientId 'id' -ClientSecret 'secret' -OutDir $recommendationFailDir -Dataset 'Recommendations' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $recommendationFailInvoke -Now { Get-Date } -Sleep { }
} catch {
    $recommendationFailThrew = $true
}
$recommendationFailRow = Import-Csv (Join-Path $recommendationFailDir 'Recommendations.csv')
$recommendationFailLog = ''
if (Test-Path (Join-Path $recommendationFailDir 'export.log')) { $recommendationFailLog = Get-Content -Raw (Join-Path $recommendationFailDir 'export.log') }
Assert-True 'recommendation http failure fails the dataset' $recommendationFailThrew
Assert-True 'recommendation http failure keeps the row' ($recommendationFailRow.cluster_uuid -eq 'keep-cluster')
Assert-True 'recommendation http failure logs status' ($recommendationFailLog -match 'status=404')
Remove-Item $recommendationFailDir -Recurse -Force

if ($script:Failed -gt 0) { exit 1 }
Write-Host "ALL PASS"
exit 0
