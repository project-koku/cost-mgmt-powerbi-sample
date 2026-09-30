function Get-CostManagementDatasetIds {
    return [string[]]@(
        'Data_Period',
        'Default_Master_Settings',
        'OS_Costs_Daily',
        'OS_Cost_Project_Tags',
        'OS_Cost_Cluster_Projects',
        'OS_Tag_Keys',
        'OS_Daily_Usage',
        'AWS_Daily_Costs',
        'AWS_Tag_Keys',
        'AWS_Cost_Categories',
        'AWS_Org_Units',
        'Recommendations'
    )
}

function Get-CostManagementHelpText {
    $ids = (Get-CostManagementDatasetIds) -join ', '
    return @"
Exports Red Hat Cost Management data to CSV for Power BI.

Dates use yyyy-MM-dd. -StartDate defaults to 30 days before today, local time. -EndDate defaults to yesterday, local time.

Datasets (-Dataset): $ids

-ApiBaseUrl defaults to https://console.redhat.com.
-TokenUrl defaults to https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token.
-Scope defaults to api.console.

-TestProxy reports the system proxy and does not read auth.csv.
-Test checks the proxy, then the service account.

Examples:
  powershell.exe -File scripts/Export-CostManagement.ps1
  powershell.exe -File scripts/Export-CostManagement.ps1 -Dataset OS_Costs_Daily
  powershell.exe -File scripts/Export-CostManagement.ps1 -TokenUrl https://keycloak.example.com/token -ApiBaseUrl https://cost.example.com
  powershell.exe -File scripts/Export-CostManagement.ps1 -TestProxy
  powershell.exe -File scripts/Export-CostManagement.ps1 -Test
"@
}

function ConvertTo-CostManagementField {
    param($Value)
    if ($null -eq $Value) { return '' }
    $isList = $Value -is [System.Array] -or ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string])
    if ($isList) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($Value)) {
            if ($null -ne $item) { $parts.Add([string]$item) }
        }
        return ($parts -join ',')
    }
    return [string]$Value
}

function Format-CostManagementCsvField {
    param([string]$Text)
    if ($Text -match '[,"\r\n]') {
        return '"' + ($Text -replace '"', '""') + '"'
    }
    return $Text
}

function Write-CostManagementCsv {
    param(
        [string]$Path,
        [string[]]$Header,
        [object[]]$Rows
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $headerCells = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Header) {
        $headerCells.Add((Format-CostManagementCsvField $name))
    }
    $lines.Add(($headerCells -join ','))
    $recordList = New-Object System.Collections.Generic.List[object]
    if ($Rows -is [System.Collections.IDictionary]) {
        $recordList.Add($Rows)
    } elseif ($null -ne $Rows) {
        foreach ($item in @($Rows)) {
            if ($null -ne $item) { $recordList.Add($item) }
        }
    }
    foreach ($row in $recordList) {
        $cells = New-Object System.Collections.Generic.List[string]
        foreach ($name in $Header) {
            $raw = $null
            if ($null -ne $row -and $row.Contains($name)) { $raw = $row[$name] }
            $cells.Add((Format-CostManagementCsvField (ConvertTo-CostManagementField $raw)))
        }
        $lines.Add(($cells -join ','))
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllLines($Path, $lines.ToArray(), $utf8Bom)
}

function New-CostManagementTokenSession {
    param(
        [string]$TokenUrl,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$Scope,
        [scriptblock]$Invoke,
        [scriptblock]$Now
    )
    return [pscustomobject]@{
        TokenUrl = $TokenUrl
        ClientId = $ClientId
        ClientSecret = $ClientSecret
        Scope = $Scope
        Invoke = $Invoke
        Now = $Now
        AccessToken = $null
        IssuedAt = $null
    }
}

function Get-CostManagementAccessToken {
    param($Session)
    $now = & $Session.Now
    $refresh = $null -eq $Session.IssuedAt
    if (-not $refresh) {
        $age = $now - $Session.IssuedAt
        if ($age.TotalMinutes -ge 4) { $refresh = $true }
    }
    if ($refresh) {
        $body = 'grant_type=client_credentials&client_id=' + [uri]::EscapeDataString($Session.ClientId) + '&client_secret=' + [uri]::EscapeDataString($Session.ClientSecret) + '&scope=' + [uri]::EscapeDataString($Session.Scope)
        $response = & $Session.Invoke -Method POST -Uri $Session.TokenUrl -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } -Body $body
        $Session.AccessToken = $response.Json.access_token
        $Session.IssuedAt = $now
    }
    return [string]$Session.AccessToken
}

function Test-CostManagementCredentials {
    param(
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$ApiBaseUrl,
        [string]$TokenUrl,
        [string]$Scope,
        [scriptblock]$Invoke
    )
    $tokenBody = 'grant_type=client_credentials&client_id=' + [uri]::EscapeDataString($ClientId) + '&client_secret=' + [uri]::EscapeDataString($ClientSecret) + '&scope=' + [uri]::EscapeDataString($Scope)
    try {
        $tokenResponse = & $Invoke -Method POST -Uri $TokenUrl -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } -Body $tokenBody
    } catch {
        return [pscustomobject]@{ ExitCode = 1; Message = 'connection: failed' }
    }
    if ($tokenResponse.StatusCode -eq 400 -or $tokenResponse.StatusCode -eq 401) {
        return [pscustomobject]@{ ExitCode = 1; Message = 'credentials: rejected' }
    }
    if ($tokenResponse.StatusCode -ne 200) {
        return [pscustomobject]@{ ExitCode = 1; Message = ('api: failed ' + $tokenResponse.StatusCode) }
    }
    $settingsUri = $ApiBaseUrl.TrimEnd('/') + '/api/cost-management/v1/account-settings/'
    $token = [string]$tokenResponse.Json.access_token
    try {
        $settings = & $Invoke -Method GET -Uri $settingsUri -Headers @{ Authorization = ('Bearer ' + $token) } -Body $null
    } catch {
        return [pscustomobject]@{ ExitCode = 1; Message = 'connection: failed' }
    }
    if ($settings.StatusCode -eq 401 -or $settings.StatusCode -eq 403) {
        return [pscustomobject]@{ ExitCode = 1; Message = 'permissions: denied' }
    }
    if ($settings.StatusCode -eq 200) {
        return [pscustomobject]@{ ExitCode = 0; Message = 'credentials: accepted' }
    }
    return [pscustomobject]@{ ExitCode = 1; Message = ('api: failed ' + $settings.StatusCode) }
}

function Invoke-CostManagementRaw {
    param($Method, $Uri, $Headers, $Body, $Proxy)
    try {
        $params = @{ Method = $Method; Uri = $Uri; UseBasicParsing = $true }
        if ($Headers) { $params.Headers = $Headers }
        if ($null -ne $Body -and $Body -ne '') { $params.Body = $Body }
        if ($Proxy) {
            $params.Proxy = [string]$Proxy
            $params.ProxyCredential = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }
        $response = Invoke-WebRequest @params
        $text = [string]$response.Content
        $json = $null
        if ($text) {
            try { $json = $text | ConvertFrom-Json } catch { $json = $null }
        }
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Json = $json; Body = $text }
    } catch {
        $httpResponse = $_.Exception.Response
        if (-not $httpResponse) { throw }
        $status = [int]$httpResponse.StatusCode
        $text = ''
        try {
            $stream = $httpResponse.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $text = $reader.ReadToEnd()
                $reader.Dispose()
            }
        } catch {
            $text = ''
        }
        $json = $null
        if ($text) {
            try { $json = $text | ConvertFrom-Json } catch { $json = $null }
        }
        return [pscustomobject]@{ StatusCode = $status; Json = $json; Body = $text }
    }
}

function ConvertTo-CostManagementProxyUri {
    param($Proxy)
    $uri = [uri]$Proxy
    $port = ''
    if (-not $uri.IsDefaultPort) { $port = ':' + $uri.Port }
    return ($uri.Scheme + '://' + $uri.Host + $port)
}

function Get-CostManagementProxyDecision {
    param(
        [uri]$Uri,
        [scriptblock]$GetProxy
    )
    try {
        $found = & $GetProxy $Uri
    } catch {
        return [pscustomobject]@{ Choice = 'failed'; ProxyUri = $null }
    }
    if ($null -eq $found) {
        return [pscustomobject]@{ Choice = 'direct'; ProxyUri = $null }
    }
    if ($found -is [string] -or $found -is [uri]) {
        return [pscustomobject]@{ Choice = 'proxy'; ProxyUri = (ConvertTo-CostManagementProxyUri $found) }
    }
    if ($found.Bypassed) {
        return [pscustomobject]@{ Choice = 'bypassed'; ProxyUri = $null }
    }
    if ($found.Proxy) {
        return [pscustomobject]@{ Choice = 'proxy'; ProxyUri = (ConvertTo-CostManagementProxyUri $found.Proxy) }
    }
    return [pscustomobject]@{ Choice = 'direct'; ProxyUri = $null }
}

function Format-CostManagementProxyLine {
    param(
        [string]$Label,
        $Decision
    )
    if ($Decision.Choice -eq 'direct') { return "${Label}: direct" }
    if ($Decision.Choice -eq 'bypassed') { return "${Label}: bypassed" }
    if ($Decision.Choice -eq 'proxy') { return "${Label}: $($Decision.ProxyUri)" }
    if ($Decision.ProxyUri) { return "${Label}: failed $($Decision.ProxyUri)" }
    return "${Label}: failed"
}

function Test-CostManagementProxy {
    param(
        [string]$TokenUrl,
        [string]$ApiBaseUrl,
        [scriptblock]$GetProxy,
        [scriptblock]$Connect
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $failed = $false
    foreach ($target in @(
        @{ Label = 'proxy token'; Url = $TokenUrl },
        @{ Label = 'proxy api'; Url = $ApiBaseUrl }
    )) {
        $decision = Get-CostManagementProxyDecision -Uri $target.Url -GetProxy $GetProxy
        if ($decision.Choice -ne 'failed' -and $Connect) {
            try {
                & $Connect $target.Url $decision.ProxyUri | Out-Null
            } catch {
                $decision = [pscustomobject]@{ Choice = 'failed'; ProxyUri = $decision.ProxyUri }
            }
        }
        if ($decision.Choice -eq 'failed') { $failed = $true }
        $lines.Add((Format-CostManagementProxyLine -Label $target.Label -Decision $decision))
    }
    $exitCode = 0
    if ($failed) { $exitCode = 1 }
    return [pscustomobject]@{ ExitCode = $exitCode; Message = ($lines -join "`n") }
}

function Get-CostManagementSystemProxy {
    param($Uri)
    $target = [uri]$Uri
    $system = [System.Net.WebRequest]::GetSystemWebProxy()
    if ($system.IsBypassed($target)) {
        $selected = $system.GetProxy($target)
        if ($selected -and ([string]$selected -ne [string]$target)) {
            return [pscustomobject]@{ Bypassed = $true; Proxy = $selected }
        }
        return $null
    }
    $selected = $system.GetProxy($target)
    if (-not $selected -or ([string]$selected -eq [string]$target)) { return $null }
    return [string]$selected
}

function Connect-CostManagementEndpoint {
    param($Uri, $ProxyUri)
    $params = @{ Method = 'GET'; Uri = $Uri; UseBasicParsing = $true }
    if ($ProxyUri) {
        $params.Proxy = [string]$ProxyUri
        $params.ProxyCredential = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }
    try {
        $response = Invoke-WebRequest @params
        return [int]$response.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        throw
    }
}

function Enable-CostManagementTls {
    $tls12 = [Net.SecurityProtocolType]::Tls12
    if (([Net.ServicePointManager]::SecurityProtocol -band $tls12) -ne $tls12) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
    }
}

function Invoke-CostManagementWebRequest {
    param($Method, $Uri, $Headers, $Body)
    Enable-CostManagementTls
    $decision = Get-CostManagementProxyDecision -Uri $Uri -GetProxy ${function:Get-CostManagementSystemProxy}
    if ($decision.Choice -eq 'failed') {
        $detail = 'proxy: failed'
        if ($decision.ProxyUri) { $detail = "proxy: failed $($decision.ProxyUri)" }
        throw $detail
    }
    $proxy = $null
    if ($decision.Choice -eq 'proxy') { $proxy = $decision.ProxyUri }
    return Invoke-CostManagementRaw -Method $Method -Uri $Uri -Headers $Headers -Body $Body -Proxy $proxy
}

function Invoke-CostManagementTest {
    param(
        [string]$TokenUrl,
        [string]$ApiBaseUrl,
        [scriptblock]$GetProxy,
        [scriptblock]$Connect,
        [scriptblock]$ReadAuth
    )
    $proxy = Test-CostManagementProxy -TokenUrl $TokenUrl -ApiBaseUrl $ApiBaseUrl -GetProxy $GetProxy -Connect $Connect
    if ($proxy.ExitCode -ne 0) {
        return [pscustomobject]@{ ExitCode = 1; Message = $proxy.Message; Auth = $null }
    }
    $auth = & $ReadAuth
    return [pscustomobject]@{ ExitCode = 0; Message = $proxy.Message; Auth = $auth }
}

function Get-CostManagementPages {
    param([scriptblock]$GetPage)
    $rows = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        $page = & $GetPage $offset
        $data = @()
        if ($null -ne $page.Data) { $data = @($page.Data) }
        if ($data.Count -eq 0) { break }
        foreach ($item in $data) { $rows.Add($item) }
        $offset += 100
        $count = 0
        if ($null -ne $page.Count) { $count = [int]$page.Count }
        if ($offset -ge $count) { break }
    }
    return ,$rows.ToArray()
}

function Split-CostManagementDateWindow {
    param(
        [datetime]$StartDate,
        [datetime]$EndDate
    )
    $start = $StartDate.Date
    $end = $EndDate.Date
    $days = [int]($end - $start).TotalDays + 1
    if ($days -le 1) { return $null }
    $leftDays = [int][math]::Floor($days / 2)
    $leftEnd = $start.AddDays($leftDays - 1)
    return ,@(
        [pscustomobject]@{ StartDate = $start; EndDate = $leftEnd },
        [pscustomobject]@{ StartDate = $leftEnd.AddDays(1); EndDate = $end }
    )
}

function Invoke-CostManagementGet {
    param(
        [string]$ApiBaseUrl,
        [string]$RelativeUrl,
        $Session,
        [scriptblock]$Invoke,
        [scriptblock]$Sleep
    )
    $base = $ApiBaseUrl.TrimEnd('/')
    if ($RelativeUrl.StartsWith('/')) { $url = $base + $RelativeUrl }
    else { $url = $base + '/' + $RelativeUrl }
    $refreshed = $false
    $failures = 0
    $delays = @(2, 4, 8)
    while ($true) {
        $token = Get-CostManagementAccessToken -Session $Session
        $response = & $Invoke -Method GET -Uri $url -Headers @{ Authorization = ('Bearer ' + $token) } -Body $null
        if ($response.StatusCode -eq 401 -and -not $refreshed) {
            $Session.IssuedAt = $null
            $refreshed = $true
            continue
        }
        $status = [int]$response.StatusCode
        $retry = ($status -eq 429 -or $status -ge 500)
        if (-not $retry) { return $response }
        if ($Sleep) { & $Sleep $delays[$failures] }
        $failures++
        if ($failures -ge 3) { throw ('status=' + $status) }
    }
}

function Get-CostManagementWindowData {
    param(
        [datetime]$StartDate,
        [datetime]$EndDate,
        [string]$ApiBaseUrl,
        [string]$RelativeUrl,
        $Session,
        [scriptblock]$Invoke,
        [scriptblock]$Sleep
    )
    try {
        $rows = New-Object System.Collections.Generic.List[object]
        $offset = 0
        while ($true) {
            $start = $StartDate.ToString('yyyy-MM-dd')
            $end = $EndDate.ToString('yyyy-MM-dd')
            $separator = '?'
            if ($RelativeUrl.Contains('?')) { $separator = '&' }
            $relative = $RelativeUrl + $separator + 'start_date=' + $start + '&end_date=' + $end + '&filter[limit]=100&filter[offset]=' + $offset
            $response = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl $relative -Session $Session -Invoke $Invoke -Sleep $Sleep
            $meta = Get-CostManagementJsonField -Object $response.Json -Name 'meta'
            $countValue = Get-CostManagementJsonField -Object $meta -Name 'count'
            $count = 0
            if ($null -ne $countValue) { $count = [int]$countValue }
            $dataValue = Get-CostManagementJsonField -Object $response.Json -Name 'data'
            $data = ConvertTo-CostManagementItemList $dataValue
            if ($data.Count -eq 0) { break }
            foreach ($item in $data) { $rows.Add($item) }
            $offset += 100
            if ($offset -ge $count) { break }
        }
        return $rows.ToArray()
    } catch {
        $halves = Split-CostManagementDateWindow -StartDate $StartDate -EndDate $EndDate
        if ($null -eq $halves) { throw }
        $left = @(Get-CostManagementWindowData -StartDate $halves[0].StartDate -EndDate $halves[0].EndDate -ApiBaseUrl $ApiBaseUrl -RelativeUrl $RelativeUrl -Session $Session -Invoke $Invoke -Sleep $Sleep)
        $right = @(Get-CostManagementWindowData -StartDate $halves[1].StartDate -EndDate $halves[1].EndDate -ApiBaseUrl $ApiBaseUrl -RelativeUrl $RelativeUrl -Session $Session -Invoke $Invoke -Sleep $Sleep)
        return @($left + $right)
    }
}

function Get-CostManagementRepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-CostManagementSchemaHeader {
    param([string]$DatasetId)
    $path = Join-Path (Get-CostManagementRepoRoot) ("schema\" + $DatasetId + '.columns.txt')
    $line = @(Get-Content -LiteralPath $path -TotalCount 1)[0]
    if ($line.EndsWith("`r")) { $line = $line.TrimEnd("`r") }
    return @($line.Split(','))
}

function ConvertTo-OpenShiftCostRow {
    param(
        [string]$CurrencyCode,
        [string]$GroupByCode,
        $DistributedOverhead,
        [string]$Day,
        [string]$Name,
        $ValueRecord,
        $TagKey
    )
    $row = [ordered]@{}
    foreach ($column in (Get-CostManagementSchemaHeader 'OS_Costs_Daily')) {
        $row[$column] = ''
    }
    $row['code'] = $CurrencyCode
    $row['Group By Code'] = $GroupByCode
    $row['meta.distributed_overhead'] = ConvertTo-CostManagementField $DistributedOverhead
    $row['date'] = $Day
    $row['Name'] = $Name
    $row['key'] = ConvertTo-CostManagementField $TagKey
    if ($null -eq $ValueRecord) { return $row }
    $row['values.date'] = ConvertTo-CostManagementField $ValueRecord.date
    $row['values.classification'] = ConvertTo-CostManagementField $ValueRecord.classification
    $row['values.source_uuid'] = ConvertTo-CostManagementField $ValueRecord.source_uuid
    $row['values.clusters'] = ConvertTo-CostManagementField $ValueRecord.clusters
    $row['values.delta_percent'] = ConvertTo-CostManagementField $ValueRecord.delta_percent
    $row['values.delta_value'] = ConvertTo-CostManagementField $ValueRecord.delta_value
    foreach ($section in @('infrastructure', 'supplementary', 'cost')) {
        $sectionObject = $ValueRecord.$section
        foreach ($child in @('raw', 'markup', 'usage', 'total', 'platform_distributed', 'worker_unallocated_distributed', 'distributed')) {
            $valueName = "values.$section.$child.value"
            $unitName = "values.$section.$child.units"
            if (-not $row.Contains($valueName)) { continue }
            if ($null -eq $sectionObject) { continue }
            $node = $sectionObject.$child
            if ($null -eq $node) { continue }
            if ($null -eq $node.value) { $row[$valueName] = '' } else { $row[$valueName] = $node.value }
            $row[$unitName] = ConvertTo-CostManagementField $node.units
        }
    }
    return $row
}

function Publish-CostManagementDataset {
    param(
        [string]$OutDir,
        [string]$DatasetId,
        [string[]]$Header,
        $Rows
    )
    if ($Rows -is [scriptblock]) { $Rows = @(& $Rows) }
    $partialDir = Join-Path $OutDir '.partial'
    if (-not (Test-Path -LiteralPath $partialDir)) {
        New-Item -ItemType Directory -Path $partialDir | Out-Null
    }
    $partial = Join-Path $partialDir ($DatasetId + '.csv')
    $final = Join-Path $OutDir ($DatasetId + '.csv')
    Write-CostManagementCsv -Path $partial -Header $Header -Rows @($Rows)
    Move-Item -LiteralPath $partial -Destination $final -Force
}

function Get-CostManagementJsonField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            Write-Output -NoEnumerate $Object[$Name]
            return
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        Write-Output -NoEnumerate $property.Value
        return
    }
    return $null
}

function ConvertTo-CostManagementItemList {
    param($Value)
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Value) {
        if ($Value -is [System.Collections.IDictionary] -or $Value -is [string]) {
            $list.Add($Value)
        } else {
            foreach ($item in $Value) {
                if ($null -ne $item) { $list.Add($item) }
            }
        }
    }
    Write-Output -NoEnumerate $list
}

function ConvertTo-CostManagementDate {
    param([string]$Text)
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Text, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)
    if (-not $ok) { throw 'Dates must use yyyy-MM-dd.' }
    return $parsed
}

function Get-CostManagementFilterMonth {
    param([datetime]$Date)
    return ('{0}-{1}' -f $Date.Year, $Date.Month)
}

function New-CostManagementRow {
    param([string]$DatasetId)
    $row = [ordered]@{}
    foreach ($column in (Get-CostManagementSchemaHeader $DatasetId)) { $row[$column] = '' }
    return $row
}

function Write-CostManagementLog {
    param($OutDir, [string]$DatasetId, [datetime]$StartDate, [datetime]$EndDate, $Status, $Body)
    $line = '{0} {1} {2} offset=0 status={3}' -f $DatasetId, $StartDate.ToString('yyyy-MM-dd'), $EndDate.ToString('yyyy-MM-dd'), $Status
    if ($Body) {
        $clean = [string]$Body -replace '(?i)Authorization\s*[:=]\s*\S+', 'Authorization: redacted'
        $clean = $clean -replace '[\r\n]+', ' '
        if ($clean) { $line = $line + ' ' + $clean }
    }
    Add-Content -LiteralPath (Join-Path $OutDir 'export.log') -Value $line -Encoding UTF8
}

function Get-CostManagementAccount {
    param($Session, [string]$ApiBaseUrl, [scriptblock]$Invoke, [scriptblock]$Sleep)
    $currencyResponse = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/currency/' -Session $Session -Invoke $Invoke -Sleep $Sleep
    $settingsResponse = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/account-settings/' -Session $Session -Invoke $Invoke -Sleep $Sleep
    $settings = Get-CostManagementJsonField -Object $settingsResponse.Json -Name 'data'
    $code = [string](Get-CostManagementJsonField -Object $settings -Name 'currency')
    $costType = [string](Get-CostManagementJsonField -Object $settings -Name 'cost_type')
    $match = $null
    foreach ($item in (ConvertTo-CostManagementItemList (Get-CostManagementJsonField -Object $currencyResponse.Json -Name 'data'))) {
        if ([string](Get-CostManagementJsonField -Object $item -Name 'code') -eq $code) { $match = $item }
    }
    return [pscustomobject]@{ Code = $code; CostType = $costType; Currency = $match }
}

function Get-CostManagementDistinctKeys {
    param($Items, [string[]]$Names)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($item in (ConvertTo-CostManagementItemList $Items)) {
        $key = $null
        if ($item -is [string]) {
            $key = [string]$item
        } else {
            foreach ($name in $Names) {
                $found = Get-CostManagementJsonField -Object $item -Name $name
                $scalar = $null -ne $found -and (($found -is [string]) -or -not ($found -is [System.Collections.IEnumerable]))
                if ($scalar) {
                    $key = [string]$found
                    if ($key) { break }
                }
            }
        }
        if ($key -and -not $keys.Contains($key)) { $keys.Add($key) }
    }
    Write-Output -NoEnumerate $keys
}

function Get-CostManagementNamedValues {
    param($Items, [string]$GroupName)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($item in (ConvertTo-CostManagementItemList $Items)) {
        $name = [string](Get-CostManagementJsonField -Object $item -Name $GroupName)
        if (-not $name) { $name = [string](Get-CostManagementJsonField -Object $item -Name 'name') }
        $values = ConvertTo-CostManagementItemList (Get-CostManagementJsonField -Object $item -Name 'values')
        if ($values.Count -eq 0) {
            $list.Add([pscustomobject]@{ Name = $name; Value = $item })
        } else {
            foreach ($value in $values) {
                $list.Add([pscustomobject]@{ Name = $name; Value = $value })
            }
        }
    }
    return $list
}

function ConvertTo-AwsCostRow {
    param($ValueRecord, [string]$CurrencyCode, [string]$CostType, [string]$GroupByCode, [string]$Day, [string]$Name, $TagKey)
    $row = New-CostManagementRow 'AWS_Daily_Costs'
    $row['code'] = $CurrencyCode
    $row['Default_Configurations.data.cost_type'] = $CostType
    $row['Group By Code'] = $GroupByCode
    $row['date'] = $Day
    $row['Name'] = $Name
    $row['key'] = ConvertTo-CostManagementField $TagKey
    if ($null -eq $ValueRecord) { return $row }
    $row['values.date'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $ValueRecord -Name 'date')
    $row['values.source_uuid'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $ValueRecord -Name 'source_uuid')
    $row['values.account_alias'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $ValueRecord -Name 'account_alias')
    $row['type'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $ValueRecord -Name 'type')
    $row['values.alias'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $ValueRecord -Name 'alias')
    foreach ($section in @('infrastructure', 'supplementary', 'cost')) {
        $sectionObject = Get-CostManagementJsonField -Object $ValueRecord -Name $section
        foreach ($child in @('raw', 'markup', 'usage', 'total')) {
            $valueName = "values.$section.$child.value"
            $unitName = "values.$section.$child.units"
            if (-not $row.Contains($valueName)) { continue }
            $node = Get-CostManagementJsonField -Object $sectionObject -Name $child
            if ($null -eq $node) { continue }
            $amount = Get-CostManagementJsonField -Object $node -Name 'value'
            if ($null -eq $amount) { $row[$valueName] = '' } else { $row[$valueName] = $amount }
            $row[$unitName] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $node -Name 'units')
        }
    }
    return $row
}

function Export-CostManagementData {
    param(
        [string]$StartDate,
        [string]$EndDate,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$OutDir,
        [string]$Dataset,
        [string]$ApiBaseUrl,
        [string]$TokenUrl,
        [string]$Scope,
        [scriptblock]$Invoke,
        [scriptblock]$Now,
        [scriptblock]$Sleep
    )
    $start = ConvertTo-CostManagementDate $StartDate
    $end = ConvertTo-CostManagementDate $EndDate
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
    $session = New-CostManagementTokenSession -TokenUrl $TokenUrl -ClientId $ClientId -ClientSecret $ClientSecret -Scope $Scope -Invoke $Invoke -Now $Now
    $period = New-CostManagementRow 'Data_Period'
    $period['Start Date'] = $start.ToString('yyyy-MM-dd')
    $period['End Date'] = $end.ToString('yyyy-MM-dd')
    Publish-CostManagementDataset -OutDir $OutDir -DatasetId 'Data_Period' -Header (Get-CostManagementSchemaHeader 'Data_Period') -Rows @($period)

    $requested = @()
    if ($Dataset) { $requested = @($Dataset) } else { $requested = @(Get-CostManagementDatasetIds) }
    foreach ($datasetId in $requested) {
        if ($datasetId -eq 'Data_Period') { continue }
        try {
            $rows = @(Get-CostManagementDatasetRows -DatasetId $datasetId -StartDate $start -EndDate $end -ApiBaseUrl $ApiBaseUrl -Session $session -Invoke $Invoke -Sleep $Sleep)
            Publish-CostManagementDataset -OutDir $OutDir -DatasetId $datasetId -Header (Get-CostManagementSchemaHeader $datasetId) -Rows $rows
        } catch {
            $status = '500'
            if ([string]$_.Exception.Message -match 'status=(\d+)') { $status = $Matches[1] }
            $body = ''
            if ($_.Exception.Message -notmatch 'status=') { $body = $_.Exception.Message }
            Write-CostManagementLog -OutDir $OutDir -DatasetId $datasetId -StartDate $start -EndDate $end -Status $status -Body $body
            throw
        }
    }
}

function Get-CostManagementDatasetRows {
    param($DatasetId, [datetime]$StartDate, [datetime]$EndDate, [string]$ApiBaseUrl, $Session, [scriptblock]$Invoke, [scriptblock]$Sleep)
    $common = @{ ApiBaseUrl = $ApiBaseUrl; Session = $Session; Invoke = $Invoke; Sleep = $Sleep; StartDate = $StartDate; EndDate = $EndDate }
    switch ($DatasetId) {
        'Default_Master_Settings' { return @(Get-CostManagementSettingsRows @common) }
        'OS_Costs_Daily' { return @(Get-CostManagementOpenShiftCostRows @common) }
        'OS_Tag_Keys' { return @(Get-CostManagementTagKeyRows @common -RelativeUrl '/api/cost-management/v1/tags/openshift/') }
        'OS_Cost_Project_Tags' { return @(Get-CostManagementProjectTagRows @common) }
        'OS_Cost_Cluster_Projects' { return @(Get-CostManagementClusterProjectRows @common) }
        'OS_Daily_Usage' { return @(Get-CostManagementUsageRows @common) }
        'AWS_Daily_Costs' { return @(Get-CostManagementAwsCostRows @common) }
        'AWS_Tag_Keys' { return @(Get-CostManagementTagKeyRows @common -RelativeUrl '/api/cost-management/v1/tags/aws/') }
        'AWS_Cost_Categories' { return @(Get-CostManagementCategoryRows @common) }
        'AWS_Org_Units' { return @(Get-CostManagementOrgRows @common) }
        'Recommendations' { return @(Get-CostManagementRecommendationRows @common) }
        default { throw "Unknown dataset $DatasetId" }
    }
}

function Get-CostManagementSettingsRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $account = Get-CostManagementAccount -Session $Session -ApiBaseUrl $ApiBaseUrl -Invoke $Invoke -Sleep $Sleep
    $row = New-CostManagementRow 'Default_Master_Settings'
    $row['code'] = $account.Code
    $row['Default_Configurations.data.currency'] = $account.Code
    $row['Default_Configurations.data.cost_type'] = $account.CostType
    if ($account.Currency) {
        $row['name'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $account.Currency -Name 'name')
        $row['symbol'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $account.Currency -Name 'symbol')
        $row['description'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $account.Currency -Name 'description')
    }
    return @($row)
}

function Get-CostManagementOpenShiftCostRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $account = Get-CostManagementAccount -Session $Session -ApiBaseUrl $ApiBaseUrl -Invoke $Invoke -Sleep $Sleep
    $tagResponse = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/tags/openshift/?filter[limit]=100&filter[offset]=0' -Session $Session -Invoke $Invoke -Sleep $Sleep
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('project', 'cluster', 'node')) { $groups.Add([pscustomobject]@{ Code = $name; Query = ('group_by[{0}]=*' -f $name); Key = $null }) }
    foreach ($tag in (ConvertTo-CostManagementItemList (Get-CostManagementJsonField -Object $tagResponse.Json -Name 'data'))) {
        $key = [string](Get-CostManagementJsonField -Object $tag -Name 'key')
        if (-not $key -and $tag -is [string]) { $key = [string]$tag }
        if ($key) { $groups.Add([pscustomobject]@{ Code = 'tag'; Query = ('group_by[tag:{0}]=*' -f [uri]::EscapeDataString($key)); Key = $key }) }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($group in $groups) {
        $relative = '/api/cost-management/v1/reports/openshift/costs/?currency=' + [uri]::EscapeDataString($account.Code) + '&filter[resolution]=daily&' + $group.Query
        $items = Get-CostManagementWindowData -StartDate $StartDate -EndDate $EndDate -ApiBaseUrl $ApiBaseUrl -RelativeUrl $relative -Session $Session -Invoke $Invoke -Sleep $Sleep
        foreach ($named in (Get-CostManagementNamedValues -Items $items -GroupName $(if ($group.Code -eq 'tag') { 'tag' } else { $group.Code }))) {
            $rows.Add((ConvertTo-OpenShiftCostRow -CurrencyCode $account.Code -GroupByCode $group.Code -DistributedOverhead $false -Day $StartDate.ToString('yyyy-MM-dd') -Name $named.Name -ValueRecord $named.Value -TagKey $group.Key))
        }
    }
    return $rows
}

function Get-CostManagementProjectTagRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $account = Get-CostManagementAccount -Session $Session -ApiBaseUrl $ApiBaseUrl -Invoke $Invoke -Sleep $Sleep
    $relative = '/api/cost-management/v1/reports/openshift/costs/?currency=' + [uri]::EscapeDataString($account.Code) + '&filter[resolution]=daily&group_by[project]=*'
    $items = Get-CostManagementWindowData -StartDate $StartDate -EndDate $EndDate -ApiBaseUrl $ApiBaseUrl -RelativeUrl $relative -Session $Session -Invoke $Invoke -Sleep $Sleep
    $projects = New-Object System.Collections.Generic.List[string]
    foreach ($named in (Get-CostManagementNamedValues -Items $items -GroupName 'project')) {
        if ($named.Name -and -not $projects.Contains($named.Name)) { $projects.Add($named.Name) }
    }
    $month = Get-CostManagementFilterMonth $EndDate
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($project in $projects) {
        $tagUrl = '/api/cost-management/v1/tags/openshift/?filter[project]=' + [uri]::EscapeDataString($project) + '&filter[limit]=100&filter[offset]=0'
        $tagResponse = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl $tagUrl -Session $Session -Invoke $Invoke -Sleep $Sleep
        foreach ($tag in (ConvertTo-CostManagementItemList (Get-CostManagementJsonField -Object $tagResponse.Json -Name 'data'))) {
            $row = New-CostManagementRow 'OS_Cost_Project_Tags'
            $row['code'] = $account.Code
            $row['date'] = $EndDate.ToString('yyyy-MM-dd')
            $row['project'] = $project
            $row['key'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $tag -Name 'key')
            $row['values'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $tag -Name 'values')
            $row['enabled'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $tag -Name 'enabled')
            $row['Filter Month'] = $month
            $rows.Add($row)
        }
    }
    return $rows
}

function Get-CostManagementTagKeyRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate, [string]$RelativeUrl)
    $response = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl ($RelativeUrl + '?filter[limit]=100&filter[offset]=0') -Session $Session -Invoke $Invoke -Sleep $Sleep
    $datasetId = 'OS_Tag_Keys'
    if ($RelativeUrl -like '*tags/aws*') { $datasetId = 'AWS_Tag_Keys' }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($tag in (ConvertTo-CostManagementItemList (Get-CostManagementJsonField -Object $response.Json -Name 'data'))) {
        $row = New-CostManagementRow $datasetId
        $row['count'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $tag -Name 'count')
        $row['key'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $tag -Name 'key')
        $row['enabled'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $tag -Name 'enabled')
        $row['Group By'] = 'tag'
        $rows.Add($row)
    }
    return $rows
}

function Get-CostManagementClusterProjectRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $account = Get-CostManagementAccount -Session $Session -ApiBaseUrl $ApiBaseUrl -Invoke $Invoke -Sleep $Sleep
    $relative = '/api/cost-management/v1/reports/openshift/costs/?currency=' + [uri]::EscapeDataString($account.Code) + '&filter[resolution]=daily&group_by[cluster]=*'
    $clusters = Get-CostManagementWindowData -StartDate $StartDate -EndDate $EndDate -ApiBaseUrl $ApiBaseUrl -RelativeUrl $relative -Session $Session -Invoke $Invoke -Sleep $Sleep
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($named in (Get-CostManagementNamedValues -Items $clusters -GroupName 'cluster')) {
        if ($named.Name -and -not $names.Contains($named.Name)) { $names.Add($named.Name) }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($cluster in $names) {
        $projectUrl = '/api/cost-management/v1/reports/openshift/costs/?currency=' + [uri]::EscapeDataString($account.Code) + '&filter[resolution]=daily&group_by[project]=*&filter[cluster]=' + [uri]::EscapeDataString($cluster)
        $projects = Get-CostManagementWindowData -StartDate $StartDate -EndDate $EndDate -ApiBaseUrl $ApiBaseUrl -RelativeUrl $projectUrl -Session $Session -Invoke $Invoke -Sleep $Sleep
        foreach ($named in (Get-CostManagementNamedValues -Items $projects -GroupName 'project')) {
            if (-not $named.Name) { continue }
            $amount = Get-CostManagementJsonField -Object (Get-CostManagementJsonField -Object (Get-CostManagementJsonField -Object $named.Value -Name 'cost') -Name 'total') -Name 'value'
            if ($null -eq $amount) { $amount = 0 }
            $row = New-CostManagementRow 'OS_Cost_Cluster_Projects'
            $row['code'] = $account.Code
            $row['Group By Code'] = 'project'
            $row['cluster'] = $cluster
            $row['date'] = $EndDate.ToString('yyyy-MM-dd')
            $row['project'] = $named.Name
            $row['value'] = $amount
            $row['units'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object (Get-CostManagementJsonField -Object (Get-CostManagementJsonField -Object $named.Value -Name 'cost') -Name 'total') -Name 'units')
            $row['Filter Month'] = Get-CostManagementFilterMonth $EndDate
            $rows.Add($row)
        }
    }
    return $rows
}

function Get-CostManagementUsageRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $account = Get-CostManagementAccount -Session $Session -ApiBaseUrl $ApiBaseUrl -Invoke $Invoke -Sleep $Sleep
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('project', 'cluster', 'node')) {
        $groups.Add([pscustomobject]@{ Code = $name; Query = ('group_by[{0}]=*' -f $name); Key = $null })
    }
    $tagResponse = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/tags/openshift/?filter[limit]=100&filter[offset]=0' -Session $Session -Invoke $Invoke -Sleep $Sleep
    foreach ($key in (Get-CostManagementDistinctKeys -Items (Get-CostManagementJsonField -Object $tagResponse.Json -Name 'data') -Names @('key'))) {
        $groups.Add([pscustomobject]@{ Code = 'tag'; Query = ('group_by[tag:{0}]=*' -f [uri]::EscapeDataString($key)); Key = $key })
    }
    $models = @(
        @{ Name = 'compute'; Code = 'cpu' },
        @{ Name = 'memory'; Code = 'memory' },
        @{ Name = 'volumes'; Code = 'volume' }
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($model in $models) {
        foreach ($group in $groups) {
            $relative = '/api/cost-management/v1/reports/openshift/' + $model.Name + '/?currency=' + [uri]::EscapeDataString($account.Code) + '&filter[resolution]=daily&' + $group.Query
            $items = Get-CostManagementWindowData -StartDate $StartDate -EndDate $EndDate -ApiBaseUrl $ApiBaseUrl -RelativeUrl $relative -Session $Session -Invoke $Invoke -Sleep $Sleep
            foreach ($named in (Get-CostManagementNamedValues -Items $items -GroupName $group.Code)) {
                $row = New-CostManagementRow 'OS_Daily_Usage'
                $row['Group By'] = $group.Code
                $row['Group By Code'] = $group.Code
                $row['Usage Code'] = $model.Code
                $row['Usage Name'] = $model.Name
                $row['Key'] = ConvertTo-CostManagementField $group.Key
                $row['date'] = $StartDate.ToString('yyyy-MM-dd')
                $row['Name'] = $named.Name
                $row['meta.currency'] = $account.Code
                foreach ($field in @('usage', 'request', 'limit', 'capacity')) {
                    $node = Get-CostManagementJsonField -Object $named.Value -Name $field
                    if ($row.Contains("values.$field.value")) {
                        $amount = Get-CostManagementJsonField -Object $node -Name 'value'
                        if ($null -ne $amount) { $row["values.$field.value"] = $amount }
                        if ($row.Contains("values.$field.units")) { $row["values.$field.units"] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $node -Name 'units') }
                    }
                }
                $rows.Add($row)
            }
        }
    }
    return $rows
}

function Get-CostManagementAwsCostRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $account = Get-CostManagementAccount -Session $Session -ApiBaseUrl $ApiBaseUrl -Invoke $Invoke -Sleep $Sleep
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('account', 'service', 'region')) { $groups.Add([pscustomobject]@{ Code = $name; Query = ('group_by[{0}]=*' -f $name); Key = $null }) }
    $tagResponse = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/tags/aws/?filter[limit]=100&filter[offset]=0' -Session $Session -Invoke $Invoke -Sleep $Sleep
    foreach ($key in (Get-CostManagementDistinctKeys -Items (Get-CostManagementJsonField -Object $tagResponse.Json -Name 'data') -Names @('key'))) {
        $groups.Add([pscustomobject]@{ Code = 'tag'; Query = ('group_by[tag:{0}]=*' -f [uri]::EscapeDataString($key)); Key = $key })
    }
    $categoryResponse = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/resource-types/aws-categories/?key_only=true' -Session $Session -Invoke $Invoke -Sleep $Sleep
    foreach ($key in (Get-CostManagementDistinctKeys -Items (Get-CostManagementJsonField -Object $categoryResponse.Json -Name 'data') -Names @('key', 'data'))) {
        $groups.Add([pscustomobject]@{ Code = 'aws_category'; Query = ('group_by[aws_category:{0}]=*' -f [uri]::EscapeDataString($key)); Key = $key })
    }
    $orgResponse = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/organizations/aws/' -Session $Session -Invoke $Invoke -Sleep $Sleep
    foreach ($key in (Get-CostManagementDistinctKeys -Items (Get-CostManagementJsonField -Object $orgResponse.Json -Name 'data') -Names @('org_unit_id'))) {
        $groups.Add([pscustomobject]@{ Code = 'org_unit_id'; Query = ('group_by[org_unit_id]={0}' -f [uri]::EscapeDataString($key)); Key = $key })
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($group in $groups) {
        $relative = '/api/cost-management/v1/reports/aws/costs/?currency=' + [uri]::EscapeDataString($account.Code) + '&filter[resolution]=daily&' + $group.Query
        $items = Get-CostManagementWindowData -StartDate $StartDate -EndDate $EndDate -ApiBaseUrl $ApiBaseUrl -RelativeUrl $relative -Session $Session -Invoke $Invoke -Sleep $Sleep
        foreach ($named in (Get-CostManagementNamedValues -Items $items -GroupName $group.Code)) {
            $rows.Add((ConvertTo-AwsCostRow -ValueRecord $named.Value -CurrencyCode $account.Code -CostType $account.CostType -GroupByCode $group.Code -Day $StartDate.ToString('yyyy-MM-dd') -Name $named.Name -TagKey $group.Key))
        }
    }
    return $rows
}

function Get-CostManagementCategoryRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $response = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/resource-types/aws-categories/?key_only=true' -Session $Session -Invoke $Invoke -Sleep $Sleep
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in (ConvertTo-CostManagementItemList (Get-CostManagementJsonField -Object $response.Json -Name 'data'))) {
        $row = New-CostManagementRow 'AWS_Cost_Categories'
        $row['count'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $item -Name 'count')
        $row['data'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $item -Name 'data')
        if (-not $row['data']) { $row['data'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $item -Name 'key') }
        $row['Group By'] = 'aws_category'
        $rows.Add($row)
    }
    return $rows
}

function Get-CostManagementOrgRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $response = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl '/api/cost-management/v1/organizations/aws/' -Session $Session -Invoke $Invoke -Sleep $Sleep
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in (ConvertTo-CostManagementItemList (Get-CostManagementJsonField -Object $response.Json -Name 'data'))) {
        $row = New-CostManagementRow 'AWS_Org_Units'
        $row['count'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $item -Name 'count')
        $row['org_unit_id'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $item -Name 'org_unit_id')
        $row['org_unit_name'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $item -Name 'org_unit_name')
        $row['org_unit_path'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $item -Name 'org_unit_path')
        $row['level'] = ConvertTo-CostManagementField (Get-CostManagementJsonField -Object $item -Name 'level')
        $row['Group By'] = 'org_unit_id'
        $rows.Add($row)
    }
    return $rows
}

function Get-CostManagementRecommendationRows {
    param($ApiBaseUrl, $Session, $Invoke, $Sleep, $StartDate, $EndDate)
    $rows = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        $relative = '/api/cost-management/v1/recommendations/openshift?limit=100&offset=' + $offset
        $response = Invoke-CostManagementGet -ApiBaseUrl $ApiBaseUrl -RelativeUrl $relative -Session $Session -Invoke $Invoke -Sleep $Sleep
        $meta = Get-CostManagementJsonField -Object $response.Json -Name 'meta'
        $countValue = Get-CostManagementJsonField -Object $meta -Name 'count'
        $count = 0
        if ($null -ne $countValue) { $count = [int]$countValue }
        $data = ConvertTo-CostManagementItemList (Get-CostManagementJsonField -Object $response.Json -Name 'data')
        if ($data.Count -eq 0) { break }
        $index = 0
        foreach ($item in $data) {
            $row = New-CostManagementRow 'Recommendations'
            foreach ($column in @($row.Keys)) {
                $value = Get-CostManagementJsonField -Object $item -Name $column
                if ($null -ne $value -and $value -isnot [System.Collections.IDictionary]) { $row[$column] = ConvertTo-CostManagementField $value }
            }
            $row['Index'] = [string]$index
            $terms = Get-CostManagementJsonField -Object $item -Name 'recommendations'
            $map = @{
                'ST Rec Cost Config' = @('short_term', 'cost')
                'ST Rec Perf Config' = @('short_term', 'performance')
                'st.duration_in_hours' = @('short_term', 'duration_in_hours')
                'st.monitoring_start_time' = @('short_term', 'monitoring_start_time')
                'MT Rec Cost Config' = @('medium_term', 'cost')
                'MT Rec Perf Config' = @('medium_term', 'performance')
                'mt.duration_in_hours' = @('medium_term', 'duration_in_hours')
                'mt.monitoring_start_time' = @('medium_term', 'monitoring_start_time')
                'LT Rec Cost Config' = @('long_term', 'cost')
                'LT Rec Perf Config' = @('long_term', 'performance')
                'lt.duration_in_hours' = @('long_term', 'duration_in_hours')
                'lt.monitoring_start_time' = @('long_term', 'monitoring_start_time')
            }
            foreach ($entry in $map.GetEnumerator()) {
                $termName = $entry.Value[0]
                $fieldName = $entry.Value[1]
                $term = Get-CostManagementJsonField -Object $item -Name $termName
                if ($null -eq $term) { $term = Get-CostManagementJsonField -Object $terms -Name $termName }
                if ($null -eq $term) { continue }
                $field = Get-CostManagementJsonField -Object $term -Name $fieldName
                if ($null -ne $field) { $row[$entry.Key] = ConvertTo-CostManagementField $field }
            }
            $rows.Add($row)
            $index++
        }
        $offset += 100
        if ($offset -ge $count) { break }
    }
    return $rows
}








