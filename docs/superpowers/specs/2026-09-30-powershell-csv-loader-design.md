# PowerShell CSV loader for the Cost Management Power BI sample

Date: 2026-09-30
Branch: `pgarciaq-powershell`
Status: approved

## Purpose

Put Red Hat Cost Management data into `PowerBI/CostManagement.pbix` without the Excel refresh that fails with `We cannot convert the value null to type Text`.

The report stays the FinOps deliverable. The Excel workbooks are only a feeder. This design replaces that feeder with Windows PowerShell, which writes CSV files the report imports.

## Problem

`OpenShift_Daily_Costs.xlsx` flattens `source_uuid` and `clusters` with this Power Query step, repeated for projects, clusters, nodes, and tags:

```powerquery
Text.Combine(List.Transform(_, Text.From), ",")
```

`Text.From` of a null value is the error `We cannot convert the value null to type Text`. A one-day window still contains those fields, so a shorter `Data_Period` does not avoid it. That matches the 20 Aug 2026 note on [COST-8048](https://redhat.atlassian.net/browse/COST-8048).

A second path produces the same family of errors on large accounts. The workbooks page with `API_Limit = 10`. A failed response is stored with `try ... otherwise null`, and a later step then types that null as text, a number, or a list. The service-account token lifetime documented in `design/README.MD` is 5 minutes. [COST-7717](https://redhat.atlassian.net/browse/COST-7717) describes the API behavior behind slow pages: the service materializes the full query, then slices `limit` and `offset`.

The sample also pins `auth` to `C:\git\cost-mgmt-powerbi-sample\data\auth.csv` inside the workbook.

## Decision

A PowerShell 5.1 script downloads JSON from the Cost Management API, flattens it with null-safe conversion, and writes one CSV per worksheet the report already reads. `PowerBI/CostManagement.pbix` then reads that folder.

JSON is the download format. CSV is the file format Power BI reads. The API can return `text/csv` (see the [API cheat sheet](https://github.com/project-koku/costmgmt-api-cheatsheet)), and that native CSV does not use the column names the report already imports. Reproducing those names in the script keeps the existing visuals, measures, and calculated tables.

Windows PowerShell 5.1 is the runtime because it is present on Windows. The script does not require PowerShell 7, Excel, SQLite, or any other install.

Power BI Import mode (VertiPaq) remains the analytical store. No embedded database is added.

Cost Management should keep emitting data. It should not generate `.pbix` files. A generated report binary is tied to a Power BI Desktop version, and FinOps teams need to change visuals themselves. The product change that still matters for large accounts is COST-7717. This sample does not wait on it.

## Non-goals

- Changing Cost Management pagination or token lifetime.
- Generating `.pbix` files from the service.
- Adding Azure, Google Cloud, or new report pages. The script covers the tables the current report loads.
- Changing the report pages or the formulas that already run inside the report. Power BI calls that formula language DAX (Data Analysis Expressions). DAX builds the date table, the monthly rollups, and the measures behind the charts. This work changes where each table's rows come from. It leaves those formulas and the page layout as they are.
- Storing the client secret anywhere except `auth.csv`.

## Users and constraints

The operator is a FinOps user on Windows with Power BI Desktop. They already have a Cost Management service account, either on console.redhat.com or on a self-managed Cost Management instance. They can run a script and refresh a report. They may not have rights to install runtimes or database engines.

Scheduled refresh in the Power BI service stays a gateway over local files.

## Architecture

```
auth.csv + ApiBaseUrl + TokenUrl
   |
   v
Export-CostManagement.ps1
   |  HTTPS JSON, Bearer token, paged
   v
Token URL (Keycloak) and Cost Management API base URL
   |
   v
data/export/*.csv          data/static/*.csv
   \                      /
    v                    v
   PowerBI/CostManagement.pbix
```

SaaS defaults are `https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token` and `https://console.redhat.com`. A self-managed instance passes its own Keycloak token URL and its own Cost Management host.

`data/static/` holds lookup sheets that the workbooks hard-code (group-by lists and overhead cost types). `data/export/` holds account data produced by a run. Export files are gitignored. Static files are committed.

## Components

### `scripts/Export-CostManagement.ps1`

One script, Windows PowerShell 5.1.

Parameters:

| Parameter | Meaning |
| --- | --- |
| `-Help` | Print usage and exit 0. No auth file is read and no network call is made. `-Help` wins when `-Test` or `-TestProxy` is also passed. |
| `-TestProxy` | Report the proxy choice for `-TokenUrl` and `-ApiBaseUrl`, then exit. Does not read `auth.csv` and does not send the client secret. |
| `-Test` | Check the proxy, then the service account, then exit. Reads `auth.csv` only after the proxy check succeeds. Does not write CSV files. |
| `-StartDate` | First day to request, `yyyy-MM-dd`. Default: 30 days before today, local time. |
| `-EndDate` | Last day to request, `yyyy-MM-dd`. Default: yesterday, local time. |
| `-AuthFile` | Path to `auth.csv`. Default: `data/auth.csv` beside the repo root, resolved from the script location. |
| `-OutDir` | Directory for CSV output. Default: `data/export`. |
| `-Dataset` | Optional dataset id. When omitted, the script runs every dataset. |
| `-ApiBaseUrl` | Cost Management origin, plus a path prefix if the install uses one. Default: `https://console.redhat.com`. |
| `-TokenUrl` | Keycloak token endpoint. Default: `https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token`. |
| `-Scope` | OAuth scope sent with the token request. Default: `api.console`. |

The script resolves the repo root from its own path. It does not embed `C:\git\...`.

`-Help` prints:

- The date format `yyyy-MM-dd`, and the defaults for `-StartDate` and `-EndDate`.
- Every dataset id accepted by `-Dataset`, with the CSV file that id writes.
- The defaults for `-ApiBaseUrl`, `-TokenUrl`, and `-Scope`.
- Examples: `-TestProxy`, `-Test`, a full run, one dataset, and a self-managed instance that sets `-TokenUrl` and `-ApiBaseUrl`.

The same text is stored as PowerShell comment-based help, so `Get-Help .\scripts\Export-CostManagement.ps1 -Full` shows it too. `-Help` is the path documented for FinOps users.

`-TestProxy` resolves the Windows system proxy for `-TokenUrl` and for `-ApiBaseUrl`, tries each URL through that choice, and prints two lines:

| Situation | Line |
| --- | --- |
| No proxy is configured for that URL | `proxy token: direct` or `proxy api: direct` |
| A proxy exists and Windows bypasses it for that URL | `proxy token: bypassed` or `proxy api: bypassed` |
| A proxy is used | `proxy token: http://proxy.example.com:8080` (the proxy's own scheme, host, and port) |
| A proxy was selected and no HTTP response came back | `proxy token: failed http://proxy.example.com:8080` |
| Proxy settings could not be read | `proxy token: failed` |

The token line is first, then the API line. Any HTTP status counts as a response, including 401. Exit 0 when neither line starts with `proxy token: failed` or `proxy api: failed`. Exit 1 otherwise. The script does not read `auth.csv` and does not send the client secret. A proxy URL in the output has no username and no password.

`-Test` prints those same two lines first. If either line starts with `proxy token: failed` or `proxy api: failed`, it exits 1 and does not read `auth.csv`. Otherwise it requests a token, then calls `GET {ApiBaseUrl}/api/cost-management/v1/account-settings/`. It does not print the client secret or the access token. The credential line is one of:

| Result | Exit | Credential line |
| --- | --- | --- |
| Token received and account settings returned HTTP 200 | 0 | `credentials: accepted` |
| Token endpoint returned HTTP 400 or 401 | 1 | `credentials: rejected` |
| Token succeeded and the API returned HTTP 401 or 403 | 1 | `permissions: denied` |
| No HTTP response (DNS, TLS, or connection failure) | 1 | `connection: failed` |

`credentials: rejected` means the client id, client secret, token URL, or scope was not accepted. `permissions: denied` means the service account authenticated and Cost Management refused the call. Any other HTTP status from account settings exits 1 with the credential line `api: failed` and the status code.

Dataset ids for this implementation are the CSV file names without `.csv`: `Data_Period`, `Default_Master_Settings`, `OS_Costs_Daily`, `OS_Cost_Project_Tags`, `OS_Cost_Cluster_Projects`, `OS_Tag_Keys`, `OS_Daily_Usage`, `AWS_Daily_Costs`, `AWS_Tag_Keys`, `AWS_Cost_Categories`, `AWS_Org_Units`, and `Recommendations`. `Data_Period` is written on every run from `-StartDate` and `-EndDate`, including a run that names one other dataset.

These datasets are not in the current workbooks or report. They are left for a later iteration so the first implementation does not invent them. Account, service, and region rows remain inside `AWS_Daily_Costs`.

- [AWS cost account tags](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/2)
- [AWS group-by account CSV](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/3)
- [AWS group-by service CSV](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/4)
- [AWS group-by region CSV](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/5)

The first implementation is tracked in [issue 1](https://github.com/pgarciaq/cost-mgmt-powerbi-sample/issues/1).

### `data/static/`

Committed CSV files for worksheets that do not come from the API:

- OpenShift group-by list
- Project overhead cost types (distributed and non-distributed)
- AWS group-by list

Header rows match the current worksheets. The blank tag, cost-category, and org-unit rows stay in the report's Power Query, where they already live.

`data/static/Project_Overhead_Cost_Types.csv` keeps the workbook text for the non-distributed row. The description is exactly `Don't distribute  overhead costs`, with two spaces between `distribute` and `overhead`. The unit test reads that file and requires those two spaces. One space fails the test.

### `schema/`

One text file per exported CSV. Each file is the header row, comma-separated. Implementation reads those headers from the current workbooks first, commits `schema/`, and then deletes the workbooks. After that, `schema/` is the column contract. Tests compare script output to these files.

### Power BI

The report queries that today read Excel worksheets are switched to the CSV files with the same headers. Report pages, relationships, measures, and calculated tables stay. `DataModel` inside the `.pbix` is a binary, so the query change is made in Power BI Desktop and the M for those queries is also saved under `powerbi/` as plain text for review.

## Authentication

`auth.csv` stays the credential file. The header row is `client_id,client_secret`, as in `auth.csv.sample`. The file remains gitignored.

The script requests a token with `grant_type=client_credentials` and `-Scope` from `-TokenUrl`. The SaaS default is the Red Hat external realm. A self-managed install passes the Keycloak URL that issues tokens for that Cost Management.

It refreshes the token when the token is 4 minutes old, and again when a call returns HTTP 401. One 401 retry is allowed per request. A second 401 fails that dataset.

The script never writes the client secret or the access token to the log or to a CSV.

## Proxy

Every token request and every API request uses the signed-in user's Windows system proxy (`GetSystemWebProxy`) for that URL.

- No proxy for the URL: connect directly.
- Windows marks the URL as bypassed: connect directly and report `bypassed`. The script reports that choice. It does not hide it.
- A proxy is returned: send the request through it and attach the user's default network credentials, so an authenticated proxy can succeed. The proxy address stored in the log or in `-TestProxy` output has no username and no password.
- The proxy was selected and the call produces no HTTP response: stop. Do not try the same URL directly. A direct fallback would hide a proxy the operator expected to use.
- There is no parameter that disables the proxy. The operator changes that in Windows Internet Settings.

Before the first HTTPS call, the script enables TLS 1.2. Windows PowerShell 5.1 does not always negotiate it, and a missing TLS 1.2 handshake would otherwise look like `connection: failed`.

## API calls and paging

Endpoint paths below are joined to `-ApiBaseUrl`. The SaaS default base is `https://console.redhat.com`. A self-managed install uses its own host.

The script calls the same report families the workbooks call:

| Dataset | Endpoint |
| --- | --- |
| OpenShift daily costs | `/api/cost-management/v1/reports/openshift/costs/` |
| OpenShift daily usage | `/api/cost-management/v1/reports/openshift/{compute,memory,volumes}/` |
| OpenShift tag keys | `/api/cost-management/v1/tags/openshift/` |
| AWS daily costs | `/api/cost-management/v1/reports/aws/costs/` |
| AWS tag keys | `/api/cost-management/v1/tags/aws/` |
| AWS cost categories | `/api/cost-management/v1/resource-types/aws-categories/` |
| AWS org units | `/api/cost-management/v1/organizations/aws/` |
| Optimizations | `/api/cost-management/v1/recommendations/openshift` |
| Currency and account settings | `/api/cost-management/v1/currency/` and `/api/cost-management/v1/account-settings/` |

OpenShift cost group-bys: project, cluster, node, and each tag key. AWS cost group-bys: account, service, region, each tag key, each cost category, and each org unit. Usage group-bys: project, cluster, node, and each tag key, for compute, memory, and volumes.

Each cost or usage request sends `currency` from account settings, `filter[resolution]=daily`, `start_date`, `end_date`, `filter[limit]`, and `filter[offset]`. Page size is 100. The script reads `meta.count` from JSON and stops when the next offset is greater than or equal to that count. An empty `data` array ends the loop even if `meta.count` is missing.

Cost and usage windows are downloaded one calendar month at a time. 1 August 2026 through 5 September 2026 is requested as 1 August through 31 August, then 1 September through 5 September. A start or end that falls inside a month is kept. Inside a month, a page is retried up to 3 times on HTTP 429 or 5xx, with a pause of 2 seconds, then 4, then 8. If the page still fails and that month is more than one day, the script splits it into two contiguous halves and downloads each half. A failed single-day window fails the dataset. An HTTP 400 is not split.

## Flattening and nulls

A cost or usage report is nested. Each `data` item is a day. That day contains the group array: `projects`, `clusters`, `nodes`, `tags`, `accounts`, `services`, `regions`, `aws_categories`, or `org_entities`. Each group contains `values`. The script writes one CSV row per value.

`date` is that value's own day for OpenShift costs, AWS costs, usage, and cluster projects. `values.date` stays the API value. OpenShift costs, AWS costs, and usage do not write `Filter Month`; Power BI derives it from `date`. Cluster-project rows write `Filter Month` from that same day: the year, a hyphen, and the month number with no leading zero. 15 August 2026 is `2026-8`. `2026-08` is wrong.

Project tags are written once per calendar month in the window, not once per day. The tag list is requested once per project. `date` is the first day of that month, including when the window starts later in the month. `Filter Month` uses the same year-hyphen-month form. A window from 1 August 2026 through 5 September 2026 writes `2026-8` on `2026-08-01` and `2026-9` on `2026-09-01`. A window of only September 2026 still writes `2026-9`.

Nested cost objects are expanded to the same dotted column names the workbooks produce, including `values.cost.total.value` and the infrastructure and supplementary value/unit pairs.

List fields, including `source_uuid` and `clusters`, are joined with a comma. A null list, a null item inside a list, or a missing field becomes an empty CSV field. The script does not call a conversion that rejects null.

Numbers stay numbers in the CSV. Dates are `yyyy-MM-dd`.

## CSV outputs

Files are UTF-8 with a byte order mark, so Excel can open them if someone double-clicks a file. The header row is always written, including when the account has zero rows.

API-backed files, written under `data/export/`:

| File | What a run writes |
| --- | --- |
| `Data_Period.csv` | One row per export window. A later run adds a window and keeps earlier windows. The same start and end are stored once. |
| `Default_Master_Settings.csv` | Currency name, symbol, description, and cost type. Replaced when the currency catalog returns HTTP 200 and includes the account currency. Otherwise the previous file stays. |
| `OS_Costs_Daily.csv` | Daily OpenShift costs. A later run replaces rows whose `date` is inside the new window and keeps the other days. |
| `OS_Cost_Project_Tags.csv` | Project tags once per month. A later run replaces a month when the new window overlaps that month. |
| `OS_Cost_Cluster_Projects.csv` | One row per project day on each cluster. A later run replaces days inside the new window. |
| `OS_Tag_Keys.csv` | OpenShift tag keys, replacing the file |
| `OS_Daily_Usage.csv` | Daily usage. A later run replaces days inside the new window. |
| `AWS_Daily_Costs.csv` | Daily AWS costs. A later run replaces days inside the new window. |
| `AWS_Tag_Keys.csv` | AWS tag keys, replacing the file |
| `AWS_Cost_Categories.csv` | AWS cost categories, replacing the file |
| `AWS_Org_Units.csv` | AWS org units, replacing the file |
| `Recommendations.csv` | OpenShift recommendations, replacing the file |

A dataset is written to `data/export/.partial/` and moved into `data/export/` only after every page for that dataset succeeds. A failed dataset leaves the previous CSV in place.

## Failure behavior

The log file is `data/export/export.log`. Each page records the dataset name, the date window, the offset, and the HTTP status. Response bodies are written only for failures, with the `Authorization` header removed.

Exit code 0 means every requested dataset was replaced. Any failed dataset returns exit code 1. Datasets that finished are updated. The dataset that failed keeps its previous CSV, and the log names it. Refresh the report only after a run that exits 0. A failed run is not a supported source for the report, because some fact tables would be from this run and others from the previous one.

## Power BI report

Implementation updates `PowerBI/CostManagement.pbix` in Power BI Desktop:

1. Point the worksheet queries at the CSV files in `data/export` and `data/static`.
2. Keep column names, relationships, report pages, and the calculated tables (`DateTable`, `MonthTable`, and the monthly cost and usage tables).
3. Save the M for the changed queries under `powerbi/` so the diff is readable. The `.pbix` remains the file FinOps users open.

The folder path inside the report is a parameter, defaulting to the repo's `data` directory, so the user does not edit a hard-coded `C:\git\...` path.

## Documentation and Excel workbooks

The new `.pbix` reads CSV. The Excel workbooks cannot feed it, so this change deletes them:

- `data/Hello.xlsx`
- `data/cost_management_data/AWS_Daily_Costs.xlsx`
- `data/cost_management_data/OpenShift_Daily_Costs.xlsx`
- `data/cost_management_data/OpenShift_Daily_Usage.xlsx`
- `data/cost_management_data/Optimizations.xlsx`

Header rows are copied into `schema/` before those files are deleted.

The same change rewrites the docs so the supported workflow is the script, then the report:

- `README.md` describes credentials, `-Help`, dates, SaaS and self-managed URLs, the export, and the Power BI refresh. Excel setup, Excel refresh, and Excel performance troubleshooting come out.
- `design/README.MD` describes PowerShell to CSV to Power BI. The Power Query function catalog is removed as the supported design. API endpoint and report-page descriptions that are still true stay.
- `AGENTS.md` matches this spec.
- README screenshots that only show the Excel refresh are deleted, along with any image that no remaining doc links.

There is no legacy Excel section.

## Security

- `auth.csv` stays untracked.
- `data/export/` is gitignored, including CSV files, the partial directory, and `export.log`. Exported files contain customer cost data.
- The log redacts credentials, including a username or password embedded in a proxy URL.
- Each run sends the client secret only to `-TokenUrl`, and data requests only to `-ApiBaseUrl`. SaaS defaults are `sso.redhat.com` and `console.redhat.com`. A self-managed Cost Management uses the operator's Keycloak URL and their own API host. The script does not send credentials to any other host.

## Repository layout

```
scripts/Export-CostManagement.ps1          entry point
scripts/CostManagementExport.ps1           functions, dot-sourced by the entry point and the tests
scripts/Export-CostManagement.Tests.ps1    unit tests, no network
data/static/*.csv
data/export/                  gitignored, created by a run
schema/*.columns.txt
powerbi/                      M for the CSV-backed queries
PowerBI/CostManagement.pbix   updated in Power BI Desktop
README.md                     supported workflow
design/README.MD              architecture
AGENTS.md
docs/superpowers/specs/2026-09-30-powershell-csv-loader-design.md
```

`.gitignore` gains `data/export/`.

## Testing

The script needs unit tests. The failures this design replaces were inside binary workbooks, so a later edit could put a bad null conversion or a dropped column back in with nothing to catch it. Tests lock the behavior that FinOps users rely on.

Pester is the common PowerShell test tool, and it is not part of Windows. These tests stay a plain script, `scripts/Export-CostManagement.Tests.ps1`, so anyone with Windows PowerShell 5.1 can run them:

```
powershell.exe -File scripts/Export-CostManagement.Tests.ps1
```

Exit code 0 means every assertion passed. The tests dot-source `scripts/CostManagementExport.ps1` and call functions with recorded JSON. They do not call the network, and they do not need a module install.

Assertions:

- `-Help` lists every dataset id and the date format `yyyy-MM-dd`, mentions `-Test` and `-TestProxy`, and it does not read `auth.csv`.
- `-TestProxy` with no system proxy prints `proxy token: direct` and `proxy api: direct`, does not read `auth.csv`, and exits 0.
- `-TestProxy` with a recorded proxy `http://user:secret@proxy.example.com:8080` prints `http://proxy.example.com:8080` and does not print `user:secret`.
- `-TestProxy` with that proxy and a failed connection prints `proxy token: failed http://proxy.example.com:8080`, exits 1, and does not send the client secret.
- A recorded bypass prints `proxy token: bypassed`.
- `-Test` with a recorded token HTTP 401 prints `credentials: rejected`, writes no CSV, and exits 1.
- `-Test` with a recorded token HTTP 200 and account-settings HTTP 403 prints `permissions: denied` and exits 1.
- `-Test` with both calls HTTP 200 prints `credentials: accepted` and exits 0.
- A recorded JSON page with a null `source_uuid` list, a null item inside `clusters`, and a missing cost object writes empty CSV fields.
- The header of each fixture result equals the matching file in `schema/`.
- A recorded HTTP 500 on a single-day window fails the dataset, writes no file into `data/export/`, and leaves an existing CSV unchanged.
- A recorded HTTP 401 refreshes the token once and retries. The retried token request uses the configured `-TokenUrl`.
- A window that fails once and then succeeds on each half is concatenated in date order with one header row.
- A run with a non-default `-ApiBaseUrl` requests `https://cost.example.com/api/cost-management/v1/...` and sends the token request only to the configured `-TokenUrl`.
- `OS_Cost_Project_Tags` for end date `2026-09-30` writes `Filter Month` as `2026-9`.
- A nested cost page with an August value and a September value writes both days. The requests are 1 August through 31 August and 1 September through 5 September.
- Project tags for 1 August 2026 through 5 September 2026 write `2026-8` on `2026-08-01` and `2026-9` on `2026-09-01`.
- A later run keeps fact rows outside the new window, replaces project-tag months the window overlaps, and keeps earlier `Data_Period` windows. Settings stay one replaced row.
- A currency catalog returned as one object copies `name`, `symbol`, and `description`.
- A currency HTTP 404 leaves the previous settings description in place and logs `status=404`.
- A currency catalog with no item for the account currency leaves the previous settings description in place and logs `status=200` and `currency catalog has no match`.
- `data/static/Project_Overhead_Cost_Types.csv` contains `Don't distribute  overhead costs` with two spaces.

A live run against a service account is a manual check: currency, account settings, and one OpenShift project day, then a full export, then refresh `CostManagement.pbix` and confirm the existing pages show rows. That live check is not part of the unit tests. SaaS and a self-managed instance are both valid targets for it.

## FinOps workflow

1. Copy `auth.csv.sample` to `data/auth.csv` and set the service-account client id and secret.
2. Run `powershell.exe -File scripts/Export-CostManagement.ps1 -Help` to see dataset ids, the `yyyy-MM-dd` date format, and the URL parameters.
3. Run `powershell.exe -File scripts/Export-CostManagement.ps1 -TestProxy`. On a self-managed instance, add `-TokenUrl` and `-ApiBaseUrl`. `direct` means no proxy is configured. `bypassed` means Windows is skipping the proxy for that host. A proxy URL means the script will use it. `failed` means stop and fix the proxy. The script will not switch to a direct connection.
4. Run `powershell.exe -File scripts/Export-CostManagement.ps1 -Test` with the same URL parameters. `credentials: accepted` means continue. `credentials: rejected` means fix the client id, client secret, token URL, or scope. `permissions: denied` means the service account needs a Cost Management role. `connection: failed` means the host did not answer after the proxy check succeeded.
5. Run `powershell.exe -File scripts/Export-CostManagement.ps1`. On a self-managed instance, add the same `-TokenUrl` and `-ApiBaseUrl`.
6. Open `PowerBI/CostManagement.pbix` and refresh.
7. If a dataset fails, read `data/export/export.log` for the dataset, the date window, and the HTTP status. Re-run with `-Dataset` and a shorter `-StartDate`/`-EndDate` while the log still shows a failure.

## Success criteria

- `-Help` lists every dataset id and `yyyy-MM-dd`, and makes no network call.
- `-TestProxy` shows `direct`, `bypassed`, the proxy host, or `failed`, and it does not read `auth.csv`.
- `-Test` distinguishes rejected credentials, denied permissions, and a failed connection, and it writes no CSV. A failed proxy check exits before the client secret is sent.
- `scripts/Export-CostManagement.Tests.ps1` exits 0.
- A fixture containing null list items produces a CSV and does not raise a type-conversion error.
- A failed API page is an HTTP status in the log, and the previous CSV for that dataset remains in place.
- The report loads the CSV folder and keeps its current pages and formulas.
- `README.md` and `design/README.MD` describe the script and the report. The Excel workbooks are gone.
- SaaS works with the default URLs. A self-managed instance works by passing `-TokenUrl` and `-ApiBaseUrl`.
- No component beyond Windows PowerShell 5.1 and Power BI Desktop is required.
