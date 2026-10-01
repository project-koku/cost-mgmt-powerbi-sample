# Cost Management Power BI

The report in `PowerBI/CostManagement.pbix` shows Cost Management data for FinOps users. Windows PowerShell 5.1 is the loader. It sends the service account to the Keycloak token URL, calls the Cost Management API, and writes CSV files under `data/export`. Power BI reads those files and the static lookups under `data/static`.

## Path

1. `data/auth.csv` holds `client_id` and `client_secret`.
2. The script requests a token from `-TokenUrl`. The default is `https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token` with scope `api.console`.
3. It calls `-ApiBaseUrl`. The default is `https://console.redhat.com`.
4. It writes one CSV per dataset, plus `export.log` when a call fails.
5. Power BI refresh loads `DataFolder\export` and `DataFolder\static`.

A self-managed Cost Management uses its own API host and Keycloak token URL through `-ApiBaseUrl` and `-TokenUrl`.

## API paths

| Data | Path |
| --- | --- |
| Currency | `/api/cost-management/v1/currency/` |
| Account settings | `/api/cost-management/v1/account-settings/` |
| OpenShift costs | `/api/cost-management/v1/reports/openshift/costs/` |
| OpenShift tags | `/api/cost-management/v1/tags/openshift/` |
| OpenShift usage | `/api/cost-management/v1/reports/openshift/compute/`, `memory/`, `volumes/` |
| AWS costs | `/api/cost-management/v1/reports/aws/costs/` |
| AWS tags | `/api/cost-management/v1/tags/aws/` |
| AWS categories | `/api/cost-management/v1/resource-types/aws-categories/?key_only=true` |
| AWS org units | `/api/cost-management/v1/organizations/aws/` |
| Recommendations | `/api/cost-management/v1/recommendations/openshift` |

Cost and usage requests page with `filter[limit]` and `filter[offset]`. Recommendations page with `limit` and `offset`.

## Report pages

| Page | What it shows |
| --- | --- |
| OpenShift Details | OpenShift group-bys with names and costs |
| Cost Overview | Projects, clusters, tags, and CPU, memory, and volume usage |
| Cost Explorer | Daily costs and the leading costs for each group-by |
| Amazon Web Services | AWS group-bys with names and costs |
| Optimizations | OpenShift recommendations |

Calculated tables `DateTable`, `MonthTable`, `OS Monthly Costs`, `OS Monthly Usage`, and `AWS Monthly Costs` stay in the model. Blank tag, cost-category, and org-unit rows stay in the Power Query used by the group-by filters.

`DateTable` is the calendar from the earliest `Start Date` to the latest `End Date` in `data/export/Data_Period.csv`. Each export window is one row in that file, and later runs keep earlier windows. Daily cost, usage, and cluster-project rows keep their own day, and a later run replaces only the days inside the new window. `MonthTable` has one row per month in that calendar. OpenShift Details and Amazon Web Services share a Period dropdown of those months, labeled with the year, ` - `, and the month name, for example `2026 - October`. Cost overview uses that same selection. Cost Explorer has a separate Period control with its own start date and end date, and both dates are days in `DateTable`. See the root `README.md` for the export command and the steps to change each control.

## Service account

The service account needs permission to read the API paths above. Access requirements are documented in [Limiting access to cost management resources](https://access.redhat.com/documentation/en-us/cost_management_service/1-latest/html/limiting_access_to_cost_management_resources/index).
