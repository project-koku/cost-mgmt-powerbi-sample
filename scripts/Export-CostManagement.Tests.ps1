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

if ($script:Failed -gt 0) { exit 1 }
Write-Host "ALL PASS"
exit 0
