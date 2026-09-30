# Cost Management Power BI sample

This sample loads Red Hat Cost Management data into `PowerBI/CostManagement.pbix`.

A Windows PowerShell 5.1 script downloads JSON from the Cost Management API and writes CSV files. Power BI Desktop imports those files. The report keeps its existing pages, measures, and calculated tables.

## Requirements

- Windows PowerShell 5.1
- Power BI Desktop
- A Cost Management service account (`client_id` and `client_secret`)

## Credentials

Copy `auth.csv.sample` to `data/auth.csv` and replace the sample values with the service account client id and client secret. `data/auth.csv` is not committed.

## See datasets and date format

```powershell
powershell.exe -File scripts/Export-CostManagement.ps1 -Help
```

Dates use `yyyy-MM-dd`. When you omit them, the start date is 30 days before today and the end date is yesterday, in local time.

## Check the proxy

```powershell
powershell.exe -File scripts/Export-CostManagement.ps1 -TestProxy
```

This check does not read `auth.csv` and does not send the client secret. It prints two lines, `proxy token:` and `proxy api:`:

- `direct` — no proxy applies
- `bypassed` — a proxy is configured and this host skips it
- `scheme://host:port` — the script will use this proxy; user names and passwords are not printed
- `failed` or `failed scheme://host:port` — the proxy could not be used

The script exits 1 when either line starts with `proxy token: failed` or `proxy api: failed`.

## Check the service account

```powershell
powershell.exe -File scripts/Export-CostManagement.ps1 -Test
```

`-Test` checks the proxy first. When the proxy check fails, it exits 1 without reading `auth.csv`. Otherwise it requests a token and calls the account-settings API. It prints one of:

- `credentials: accepted` — exit 0
- `credentials: rejected` — the token endpoint rejected the client id or secret
- `permissions: denied` — the account cannot call the API
- `connection: failed` — the host could not be reached

It does not print the client secret or the access token.

## SaaS export

```powershell
powershell.exe -File scripts/Export-CostManagement.ps1
```

This uses `https://console.redhat.com` and the Red Hat SSO token endpoint. CSV files are written to `data/export/`. The script exits 0 only when every requested dataset succeeds.

## Self-managed export

Pass the Cost Management API host and the Keycloak token URL:

```powershell
powershell.exe -File scripts/Export-CostManagement.ps1 -TokenUrl https://keycloak.example.com/token -ApiBaseUrl https://cost.example.com
```

## Refresh the report

Open `PowerBI/CostManagement.pbix` in Power BI Desktop and refresh it. The `DataFolder` parameter defaults to this repository's `data` directory. Queries read `DataFolder\export\<file>.csv` and `DataFolder\static\<file>.csv`.

Refresh the report only after the export script exits 0.

## Failures

Read `data/export/export.log`. A failed request is recorded with its HTTP status. Rerun a single dataset over a shorter window:

```powershell
powershell.exe -File scripts/Export-CostManagement.ps1 -Dataset OS_Costs_Daily -StartDate 2026-09-01 -EndDate 2026-09-01
```

Refresh Power BI only after that command exits 0.
