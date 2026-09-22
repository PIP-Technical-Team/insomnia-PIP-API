# PIP API Tests

This repository contains an Insomnia collection for API contract checks and a small Python script for manual cache warming. Cache warming does not require Insomnia, Inso CLI, PowerShell, Node.js, or npm.

The PIP API package has 39 active explicit GET routes. This suite covers the 36 safe routes. It automates 35 routes and keeps `cache-get` as a manual request because it needs a live cache key. The destructive `cache-reset`, `cache-delete`, and `duckdb-reset` routes are intentionally absent.

## Start Here

Use the `MAC_test` branch for this work. Pull it before you open Insomnia or run the cache warmer:

```sh
git switch MAC_test
git pull --ff-only origin MAC_test
```

There are two supported ways to run requests. Choose one for each activity:

| Activity | What you use | When to use it |
| --- | --- | --- |
| Browse requests or run a contract check | Insomnia desktop application | You want to select requests and inspect responses. |
| Warm gateway cache entries | `python3 scripts/warm_pip_cache.py` | You want one repeatable command with no extra packages. |

The Python warmer is independent of the Insomnia collection. It calls the API directly and does not create result files. Python 3.9 or later is the only runtime it needs. On macOS or Linux, confirm it with:

```sh
python3 --version
```

On Windows PowerShell, use the Python launcher:

```powershell
py -3 --version
```

The script prints each HTTP result, response size, and elapsed time to the terminal. These timings are basic end-to-end measurements, not load-test results.

Run every command below from the repository root, the folder that contains `README.md` and `insomnia.wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3.yaml`.

## Collection File

`insomnia.wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3.yaml` is the authoritative Insomnia v5.1 collection. Do not create one collection for each stage or server.

The collection has five top-level scopes:

| Scope | Purpose | Valid targets |
| --- | --- | --- |
| `00 Gateway Contract` | Supported or intended public gateway contract | Local, gateways, and direct VMs |
| `10 Direct Server Only` | Package routes that current gateways do not publish | Local and direct VMs only |
| `20 Performance` | Manual sequential end-to-end latency samples | Selected target only |
| `30 Caching` | Manual `/pip` gateway-cache warming | Selected target only |
| `90 Manual Requests` | Requests that need operator input | Manual use only |

The `00 Gateway Contract` folders are `00 Smoke`, `10 Poverty Statistics`, `20 Grouped Data`, `30 Metadata`, `40 System`, `50 Homepage`, `60 Poverty Calculator`, `70 Country Profiles`, `80 UI Support`, and `90 Validation Errors`.

The `10 Direct Server Only` folders are `10 Version And Data`, `20 Runtime Diagnostics`, `30 Downloads`, and `40 Read-Only Cache`.

The `90 Manual Requests` scope contains cache lookup and legacy manual UI requests. It is never part of an automatic run.

## Environments

The Base Environment contains all shared test data. Each selectable sub-environment normally overrides only `base_url`. A request is defined one time and works on every target.

Available targets are:

| Stage | Targets |
| --- | --- |
| Local | `Local` |
| Dev | `Dev - Gateway`, `Dev - VM1` |
| QA | `QA - Gateway`, `QA - VM1`, `QA - VM2` |
| Prod | `Prod - Gateway`, `Prod - VM1`, `Prod - VM2`, `Prod - VM3` |

The shared variables include the test country, survey year, interpolated year, group year, poverty line, population share, grouped-data vectors, requested mean, explicit data version, and manual cache key.

Normal requests omit `version`, `release_version`, `ppp_version`, and `identity`. They test the latest data version on the selected target. The direct-server request `GET /version - explicit data version` uses `test_data_version`. If one target does not load that historical version, add only a `test_data_version` override to that target sub-environment. Do not copy the request.

## Open In Insomnia

Use this path only when you want the graphical interface. You do not need to open Insomnia before running the Python cache warmer.

1. Pull `MAC_test` with the commands in **Start Here**.
2. Open Insomnia.
3. If this repository is already on the computer, use the Insomnia scan or open action and select the repository root. Otherwise, use Git Sync to clone `https://github.com/PIP-Technical-Team/insomnia-PIP-API.git`, then switch its local branch to `MAC_test`.
4. Open the `PIP API Tests` collection.
5. Confirm that the Base Environment and all ten target sub-environments are visible.
6. Select the required target in the environment menu before you send or run requests.

The automated contract, performance, and cache-warming requests do not use authentication or cookies. These requests disable cookie send and cookie storage. Do not include legacy manual UI requests in an automated run.

## Run In The GUI

Smoke is the safe default. It sends three bounded requests: `health-check`, `versions`, and one national `pip` request for one country, one year, and one poverty line.

To run Smoke:

1. Select a target environment.
2. Open the Collection Runner.
3. Select only `00 Gateway Contract/00 Smoke`.
4. Start the run.

To run Full on a gateway, select only `00 Gateway Contract`. To run Full on Local or a direct VM, select `00 Gateway Contract` and `10 Direct Server Only`. Never include `20 Performance`, `30 Caching`, or `90 Manual Requests` in an automatic run.

To test one function area, select one folder such as `20 Grouped Data` or `70 Country Profiles`. This is useful during endpoint development.

Full is not the default because it sends more requests, includes validation errors, and runs direct-server diagnostics when that scope is selected. It does not contain load tests, unbounded all-country and all-year requests, retries, or fixed response-time limits.

## Local Workflow

The current development computer does not have intranet access. Use it only for the local API target.

1. Start the PIP API at `http://127.0.0.1:8080/api/v1`.
2. Set `PIPAPI_APPLY_CACHING=TRUE` before API startup if Local Full must test `cache-info` and `cache-keys`.
3. Select the `Local` environment.
4. Run Smoke first.
5. Run Full by selecting `00 Gateway Contract` and `10 Direct Server Only`.

Do not use failed intranet DNS or network connections on this computer as API test results.

## Intranet Workflow

Use the intranet Windows computer for Dev, QA, and Prod gateways and VMs.

1. Pull the current repository version.
2. Select the stage gateway environment and run Smoke.
3. Select each VM environment and run Smoke.
4. Run Full on the gateway with `00 Gateway Contract` only.
5. Run Full on each VM with `00 Gateway Contract` and `10 Direct Server Only`.

The PowerShell runner can do these target sequences automatically.

## Optional Inso Contract-Test Runner

This section applies only to the existing `run-pip-tests.ps1` contract-test helper. The Python cache warmer does not use Inso or PowerShell. Install Inso CLI on the intranet Windows computer only when you need this contract-test runner:

```powershell
npm install --global insomnia-inso
inso --version
```

Run the stage helper from the repository root:

```powershell
.\scripts\run-pip-tests.ps1 -Stage Local
.\scripts\run-pip-tests.ps1 -Stage QA
.\scripts\run-pip-tests.ps1 -Stage QA -Suite Full
.\scripts\run-pip-tests.ps1 -Stage Prod -Suite Full
```

`-Suite Smoke` is the default for every stage. Use `-Suite Full` explicitly. The runner processes targets sequentially, continues after a failed target, prints a target summary, and returns a nonzero exit code when any target fails.

For Full, the runner sends only `00 Gateway Contract` to gateways. It sends `00 Gateway Contract` and `10 Direct Server Only` to Local and VMs. It never sends `20 Performance`, `30 Caching`, or `90 Manual Requests`.

## Manual Cache Warming

Cache warming is a manual release task. The script does not reset a cache and does not run concurrently. ITS owns the gateway reset. Run the full production matrix only after the release is healthy and ITS confirms the reset.

The `pip` scenario dynamically performs these steps:

1. Calls `/versions` and selects the latest `PROD` version for every PPP year.
2. Calls `/poverty-lines?version=<full-version>` for each selected version.
3. Uses each canonical poverty-line `name` exactly as the API returns it.
4. Sends one JSON request and one CSV request for every PPP year and poverty line.

Other scenarios cover the page endpoints already defined in the Insomnia collection:

| Scenario | Endpoints |
| --- | --- |
| `homepage` | `/hp-stacked`, `/hp-countries`, `/decomposition-vars`, `/poverty-lines`, `/indicators` |
| `country-profile` | `/cp-download` with JSON format, `/cp-key-indicators`, `/cp-charts` |
| `pages` | All Homepage and Country Profiles endpoints |
| `all` | The dynamic `/pip` matrix plus all Homepage and Country Profiles endpoints |

Page scenarios are bounded. They require at least one explicit `--country` and `--povline`. Repeat either option to add values. The script creates every requested country and poverty-line combination. It never assumes `country=all` for these endpoints.

The warmed `/pip` URL contains only these gateway cache-key parameters:

```text
country=all&year=all&povline=<canonical value>&ppp_version=<year>&format=<json|csv>
```

Do not add `fill_gaps`, `version`, `release_version`, or other default parameters to the warming URL.

### 1. Preview Two Requests

Run this safe command first. It performs discovery and prints two URLs, but it does not send the `/pip` requests.

macOS or Linux:

```sh
python3 scripts/warm_pip_cache.py \
  --base-url https://api.worldbank.org/pip/v1 \
  --limit 2
```

Windows PowerShell:

```powershell
py -3 scripts/warm_pip_cache.py --base-url https://api.worldbank.org/pip/v1 --limit 2
```

### 2. Send Two Test Requests

Add `--execute` only when you intend to send the requests:

```sh
python3 scripts/warm_pip_cache.py \
  --base-url https://api.worldbank.org/pip/v1 \
  --limit 2 \
  --execute
```

Windows PowerShell:

```powershell
py -3 scripts/warm_pip_cache.py --base-url https://api.worldbank.org/pip/v1 --limit 2 --execute
```

### 3. Warm The Complete `/pip` Cache Matrix

Remove `--limit` only after the two-request test succeeds and ITS confirms the gateway reset:

```sh
python3 scripts/warm_pip_cache.py \
  --base-url https://api.worldbank.org/pip/v1 \
  --delay-ms 250 \
  --timeout 180 \
  --execute
```

Windows PowerShell:

```powershell
py -3 scripts/warm_pip_cache.py --base-url https://api.worldbank.org/pip/v1 --delay-ms 250 --timeout 180 --execute
```

### Warm Homepage And Country Profiles

Preview all eight page request shapes for one country and poverty line:

```sh
python3 scripts/warm_pip_cache.py \
  --base-url https://api.worldbank.org/pip/v1 \
  --scenario pages \
  --country AGO \
  --povline 3
```

Add `--execute` after reviewing the printed URLs. To include more values, repeat the options:

```sh
python3 scripts/warm_pip_cache.py \
  --base-url https://api.worldbank.org/pip/v1 \
  --scenario pages \
  --country AGO \
  --country IDN \
  --povline 3 \
  --povline 6.55 \
  --execute
```

This example warms both countries at both poverty lines. The three global Homepage reference endpoints are sent only once.

On Windows PowerShell, use one line:

```powershell
py -3 scripts/warm_pip_cache.py --base-url https://api.worldbank.org/pip/v1 --scenario pages --country AGO --povline 3 --execute
```

Use `--scenario all` with the same `--country` and `--povline` options when one run must include `/pip`, Homepage, and Country Profiles. The dynamic `/pip` matrix can make this a large run. Preview with `--limit 10`, review the `Prepared` count, and remove the limit only after the limited run succeeds.

The script continues after an individual request failure and exits with status `1` if any request failed. It reads each complete response so that the gateway can cache it, but it does not save response bodies or create manifests.

Each result includes basic elapsed time and response size:

```text
[12/74] 200 ppp=2021 povline=3.00 format=json 1.42s 184220 bytes
```

Run the same command again immediately for a simple presumed-warm latency comparison. This is not a throughput or load test.

### Warm One Exact URL

Use `--url` for an endpoint or parameter combination that does not need dynamic discovery:

```sh
python3 scripts/warm_pip_cache.py \
  --url "https://api.worldbank.org/pip/v1/example?x=1&y=2" \
  --execute
```

Repeat `--url` to warm more than one exact URL. The script sends the URL exactly as supplied.

On Windows PowerShell, use the same options after `py -3 scripts/warm_pip_cache.py`.

### Add A Reusable Endpoint Scenario

For another bounded page endpoint, add its path and ordered parameter names to `PAGE_ENDPOINTS` in `scripts/warm_pip_cache.py`. Add custom discovery logic to `build_scenario_plan` only when the endpoint matrix cannot be expressed with explicit countries and poverty lines. Use the exact URLs sent by the real client. Do not guess optional parameters because every different parameter set can create a different gateway cache entry.

Use the Insomnia `30 Caching` request only for optional graphical inspection. The Python script is the primary cache-warming method.

## Manual Cache Lookup

Use `cache-get` only when you need to inspect a real cache entry.

1. Select Local or a direct VM.
2. Send `GET /cache-keys - available cache keys`.
3. Set `cache_key` to one returned key.
4. Send `GET /cache-get - lookup configured key` from `90 Manual Requests`.

The cache routes require an API process that started with caching enabled.

## Add An Endpoint

Use `..\pipapi\inst\plumber\v1\endpoints.R` as the authority for implemented behavior.

1. Add one request to the correct functional folder.
2. Start the URL with `{{base_url}}`.
3. Use shared Base Environment variables for reusable test data.
4. Add only bounded parameters.
5. Add a short request-level `scripts.afterResponse` script with `insomnia.test()` and `insomnia.expect()`.
6. Assert status, response format, top-level type, no top-level API error, no timeout body, and a small stable field subset.
7. Disable cookie send and cookie storage.
8. Run the functional folder, Local Full, and the applicable stage checks.

Do not assert exact poverty values, hashes, timestamps, package versions, full data versions, complete schemas, full row counts, complete country or year lists, or response times. Do not add one request for each environment. A request in an existing parent folder is automatically included in the applicable GUI and CLI scope.

## Interpret Failures

A gateway `404` can mean that gateway policy does not publish a package route. Confirm the same request on a direct VM. Direct-only routes are already separated so the Full gateway run does not send them.

A `404` on both a gateway and a VM can mean deployment-version skew. For example, an older deployment can lack `ui_version_id`. Keep this failure visible. Do not add environment-dependent success rules that hide a contract mismatch.

Validation Error requests accept any status from `400` through `499`. The package currently returns some non-standard `404` responses for invalid input, but a future `400` or `422` is also valid.

A response with status `200` and `ok: false` is a request-timeout body. Successful JSON tests reject this response.

## Release Checklist

1. Run Local Full.
2. Run target-stage Smoke.
3. Run target-stage Full.
4. Run Prod Smoke after deployment.
5. Run Prod Full only when complete release validation is required.
6. If cache warming is required, verify all intended VMs, obtain ITS reset confirmation, preview the generated matrix, and then run it manually.

For a normal release, run Dev before QA and run QA before Prod.

## Troubleshooting

| Problem | Action |
| --- | --- |
| Python is missing or too old | Install Python 3.9 or later. Run `python3 --version` on macOS/Linux or `py -3 --version` on Windows. |
| The cache warmer reports `Discovery failed` | Confirm the `--base-url`, network access, and the target's `/versions` response. |
| Inso CLI is missing for contract tests | On the intranet Windows computer, run `npm install --global insomnia-inso`, open a new PowerShell session, and run `inso --version`. |
| An intranet host is unreachable | Use the intranet computer, connect to the required network, and confirm World Bank DNS resolution. |
| The explicit version request returns a client error | Confirm the target's `/versions` response, then override only `test_data_version` in that target sub-environment. |
| A response has status 200 and `ok: false` | Treat it as an API request timeout. Reduce the selected scope or inspect the target logs. Do not weaken the assertion. |
| Local Smoke cannot connect | Start the local PIP API and confirm `http://127.0.0.1:8080/api/v1/health-check` is reachable. |
| Local cache checks fail | Restart the API with `PIPAPI_APPLY_CACHING=TRUE`. |
| A gateway returns 404 but a VM passes | Record a gateway-policy finding. Do not move the route or change its assertion without confirming the intended gateway contract. |
| An older deployment returns 404 for a new route | Record deployment-version skew and update the deployment. |

Destructive cache requests are not available in this repository. Use server administration procedures outside this test suite when a cache reset or delete operation is required.
