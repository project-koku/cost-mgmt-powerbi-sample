# PowerShell CSV loader Implementation Plan

This plan is done. The script, tests, schema files, static lookups, report queries, and docs below are in the repository. The Excel workbooks and the Excel-only screenshots are gone. [Issue 1](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/1) and [issue 7](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/7) are closed. [Issue 2](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/2), [issue 3](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/3), [issue 4](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/4), and [issue 5](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/5) are closed as no-ops. Those four datasets were not added.

**Goal:** Replace the Excel workbooks with a Windows PowerShell 5.1 exporter that writes CSV, and point `PowerBI/CostManagement.pbix` at those files.

**Architecture:** `scripts/Export-CostManagement.ps1` is the entry point. It dot-sources `scripts/CostManagementExport.ps1`, which holds help text, token handling, paging, flattening, and CSV writing. Tests in `scripts/Export-CostManagement.Tests.ps1` call those functions with recorded JSON and never touch the network. `schema/*.columns.txt` is the column contract, copied from the workbooks before those workbooks were deleted.

**Tech Stack:** Windows PowerShell 5.1, Power BI Desktop for the `.pbix` query change, no extra modules.

## Global Constraints

- Runtime is Windows PowerShell 5.1. Do not require PowerShell 7, Pester, Excel, or SQLite.
- Download JSON. Write UTF-8 CSV with a byte order mark. A null list, a null list item, or a missing field becomes an empty CSV field.
- `-Help` lists every in-scope dataset id, `yyyy-MM-dd`, `-Test`, and `-TestProxy`. It reads no auth file and makes no network call. Exit 0. `-Help` wins when `-Test` or `-TestProxy` is also passed.
- `-TestProxy` prints `proxy token:` and `proxy api:` and does not read `auth.csv`. Lines are `direct`, `bypassed`, `scheme://host:port` with no userinfo, or `failed`. Exit 1 when either line starts with `proxy token: failed` or `proxy api: failed`.
- `-Test` prints those proxy lines first. A failed proxy check exits 1 without reading `auth.csv`. Otherwise it reads `auth.csv`, requests a token, then `GET {ApiBaseUrl}/api/cost-management/v1/account-settings/`. It writes no CSV. The credential line is `credentials: accepted` (exit 0), `credentials: rejected`, `permissions: denied`, `connection: failed`, or `api: failed` (exit 1). Never print the client secret, the access token, or proxy credentials.
- Requests use the Windows system proxy for that URL. A bypass is reported as `bypassed` and connects directly. A selected proxy that fails is not retried as a direct connection. Enable TLS 1.2 before the first HTTPS call.
- Date parameters use `yyyy-MM-dd`. Default `-StartDate` is 30 days before today, local time. Default `-EndDate` is yesterday, local time.
- `-ApiBaseUrl` defaults to `https://console.redhat.com`. `-TokenUrl` defaults to `https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token`. `-Scope` defaults to `api.console`.
- The client secret is sent only to `-TokenUrl`. Data requests go only to `-ApiBaseUrl`. Never write the secret or the access token to the log or a CSV.
- Page size is 100. Stop when the next offset is greater than or equal to `meta.count`, or when `data` is empty.
- Retry HTTP 429 and 5xx three times, pausing 2 seconds, then 4, then 8. Then split a multi-day window into two contiguous halves. A failed single-day window fails the dataset.
- Refresh the token when it is 4 minutes old, and once after HTTP 401. A second 401 fails the dataset.
- Write each dataset under `data/export/.partial/` and move it into `data/export/` only after that dataset succeeds. A failure leaves the previous CSV in place. Exit 0 only when every requested dataset succeeded.
- `Data_Period` is written on every run, including a run that names one other dataset.
- `auth.csv` and `data/export/` stay gitignored.
- Keep report pages, relationships, measures, and calculated tables. Do not add Azure, Google Cloud, or new report pages.
- Workbook headers are in `schema/`. The workbooks are gone.
- `AWS_Cost_Account_Tags`, `AWS_Group_By_Account`, `AWS_Group_By_Service`, and `AWS_Group_By_Region` were not added. [Issue 2](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/2), [issue 3](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/3), [issue 4](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/4), and [issue 5](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/5) are closed as no-ops. Account, service, and region rows stay in `AWS_Daily_Costs`. Tag and cost-category costs stay in that same file.

---

## Test plan: red, green, refactor

The test plan is this implementation plan. There is no second document. Every task followed the same cycle.

1. **Red.** Add the assertion to `scripts/Export-CostManagement.Tests.ps1` before the production code exists. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. The new assertion must fail. A pass at this step means the test is not exercising new behavior.
2. **Green.** Write the smallest code that makes the whole script print `ALL PASS` and exit 0.
3. **Refactor.** With the tests still passing, rename for clarity and remove duplication. Do not add behavior, parameters, or datasets in this step. Run the same test script again. Expected: `ALL PASS`.

The tests call functions with recorded HTTP responses. They do not call the network. `-Test` is covered by those recorded responses, not by a live service account. A live `-Test` against a real account stays a manual check after the unit tests are green.

## File structure

- `scripts/CostManagementExport.ps1` — functions. No top-level execution.
- `scripts/Export-CostManagement.ps1` — parameters, `-Help`, and the run.
- `scripts/Export-CostManagement.Tests.ps1` — assertions. Dot-sources the function file.
- `schema/<DatasetId>.columns.txt` — one header line per dataset.
- `data/static/OpenShift_Group_Bys.csv`, `data/static/Project_Overhead_Cost_Types.csv`, `data/static/AWS_Group_Bys.csv`
- `data/export/` — created at runtime, gitignored.
- `PowerBI/*.pq` — text copy of the report queries after the Desktop edit.
- `README.md`, `design/README.MD`, `AGENTS.md` — supported workflow.

Dataset ids, in this order: `Data_Period`, `Default_Master_Settings`, `OS_Costs_Daily`, `OS_Cost_Project_Tags`, `OS_Cost_Cluster_Projects`, `OS_Tag_Keys`, `OS_Daily_Usage`, `AWS_Daily_Costs`, `AWS_Tag_Keys`, `AWS_Cost_Categories`, `AWS_Org_Units`, `Recommendations`.

---

### Task 1: Help text and the test runner

**Files:**
- Create: `scripts/CostManagementExport.ps1`
- Create: `scripts/Export-CostManagement.ps1`
- Create: `scripts/Export-CostManagement.Tests.ps1`

**Interfaces:**
- Consumes: nothing
- Produces: `Get-CostManagementDatasetIds` returns `[string[]]` in the order above. `Get-CostManagementHelpText` returns one `[string]`. The entry script accepts `-Help` as a `[switch]`.

- [x] **Step 1: Write the failing test**

Create `scripts/Export-CostManagement.Tests.ps1`:

```powershell
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

$entry = Join-Path $PSScriptRoot 'Export-CostManagement.ps1'
$out = & powershell.exe -NoProfile -File $entry -Help
Assert-True 'help switch exit 0' ($LASTEXITCODE -eq 0)
Assert-True 'help switch prints a dataset' ($out -join "`n" -match 'OS_Costs_Daily')

if ($script:Failed -gt 0) { exit 1 }
Write-Host "ALL PASS"
exit 0
```

- [x] **Step 2: Run the test and confirm it fails**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: a parse or command-not-found error because `Get-CostManagementHelpText` does not exist yet. Exit code is not 0.

- [x] **Step 3: Implement help**

Create `scripts/CostManagementExport.ps1` with `Get-CostManagementDatasetIds` and `Get-CostManagementHelpText`. The help string must include `yyyy-MM-dd`, every dataset id, both default URLs, `-Scope` default `api.console`, `-TestProxy`, and three examples: a full run, `-Dataset OS_Costs_Daily`, and a self-managed run that sets `-TokenUrl` and `-ApiBaseUrl`.

Create `scripts/Export-CostManagement.ps1` with comment-based help (`.SYNOPSIS`, `.PARAMETER`, `.EXAMPLE`) and:

```powershell
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$TestProxy,
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

throw 'Export is not implemented yet.'
```

`-Help` must be handled before any auth or network code.

- [x] **Step 4: Run the test and confirm it passes**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS` and exit 0.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add scripts/CostManagementExport.ps1 scripts/Export-CostManagement.ps1 scripts/Export-CostManagement.Tests.ps1
git commit -m "Add Cost Management exporter help text and test runner."
```

---

### Task 2: Null-safe CSV writing

**Files:**
- Modify: `scripts/CostManagementExport.ps1`
- Modify: `scripts/Export-CostManagement.Tests.ps1`

**Interfaces:**
- Consumes: `Get-CostManagementDatasetIds`
- Produces: `ConvertTo-CostManagementField ([object]$Value) -> [string]`. `Write-CostManagementCsv ([string]$Path, [string[]]$Header, [object[]]$Rows)` where each row is an `[ordered]` dictionary keyed by header name. The file is UTF-8 with BOM. The header is written when `$Rows` is empty.

- [x] **Step 1: Write the failing test**

Append assertions:

```powershell
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
```

`ConvertTo-CostManagementField` joins a list with a comma and skips null items. A scalar null returns `''`.

- [x] **Step 2: Run the test and confirm it fails**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: FAIL because `ConvertTo-CostManagementField` is missing. Exit code 1.

- [x] **Step 3: Implement the two functions**

`Write-CostManagementCsv` quotes a field when it contains a comma, a quote, or a newline. Quotes inside a field are doubled. Create the parent directory if it is missing.

- [x] **Step 4: Run the test and confirm it passes**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS`.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add scripts/CostManagementExport.ps1 scripts/Export-CostManagement.Tests.ps1
git commit -m "Write null-safe UTF-8 CSV for Cost Management exports."
```

---

### Task 3: Token client

**Files:**
- Modify: `scripts/CostManagementExport.ps1`
- Modify: `scripts/Export-CostManagement.Tests.ps1`

**Interfaces:**
- Consumes: nothing from Task 2
- Produces: `New-CostManagementTokenSession` with parameters `TokenUrl`, `ClientId`, `ClientSecret`, `Scope`, `Invoke`, `Now`. `Invoke` is a `[scriptblock]` called as `& $Invoke -Method POST -Uri ... -Headers ... -Body ...`. It returns an object with `StatusCode` and `Json`. `Get-CostManagementAccessToken -Session $session` returns the bearer token string and refreshes when `Now` is 4 minutes past `IssuedAt`.

- [x] **Step 1: Write the failing test**

Use a fake `$Invoke` that records URIs and returns `access_token = 'tok-1'` the first time and `'tok-2'` the second time. Assert the first URI equals the supplied `-TokenUrl` (`https://keycloak.example.com/token`), the body contains `grant_type=client_credentials`, `scope=api.console`, and the client id, and the body does not get copied into a log variable. Advance `Now` by 5 minutes and assert the second token is `tok-2`.

- [x] **Step 2: Run the test and confirm it fails**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: FAIL on the missing token function.

- [x] **Step 3: Implement the session**

Store `IssuedAt` from the `Now` scriptblock. Do not log `ClientSecret` or `access_token`.

- [x] **Step 4: Run the test and confirm it passes**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS`.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add scripts/CostManagementExport.ps1 scripts/Export-CostManagement.Tests.ps1
git commit -m "Refresh the Cost Management token on a four-minute timer."
```

---

### Task 3b: -Test credential check

**Files:**
- Modify: `scripts/CostManagementExport.ps1`
- Modify: `scripts/Export-CostManagement.ps1`
- Modify: `scripts/Export-CostManagement.Tests.ps1`

**Interfaces:**
- Consumes: `New-CostManagementTokenSession` and `Get-CostManagementAccessToken` from Task 3. `Invoke` returns `StatusCode` and `Json`.
- Produces: `Test-CostManagementCredentials` parameters `ClientId`, `ClientSecret`, `ApiBaseUrl`, `TokenUrl`, `Scope`, `Invoke`. Returns an object with `ExitCode` and `Message`. The entry script's `-Test` switch prints `Message` and exits with `ExitCode`. It does not create files under `data/export`.

- [x] **Step 1: Write the failing test**

Write a separate fake `Invoke` scriptblock for each case. Do not share one scriptblock closed over parameters. PowerShell 5.1 will not capture those parameters reliably.

Rejected credentials: token URI returns status 401. Assert `Message` starts with `credentials: rejected` and `ExitCode` is 1.

Denied permissions: token returns 200, account-settings URI returns 403. Assert `Message` starts with `permissions: denied`. Assert the account-settings URI is `https://cost.example.com/api/cost-management/v1/account-settings/`.

Accepted: both return 200. Assert `Message` starts with `credentials: accepted` and `ExitCode` is 0.

Connection failure: the scriptblock throws before returning a status. Assert `Message` starts with `connection: failed`.

Call each case with `-ClientSecret 'client-secret-value'`. Assert `Message` does not contain `client-secret-value` and does not contain `access_token`. Run the entry script with `-Help -Test` and assert exit 0 and that the output contains `yyyy-MM-dd`. `-Help` must not read `auth.csv`. The fake `Invoke` is passed only into `Test-CostManagementCredentials`.

- [x] **Step 2: Run the test and confirm it fails**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: FAIL because `Test-CostManagementCredentials` does not exist.

- [x] **Step 3: Implement -Test**

`Test-CostManagementCredentials` calls the token URL, then `GET` `$ApiBaseUrl + '/api/cost-management/v1/account-settings/'` with `Authorization: Bearer <token>`. Map statuses to the credential lines in the spec. The entry script handles `-Test` only when `-Help` is absent, after the functions are loaded, and before any export directory is created. Task 3c adds the proxy lines in front of this result.

- [x] **Step 4: Run the test and confirm it passes**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS`.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add scripts/CostManagementExport.ps1 scripts/Export-CostManagement.ps1 scripts/Export-CostManagement.Tests.ps1
git commit -m "Test Cost Management credentials before exporting."
```

---

### Task 3c: System proxy

**Files:**
- Modify: `scripts/CostManagementExport.ps1`
- Modify: `scripts/Export-CostManagement.ps1`
- Modify: `scripts/Export-CostManagement.Tests.ps1`

**Interfaces:**
- Consumes: nothing from the network. Tests pass `-GetProxy` and `-Connect`.
- Produces:
  - `Get-CostManagementProxyDecision -Uri [uri] -GetProxy` returns `Choice` (`direct`, `bypassed`, `proxy`, or `failed`) and `ProxyUri` with userinfo removed.
  - `Test-CostManagementProxy -TokenUrl -ApiBaseUrl -GetProxy -Connect` returns `ExitCode` and `Message`. `Message` is two lines, `proxy token:` then `proxy api:`.
  - `Invoke-CostManagementWebRequest` applies that decision and enables TLS 1.2. Export code in Task 7 calls it.
  - Entry `-TestProxy` prints `Message` and exits with `ExitCode`. It does not read `auth.csv`.
  - `Invoke-CostManagementTest` parameters `TokenUrl`, `ApiBaseUrl`, `GetProxy`, `Connect`, `ReadAuth`. It runs the proxy check first. When the proxy check fails, it does not call `ReadAuth`.
  - Entry `-Test` calls `Invoke-CostManagementTest`. When the proxy check fails, it prints the proxy message and exits 1 without reading `auth.csv`.

- [x] **Step 1: Write the failing test**

Use a separate fake for each case.

No proxy: `-GetProxy` returns no proxy. Assert `Message` is `proxy token: direct` then `proxy api: direct`, and `ExitCode` is 0.

Bypass: `-GetProxy` reports the token URL bypassed. Assert the token line is `proxy token: bypassed`.

Proxy with userinfo: `-GetProxy` returns `http://user:secret@proxy.example.com:8080` and `-Connect` returns an HTTP status. Assert `Message` contains `http://proxy.example.com:8080` and does not contain `user:secret`.

Proxy failure: the same proxy, and `-Connect` throws. Assert the token line is `proxy token: failed http://proxy.example.com:8080` and `ExitCode` is 1. Call the entry helper that runs the proxy check before reading auth, and pass a `-ReadAuth` scriptblock. Assert that scriptblock is not called.

`-Help -TestProxy` exits 0. The unit tests do not run a live `-TestProxy`, because that would use the machine proxy and the network.

- [x] **Step 2: Run the test and confirm it fails**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: FAIL because `Test-CostManagementProxy` does not exist.

- [x] **Step 3: Implement the proxy check**

`GetSystemWebProxy` is the production `-GetProxy`. `IsBypassed` selects `bypassed`. A returned proxy selects `proxy` and the request uses `DefaultNetworkCredentials`. A throw from proxy lookup or from `-Connect` selects `failed`. Do not connect directly after `failed`. Strip userinfo before printing or logging the proxy URI. `-Help` still exits before this code.

- [x] **Step 4: Run the test and confirm it passes**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS`.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add scripts/CostManagementExport.ps1 scripts/Export-CostManagement.ps1 scripts/Export-CostManagement.Tests.ps1
git commit -m "Report the system proxy before sending Cost Management credentials."
```

---

### Task 4: Paging, retries, and date splits

**Files:**
- Modify: `scripts/CostManagementExport.ps1`
- Modify: `scripts/Export-CostManagement.Tests.ps1`

**Interfaces:**
- Consumes: `New-CostManagementTokenSession`
- Produces:
  - `Split-CostManagementDateWindow -StartDate [datetime] -EndDate [datetime]` returns `$null` when the window is one day, otherwise two contiguous `[pscustomobject]` windows `{ StartDate; EndDate }` that cover every day once.
  - `Invoke-CostManagementGet` parameters: `ApiBaseUrl`, `RelativeUrl`, `Session`, `Invoke`. On 401, refresh once and retry. On 429 or 5xx, retry up to 3 times.
  - `Get-CostManagementPages` parameters: `GetPage` scriptblock `(int $Offset) -> object with Count and Data`. Page size 100. Stops on empty `Data` or when the next offset is past `Count`.

- [x] **Step 1: Write the failing tests**

Cover all four cases from the spec:

- A `GetPage` whose first call returns `Count = 250` and 100 rows, then 100, then 50, is called with offsets 0, 100, and 200 only.
- HTTP 500 three times on a one-day window throws. HTTP 500 once, then success on each half, returns both halves' rows in date order.
- HTTP 401 once causes one token refresh and one retry against the same API URL. The token URL in the refresh is the session's `TokenUrl`, not `console.redhat.com`.
- `Invoke-CostManagementGet -ApiBaseUrl https://cost.example.com -RelativeUrl '/api/cost-management/v1/reports/openshift/costs/?filter[limit]=100'` requests exactly `https://cost.example.com/api/cost-management/v1/reports/openshift/costs/?filter[limit]=100`.

- [x] **Step 2: Run the test and confirm it fails**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: FAIL on the missing paging functions.

- [x] **Step 3: Implement paging**

`Split-CostManagementDateWindow` splits by day count, first half smaller or equal when the count is odd. Pauses for retries are a `[scriptblock] $Sleep` argument so tests pass `-Sleep { }` and production passes `Start-Sleep -Seconds`.

- [x] **Step 4: Run the test and confirm it passes**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS`.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add scripts/CostManagementExport.ps1 scripts/Export-CostManagement.Tests.ps1
git commit -m "Page Cost Management JSON and split a failed date window."
```

---

### Task 5: Schema files and static lookups

**Files:**
- Create: `schema/*.columns.txt` for every dataset id
- Create: `data/static/OpenShift_Group_Bys.csv`
- Create: `data/static/Project_Overhead_Cost_Types.csv`
- Create: `data/static/AWS_Group_Bys.csv`
- Modify: `scripts/Export-CostManagement.Tests.ps1`

**Interfaces:**
- Consumes: dataset ids from Task 1
- Produces: `Get-CostManagementRepoRoot` returns the absolute repo root (parent of `scripts/`). `Get-CostManagementSchemaHeader ([string]$DatasetId)` returns `[string[]]` by reading `schema/<DatasetId>.columns.txt` under that root.

- [x] **Step 1: Write the failing test**

```powershell
$header = Get-CostManagementSchemaHeader 'OS_Costs_Daily'
Assert-True 'os costs has source_uuid' ($header -contains 'values.source_uuid')
Assert-True 'os costs has clusters' ($header -contains 'values.clusters')
Assert-True 'static group by file exists' (Test-Path (Join-Path (Get-CostManagementRepoRoot) 'data/static/OpenShift_Group_Bys.csv'))
$overhead = Get-Content -Raw (Join-Path (Get-CostManagementRepoRoot) 'data/static/Project_Overhead_Cost_Types.csv')
Assert-True 'overhead keeps two spaces' ($overhead.Contains("Don't distribute  overhead costs"))
```

The two spaces are between `distribute` and `overhead`. One space fails this assertion.

- [x] **Step 2: Run the test and confirm it fails**

Expected: FAIL because the schema file is missing.

- [x] **Step 3: Write the schema files and static CSVs**

`schema/OS_Costs_Daily.columns.txt` is one line:

```text
code,Group By Code,meta.distributed_overhead,date,Name,values.date,values.classification,values.source_uuid,values.clusters,values.infrastructure.raw.value,values.infrastructure.raw.units,values.infrastructure.markup.value,values.infrastructure.markup.units,values.infrastructure.usage.value,values.infrastructure.usage.units,values.infrastructure.total.value,values.infrastructure.total.units,values.supplementary.raw.value,values.supplementary.raw.units,values.supplementary.markup.value,values.supplementary.markup.units,values.supplementary.usage.value,values.supplementary.usage.units,values.supplementary.total.value,values.supplementary.total.units,values.cost.raw.value,values.cost.raw.units,values.cost.markup.value,values.cost.markup.units,values.cost.usage.value,values.cost.usage.units,values.cost.platform_distributed.value,values.cost.platform_distributed.units,values.cost.worker_unallocated_distributed.value,values.cost.worker_unallocated_distributed.units,values.cost.distributed.value,values.cost.distributed.units,values.cost.total.value,values.cost.total.units,values.delta_percent,key,values.delta_value
```

Write the other headers from the workbook tables, one file each:

| File | Header |
| --- | --- |
| `Data_Period.columns.txt` | `Start Date,End Date` |
| `Default_Master_Settings.columns.txt` | `code,name,symbol,description,Default_Configurations.data.currency,Default_Configurations.data.cost_type` |
| `OS_Cost_Cluster_Projects.columns.txt` | `code,Group By Code,cluster,date,project,value,units,Filter Month` |
| `OS_Tag_Keys.columns.txt` | `count,key,enabled,Group By` |
| `OS_Cost_Project_Tags.columns.txt` | `code,date,project,key,values,enabled,Filter Month` |
| `OS_Daily_Usage.columns.txt` | `Group By,Group By Code,Usage Code,Usage Name,Key,meta.count,meta.currency,date,Name,values.usage.value,values.usage.units,values.request.value,values.request.units,values.request.unused,values.request.unused_percent,values.limit.value,values.limit.units,values.capacity.value,values.capacity.units,values.capacity.unused,values.capacity.unused_percent,values.capacity.count,values.capacity.count_units` |
| `AWS_Daily_Costs.columns.txt` | `code,Default_Configurations.data.cost_type,Group By Code,date,Name,values.date,values.source_uuid,values.account_alias,values.infrastructure.raw.value,values.infrastructure.raw.units,values.infrastructure.markup.value,values.infrastructure.markup.units,values.infrastructure.usage.value,values.infrastructure.usage.units,values.infrastructure.total.value,values.infrastructure.total.units,values.supplementary.raw.value,values.supplementary.raw.units,values.supplementary.markup.value,values.supplementary.markup.units,values.supplementary.usage.value,values.supplementary.usage.units,values.supplementary.total.value,values.supplementary.total.units,values.cost.raw.value,values.cost.raw.units,values.cost.markup.value,values.cost.markup.units,values.cost.usage.value,values.cost.usage.units,values.cost.total.value,values.cost.total.units,key,type,values.alias` |
| `AWS_Tag_Keys.columns.txt` | `count,key,enabled,Group By` |
| `AWS_Cost_Categories.columns.txt` | `count,data,Group By` |
| `AWS_Org_Units.columns.txt` | `count,org_unit_id,org_unit_name,org_unit_path,level,Group By` |
| `Recommendations.columns.txt` | `Load Time,cluster_alias,cluster_uuid,container,id,last_reported_time,project,source_id,workload,workload_type,monitoring_end_time,Index,Current configuration,ST Rec Cost Config,ST Rec Perf Config,st.duration_in_hours,st.monitoring_start_time,mt.duration_in_hours,mt.monitoring_start_time,MT Rec Cost Config,MT Rec Perf Config,LT Rec Cost Config,LT Rec Perf Config,lt.duration_in_hours,lt.monitoring_start_time` |

Static files, including the double space in the overhead description:

```text
Group By,Group By Code
Cluster,cluster
Node,node
Project,project
Tag,tag
```

```text
Code,Description
cost,Don't distribute  overhead costs
distributed_cost,Distribute through cost models
```

```text
Group By,Group By Code
Account,account
Region,region
Service,service
Tag,tag
Organization,org_unit_id
Cost category,aws_category
```

- [x] **Step 4: Run the test and confirm it passes**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS`.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add schema data/static scripts/CostManagementExport.ps1 scripts/Export-CostManagement.Tests.ps1
git commit -m "Record Cost Management CSV column contracts and static lookups."
```

---

### Task 6: Flatten a cost row and publish one dataset file

**Files:**
- Modify: `scripts/CostManagementExport.ps1`
- Modify: `scripts/Export-CostManagement.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-CostManagementField`, `Write-CostManagementCsv`, `Get-CostManagementSchemaHeader`
- Produces: `ConvertTo-OpenShiftCostRow` parameters `CurrencyCode`, `GroupByCode`, `DistributedOverhead`, `Day`, `Name`, `ValueRecord`, `TagKey`. Returns an `[ordered]` row whose keys are the `OS_Costs_Daily` header. `Publish-CostManagementDataset` parameters `OutDir`, `DatasetId`, `Header`, `Rows`. Writes `OutDir/.partial/<DatasetId>.csv`, then moves it to `OutDir/<DatasetId>.csv`. On throw before the move, the previous `OutDir/<DatasetId>.csv` stays.

- [x] **Step 1: Write the failing test**

Build one JSON value object:

```powershell
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
```

Then call `Publish-CostManagementDataset` twice into a temp directory: first with one row, then with a scriptblock that throws before returning rows. Assert the CSV from the first publish is still the file in the temp directory.

- [x] **Step 2: Run the test and confirm it fails**

Expected: FAIL on `ConvertTo-OpenShiftCostRow`.

- [x] **Step 3: Implement the flattener**

Map `infrastructure`, `supplementary`, and `cost` children `raw`, `markup`, `usage`, `total` to `values.<section>.<child>.value` and `.units`. Also map `cost.platform_distributed`, `cost.worker_unallocated_distributed`, and `cost.distributed`. Leave any header key that has no source as `''`.

- [x] **Step 4: Run the test and confirm it passes**

Expected: `ALL PASS`.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add scripts/CostManagementExport.ps1 scripts/Export-CostManagement.Tests.ps1
git commit -m "Flatten OpenShift cost rows without failing on nulls."
```

---

### Task 7: Export orchestration for every dataset

**Files:**
- Modify: `scripts/CostManagementExport.ps1`
- Modify: `scripts/Export-CostManagement.ps1`
- Modify: `scripts/Export-CostManagement.Tests.ps1`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: paging, token session, publish, schema headers, OpenShift cost flattener
- Produces: `Export-CostManagementData` parameters `StartDate`, `EndDate`, `ClientId`, `ClientSecret`, `OutDir`, `Dataset`, `ApiBaseUrl`, `TokenUrl`, `Scope`, `Invoke`, `Now`, `Sleep`. Returns nothing. Exit is the entry script's job: catch a failed dataset, write `OutDir/export.log`, and `exit 1`.

Dataset behavior:

- `Data_Period`: columns `Start Date`, `End Date`, one row per export window, dates `yyyy-MM-dd`. A later run keeps earlier windows and stores the same start and end once. Written even when `-Dataset` names another id.
- `Default_Master_Settings`: `GET /api/cost-management/v1/currency/` and `GET /api/cost-management/v1/account-settings/`. Join on currency code. Replace the file only when the catalog returns HTTP 200 and includes that code. Otherwise keep the previous file.
- `OS_Costs_Daily`: for group codes `project`, `cluster`, `node`, and each key from `GET /api/cost-management/v1/tags/openshift/`, call `/api/cost-management/v1/reports/openshift/costs/` with `currency`, `filter[resolution]=daily`, `start_date`, `end_date`, `filter[limit]=100`, `filter[offset]`, and `group_by[<code>]=*` or `group_by[tag:<key>]=*`. Request one calendar month at a time. Flatten each nested value with `ConvertTo-OpenShiftCostRow`. `date` is that value's day.
- `OS_Tag_Keys`: tags endpoint, paged with `limit` and `offset`. Columns `count`, `key`, `enabled`, and `Group By` set to `tag`. HTTP 200 replaces the file. Any other status keeps the previous file.
- `OS_Cost_Project_Tags`: for each distinct project, `GET /api/cost-management/v1/tags/openshift/?filter[project]=...` once. Write the tags once per calendar month in the window. `date` is the first of that month. `Filter Month` is that month's year, a hyphen, and the month number without a leading zero. September 2026 writes `2026-9`. The test asserts that exact string. `2026-09` fails. A later run replaces a month when the new window overlaps it.
- `OS_Cost_Cluster_Projects`: for each distinct cluster, costs grouped by project. `date` and `Filter Month` come from each value's day. `value` null becomes `0`, matching the workbook's replace step. Drop rows whose project is null.
- `OS_Daily_Usage`: usage models `compute` (Usage Code `cpu`), `memory`, `volumes` (Usage Code `volume`). Endpoints `/api/cost-management/v1/reports/openshift/<model>/`. Group by project, cluster, node, and tag key. `date` is each value's day. Copy `value`, `units`, `unused`, `unused_percent`, `count`, and `count_units` when the schema has that column.
- `AWS_Daily_Costs`: `/api/cost-management/v1/reports/aws/costs/` grouped by `account`, `service`, `region`, each AWS tag, each cost category (`aws_category:<key>`), and each org unit. Same null rules and per-day `date` as OpenShift. `ConvertTo-AwsCostRow` fills the AWS header, including `values.account_alias`, `key`, `type`, and `values.alias`.
- `AWS_Tag_Keys`: `/api/cost-management/v1/tags/aws/`.
- `AWS_Cost_Categories`: `/api/cost-management/v1/resource-types/aws-categories/?key_only=true` with no page parameters. A string in `data` is the category name.
- `AWS_Org_Units`: `/api/cost-management/v1/organizations/aws/`.
- `Recommendations`: page `GET /api/cost-management/v1/recommendations/openshift` with `limit` and `offset`. One CSV row per recommendation. `last_reported` is written to `last_reported_time`. `monitoring_end_time` comes from `recommendations`. Current configuration text comes from `recommendations.current`. Short, medium, and long term duration, start time, and cost and performance text come from `recommendations.recommendation_terms`. A missing term leaves those columns empty. A non-200 keeps the previous file.

`export.log` lines look like `OS_Costs_Daily 2026-09-01 2026-09-01 offset=0 status=500`. Do not write response bodies that contain an `Authorization` header. Strip that header if a body is logged.

`.gitignore` gains a line `data/export/`.

- [x] **Step 1: Write failing tests for settings, one OpenShift cost page, project tags for September 2026, an AWS host check, recommendations with a null term, and a failed single-day page**

The project-tags test uses `-EndDate 2026-09-30` and asserts `Filter Month` equals `2026-9`.

The host test asserts the costs URL starts with `https://cost.example.com/api/cost-management/v1/reports/openshift/costs/`.

The failed-page test is:

```powershell
$out = Join-Path $env:TEMP ("cm-export-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $out | Out-Null
$previous = "previous-row`n"
Set-Content -Path (Join-Path $out 'OS_Costs_Daily.csv') -Value $previous -NoNewline
$invoke = {
    param($Method, $Uri, $Headers, $Body)
    if ($Uri -like '*/token') {
        return [pscustomobject]@{ StatusCode = 200; Json = @{ access_token = 'tok'; expires_in = 300 } }
    }
    return [pscustomobject]@{ StatusCode = 500; Json = $null; Body = 'unavailable' }
}
try {
    Export-CostManagementData -StartDate '2026-09-01' -EndDate '2026-09-01' -ClientId 'id' -ClientSecret 'secret' -OutDir $out -Dataset 'OS_Costs_Daily' -ApiBaseUrl 'https://cost.example.com' -TokenUrl 'https://keycloak.example.com/token' -Scope 'api.console' -Invoke $invoke -Now { Get-Date } -Sleep { }
    Assert-True 'failed day throws' $false
} catch {
    Assert-True 'failed day throws' $true
}
Assert-True 'previous csv kept' ((Get-Content -Raw (Join-Path $out 'OS_Costs_Daily.csv')) -eq $previous)
Assert-True 'log has status 500' ((Get-Content -Raw (Join-Path $out 'export.log')) -match 'status=500')
Remove-Item $out -Recurse -Force
```

The recommendations test feeds one recommendation whose short-term object is `$null` and asserts `ST Rec Cost Config` is empty while `cluster_uuid` is copied.

- [x] **Step 2: Run the test and confirm it fails**

Expected: FAIL on `Export-CostManagementData`.

- [x] **Step 3: Implement `Export-CostManagementData` and the entry script**

The entry script reads `auth.csv` only after `-Help` is handled. Default `-AuthFile` is `<repo>/data/auth.csv`. Default `-OutDir` is `<repo>/data/export`. Parse dates as `yyyy-MM-dd` and throw a message that names that format when parsing fails. Pass `Start-Sleep` as `-Sleep`.

Production requests go through `Invoke-CostManagementWebRequest` from Task 3c, which applies the system proxy and TLS 1.2. The underlying call is `Invoke-WebRequest` on Windows PowerShell 5.1. A 4xx or 5xx throws. Catch that exception, read `StatusCode` from `$_.Exception.Response`, and return the same object the tests return: `StatusCode`, `Json`, `Body`. Do not use `-SkipHttpErrorCheck`. That parameter is not in Windows PowerShell 5.1.

Cost and usage URLs use `filter[limit]` and `filter[offset]`. The recommendations URL uses `limit` and `offset`.

- [x] **Step 4: Run the test and confirm it passes**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS`.

Also run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.ps1 -Help`

Expected: exit 0 and the dataset list.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add scripts .gitignore
git commit -m "Export Cost Management datasets to CSV with recorded-response tests."
```

---

### Task 8: Docs, and delete the Excel workbooks

Done. `CostManagement.pbix` reads CSV. The workbooks and the unreferenced Excel images are gone.

**Files:**
- Modify: `README.md`
- Modify: `design/README.MD`
- Modify: `AGENTS.md`
- Delete: `data/Hello.xlsx`
- Delete: `data/cost_management_data/AWS_Daily_Costs.xlsx`
- Delete: `data/cost_management_data/OpenShift_Daily_Costs.xlsx`
- Delete: `data/cost_management_data/OpenShift_Daily_Usage.xlsx`
- Delete: `data/cost_management_data/Optimizations.xlsx`
- Delete images that the rewritten docs no longer reference: `images/Excel_Connection_Access.png`, `images/Excel_Connection_Access_Additional.png`, `images/Excel_Costs_Connection_Authentication.png`, `images/Excel_Privacy_Error.png`, `images/PowerBI_Data_Source.png`, `images/PowerBI_Source_Settings.png`, `design/images/Excel_Date_Period.png`, `design/images/Logical_Architecture.png`, `design/images/Physical_Architecture.png`

**Interfaces:**
- Consumes: the entry script's parameters from Task 7
- Produces: a README whose setup path is auth file, `-Help`, export, Power BI refresh

- [x] **Step 1: Rewrite `README.md`**

Required sections, in order:

1. What the sample is: Cost Management data in `PowerBI/CostManagement.pbix`.
2. Requirements: Windows PowerShell 5.1, Power BI Desktop, a service account.
3. Credentials: copy `auth.csv.sample` to `data/auth.csv`.
4. See datasets and date format: `powershell.exe -File scripts/Export-CostManagement.ps1 -Help`.
5. Check the proxy: `powershell.exe -File scripts/Export-CostManagement.ps1 -TestProxy`. Document `direct`, `bypassed`, a proxy host with no userinfo, and `failed`.
6. Check the service account: `powershell.exe -File scripts/Export-CostManagement.ps1 -Test`. Document `credentials: accepted`, `credentials: rejected`, `permissions: denied`, and `connection: failed`.
7. SaaS export: `powershell.exe -File scripts/Export-CostManagement.ps1`.
8. Self-managed export: same command with `-TokenUrl` and `-ApiBaseUrl`.
9. Refresh `PowerBI/CostManagement.pbix`.
10. Failures: read `data/export/export.log`, then rerun with `-Dataset` and a shorter date window. Refresh the report only after the script exits 0.

Remove Excel setup, Excel refresh, Excel performance, and Excel troubleshooting. Do not leave a legacy Excel section.

- [x] **Step 2: Rewrite `design/README.MD`**

Describe service account to Keycloak token URL to Cost Management API to PowerShell to `data/export` CSV to Power BI. Keep the API paths and the report page names that are still true. Remove the Power Query function catalog as the supported design. Remove image links whose files this task deletes.

- [x] **Step 3: Align `AGENTS.md`**

State that the Excel workbooks are gone, tests are `powershell.exe -File scripts/Export-CostManagement.Tests.ps1`, and `-ApiBaseUrl` / `-TokenUrl` are the on-prem switches.

- [x] **Step 4: Delete the workbooks and unreferenced images**

Confirm `schema/` already contains the headers from Task 5 before deleting any `.xlsx`.

- [x] **Step 5: Run the tests**

Run: `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`

Expected: `ALL PASS`.

- [x] **Step 6: Refactor**

Re-read `README.md` and `design/README.MD` and remove any leftover Excel setup steps. Do not add datasets. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 7: Commit**

```powershell
git add README.md design/README.MD AGENTS.md
git add -u data images design/images
git commit -m "Document the CSV export workflow and remove the Excel workbooks."
```

---

### Task 9: Point the Power BI report at the CSV files

**Files:**
- Modify: `PowerBI/CostManagement.pbix` in Power BI Desktop
- Create: `PowerBI/OS_Costs_Daily.pq` and one `.pq` file per query whose source changes

**Interfaces:**
- Consumes: CSV paths from Task 7 and static files from Task 5
- Produces: a report parameter `DataFolder`. `PowerBI/DataFolder.pq` stores the placeholder `C:\path\to\cost-mgmt-powerbi-sample\data`. Queries read `DataFolder\export\<file>.csv` and `DataFolder\static\<file>.csv`. Before the first refresh, set `DataFolder` in Power BI Desktop to this clone's `data` directory. Power BI loads the path saved in `DataModel`.

- [x] **Step 1: Open `PowerBI/CostManagement.pbix` in Power BI Desktop**

Apply this task in Power BI Desktop. Do not leave it as a click-path for the user. This step cannot be done by editing the binary `DataModel`. If Desktop is not installed, or a sign-in dialog cannot be completed, stop this task and say which dialog is open. Do not commit a hand-edited `DataModel`.

- [x] **Step 2: Add the `DataFolder` parameter and replace each Excel source**

Example for the OpenShift daily cost query. Repeat the same shape for each exported CSV the report loads, and for the three static files:

```powerquery
let
    Source = Csv.Document(File.Contents(DataFolder & "\export\OS_Costs_Daily.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Typed = Table.TransformColumns(Promoted, {{"values.cost.total.value", each if _ = null or _ = "" then null else Number.From(_), type number}}),
    Dated = Table.TransformColumns(Typed, {{"date", each if _ = null or _ = "" then null else Date.From(_), type date}})
in
    Dated
```

Apply that pattern to every numeric column (names ending in `.value`, `.unused`, `.unused_percent`, `delta_percent`, `delta_value`, or the column `value`) and every date or time column (`date`, `values.date`, `Start Date`, `End Date`, and names ending in `_time` or `Time`). An empty field becomes null. `Number.From` and `Date.From` must not see a null or a blank, or the refresh raises the same "cannot convert the value null" error this work is removing.

Keep the existing calculated tables (`DateTable`, `MonthTable`, monthly cost, monthly usage), relationships, measures, and report pages. Keep the blank tag, cost-category, and org-unit rows that already live in the report's Power Query.

- [x] **Step 3: Save each changed query as text**

Write `PowerBI/Data_Period.pq`, `PowerBI/Default_Master_Settings.pq`, `PowerBI/OS_Costs_Daily.pq`, `PowerBI/OS_Cost_Project_Tags.pq`, `PowerBI/OS_Cost_Cluster_Projects.pq`, `PowerBI/OS_Tag_Keys.pq`, `PowerBI/OS_Daily_Usage.pq`, `PowerBI/AWS_Daily_Costs.pq`, `PowerBI/AWS_Tag_Keys.pq`, `PowerBI/AWS_Cost_Categories.pq`, `PowerBI/AWS_Org_Units.pq`, `PowerBI/Recommendations.pq`, `PowerBI/OpenShift_Group_Bys.pq`, `PowerBI/Project_Overhead_Cost_Types.pq`, and `PowerBI/AWS_Group_Bys.pq`.

- [x] **Step 4: Refresh the report against a folder that contains the static CSVs and a header-only export**

Header-only files are enough to prove the queries promote headers. A live service-account refresh stays manual and is not part of the unit tests.

- [x] **Step 5: Refactor**

With the tests from this task still passing, simplify names and remove duplication. Do not add behavior. Run `powershell.exe -NoProfile -File scripts/Export-CostManagement.Tests.ps1`. Expected: `ALL PASS`.

- [x] **Step 6: Commit**

```powershell
git add PowerBI/CostManagement.pbix PowerBI
git commit -m "Load Cost Management CSVs in the Power BI report."
```

Skip this commit if Desktop was unavailable. Report that the `.pbix` is unchanged.
