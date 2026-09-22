# PIP API Tests

This repository contains one Insomnia collection for the current PIP API HTTP contract. The Insomnia GUI is the primary interface. The optional PowerShell runner uses Inso CLI to run the same collection on each target in a stage.

The PIP API package has 39 active explicit GET routes. This suite covers the 36 safe routes. It automates 35 routes and keeps `cache-get` as a manual request because it needs a live cache key. The destructive `cache-reset`, `cache-delete`, and `duckdb-reset` routes are intentionally absent.

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

Use the current Insomnia release.

1. Open Insomnia and use Git Sync to clone `https://github.com/PIP-Technical-Team/insomnia-PIP-API.git`.
2. If this repository is already on the computer, use the Insomnia scan or open action and select the repository root.
3. Open the `PIP API Tests` collection.
4. Confirm that the Base Environment and all ten target sub-environments are visible.
5. Select the required target in the environment menu before you send or run requests.

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

## Optional Inso Runner

Install Inso CLI on the intranet Windows computer:

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

Cache warming is a manual release task. It is not a load test, a schedule, a deployment hook, or a cache-reset tool. ITS owns the complete gateway cache reset. Do not start a gateway warm run until the release is healthy on all intended API VMs and ITS explicitly confirms the gateway reset.

There are two cache layers:

| Layer | Owner and signal | Meaning |
| --- | --- | --- |
| VM/API response cache | PIP API; `X-Pipapi-Cache: HIT|MISS` when present | API-origin cache state only |
| Gateway cache | ITS | Gateway-specific trace, log, or header when ITS provides one |

The gateway can replay `X-Pipapi-Cache`, so this header is not gateway hit or miss evidence. The first gateway run after an ITS-confirmed reset is a `gateway-empty first pass`. Immediate identical runs are `presumed gateway hits` until ITS provides a reliable gateway signal. For a direct VM, the first phase is a `VM first-pass`; it measures only the VM/API path and its cache state.

The gateway key requires this exact parameter set:

```text
country=all&year=all&povline=<canonical value>&ppp_version=<year>&format=<json|csv>
```

Do not add `fill_gaps`, `version`, `release_version`, or other default parameters. JSON and CSV are separate entries. The cache warmer calls `/versions`, selects the latest `PROD` release for each PPP year, then calls `/poverty-lines?version=<full version>`. It uses each returned canonical `name` exactly as supplied and creates both JSON and CSV iteration rows.

Use Insomnia/Inso 13.2 or a compatible version with Collection Runner iteration-data support. The script writes only iteration data, a manifest, Inso output, and compact summaries below the ignored `results/` directory. It does not save response bodies, cookies, gateway traces, or secrets.

Preview the selected versions and data before any expensive request:

```powershell
.\scripts\run-pip-cache-warm.ps1 `
  -BaseUrl "https://api.worldbank.org/pip/v1" `
  -Environment "Prod - Gateway" `
  -GenerateOnly -Limit 2
```

Run the complete matrix only after the required release and ITS confirmation:

```powershell
.\scripts\run-pip-cache-warm.ps1 `
  -BaseUrl "https://api.worldbank.org/pip/v1" `
  -Environment "Prod - Gateway" `
  -DelayMs 250 `
  -Execute
```

`-Execute` is required for every request run. The script accepts only the existing gateway environments; it rejects Local and direct VM environments because they cannot warm a gateway cache. `-Limit` limits generated iteration rows for a safe smoke run. The script validates the environment and base URL, empty discovery responses, missing `PROD` versions, empty poverty-line lists, duplicate rows, expected row count, output location, and version-set changes during the run. It does not use `--bail`, so a run continues after one failed row. If the gateway returns `429` or shows saturation, stop and increase the delay. Do not add concurrency.

The cache runner uses an Inso command equivalent to this command. It deliberately omits `--includeFullData`.

```powershell
inso --ci -w .\insomnia.wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3.yaml run collection `
  --item req_b5d107e4c8394a62bf1e7530d8962ca4 `
  --env "Prod - Gateway" `
  --iteration-data .\results\cache-warm\cache-warm-iterations-<timestamp>.json `
  --delay-request 250 `
  --requestTimeout 180000 `
  --output .\results\cache-warm\cache-warm-inso-<timestamp>.json `
  --acceptRisk `
  wrk_5ab0f2f90f1c4cf08f721385a6ea6dc3
```

For GUI use, run `-GenerateOnly` and select only `30 Caching / Warm GET /pip - all country and year` in Collection Runner. Use **Upload Data** to select the generated JSON file, verify the iteration count, and run it. Use the CLI when you need saved results. The GUI is useful for a small `-Limit 2` check.

Do not use a pre-request loop with `insomnia.sendRequest` for this work. It has weak per-iteration reporting and restart behavior. Request chaining passes response values but does not control an iteration-data loop. A plugin, separate requests for every key, and a Postman/Newman migration add no useful ability here.

ITS reports a nine-day gateway policy, but the effective retention after the API `Cache-Control: public, max-age=7200` boundary is not confirmed. ITS must trace one warmed URL immediately, shortly before two hours, and shortly after two hours. Until that test is complete, do not state that one warm run lasts nine days or that a weekly run is sufficient.

## Manual Performance Measurement

`20 Performance` provides sequential end-to-end client latency samples for `/health-check`, `/versions`, bounded `/pip` JSON and CSV, and expensive all-country/all-year `/pip` JSON and CSV. It is not a controlled concurrency, throughput, saturation, or capacity test. Do not calculate requests per second as a service throughput metric.

Use the same client computer, network path, Inso version, delay, timeout, cookie policy, request order, and data version for all targets in one comparison. The performance script calls `/versions` first and stops when the selected targets expose different latest `PROD` versions. Alternate target order between benchmark sessions to reduce time and order bias.

```powershell
.\scripts\run-pip-performance.ps1 `
  -Environment "Prod - Gateway","Prod - VM1","Prod - VM2","Prod - VM3" `
  -WarmIterations 5 `
  -DelayMs 250
```

The runner writes one `first-pass` artifact for each target, then the requested number of `presumed-warm` artifacts. It records Inso version and settings, raw output, request console records, and a CSV/JSON summary. The summary groups target, endpoint, format, and phase, then reports count, errors, min, median/p50, p90, p95, and max latency. It keeps JSON and CSV separate.

Do not mix first-pass and warm records in one percentile. A gateway result includes DNS, network, TLS, and gateway effects. A direct VM uses intranet HTTP. Their difference is end-to-end client latency, not a pure gateway cost. No latency pass/fail thresholds exist until the team defines a baseline and service objective.

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
| Inso CLI is missing | Run `npm install --global insomnia-inso`, open a new PowerShell session, and run `inso --version`. |
| An intranet host is unreachable | Use the intranet computer, connect to the required network, and confirm World Bank DNS resolution. |
| The explicit version request returns a client error | Confirm the target's `/versions` response, then override only `test_data_version` in that target sub-environment. |
| A response has status 200 and `ok: false` | Treat it as an API request timeout. Reduce the selected scope or inspect the target logs. Do not weaken the assertion. |
| Local Smoke cannot connect | Start the local PIP API and confirm `http://127.0.0.1:8080/api/v1/health-check` is reachable. |
| Local cache checks fail | Restart the API with `PIPAPI_APPLY_CACHING=TRUE`. |
| A gateway returns 404 but a VM passes | Record a gateway-policy finding. Do not move the route or change its assertion without confirming the intended gateway contract. |
| An older deployment returns 404 for a new route | Record deployment-version skew and update the deployment. |

Destructive cache requests are not available in this repository. Use server administration procedures outside this test suite when a cache reset or delete operation is required.
