# Agents

This file is the instruction source for every coding agent in this repository.

## What this repo is

A sample that loads Red Hat Cost Management data into `PowerBI/CostManagement.pbix` for FinOps users on Windows.

## Loader

Follow `docs/superpowers/specs/2026-09-30-powershell-csv-loader-design.md` before changing how data is fetched or loaded.

The intended loader is Windows PowerShell 5.1. It downloads JSON from the Cost Management API and writes CSV. The Power BI report imports those CSV files. The Excel workbooks are removed in that change; the new report does not read them. Do not add a second loader beside the script.

`-ApiBaseUrl` and `-TokenUrl` default to console.redhat.com and the Red Hat SSO token endpoint. A self-managed Cost Management passes its own API host and Keycloak token URL.

`-TestProxy` reports the system proxy for the token URL and the API host. It must not read `auth.csv`. `-Test` runs that check before it sends the client secret. A configured proxy is used. The script must not drop it and connect directly. Neither switch prints the client secret, the access token, or proxy credentials, and neither writes CSV files.

Cost Management emits data. This repository owns the report template. Do not add a database, and do not generate `.pbix` files from Cost Management.

## Secrets and exports

- `auth.csv` is gitignored. Never commit it. Never write the client secret or the access token into logs, CSV files, or docs.
- Account exports contain customer cost data. Keep `data/export/` gitignored, including logs.

## Power BI

Keep the existing report pages, measures, and calculated tables. Change queries in Power BI Desktop, and save a text copy of the changed M under `powerbi/`. Leave the binary `DataModel` inside the `.pbix` for Power BI Desktop to rewrite.

Run `powershell.exe -File scripts/Export-CostManagement.Tests.ps1` after changing the loader. Those tests use Windows PowerShell 5.1 and do not call the network.

## Nulls and failed calls

A null from the API becomes an empty CSV field. A failed HTTP response is logged with its status. Do not store that failure as a null cell for a later type conversion to trip over.
