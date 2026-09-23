#!/usr/bin/env python3
"""Warm selected PIP API gateway cache entries with sequential GET requests."""

from __future__ import annotations

import argparse
import csv
import io
import itertools
import json
import sys
import time
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from http.client import HTTPException
from typing import Any, Callable, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


SUPPORTED_PPP_VERSIONS = ("2021", "2017")
SUPPORTED_DATA_FORMATS = ("json", "csv", "rds")


@dataclass(frozen=True)
class WarmRequest:
    url: str
    label: str
    response_format: Optional[str] = None
    required_csv_header: tuple[str, ...] = ()


@dataclass(frozen=True)
class WarmPlan:
    requests: list[WarmRequest]
    verify: Optional[Callable[[], None]] = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Warm PIP API cache entries. The default mode only previews requests."
    )
    parser.add_argument(
        "--base-url",
        help="API base URL used by a named scenario, for example https://api.worldbank.org/pip/v1",
    )
    parser.add_argument(
        "--scenario",
        choices=tuple(SCENARIOS),
        default=None,
        help="Named cache scenario to build (default: pip)",
    )
    parser.add_argument(
        "--country",
        action="append",
        default=[],
        help="Country code for page scenarios. Repeat for more countries.",
    )
    parser.add_argument(
        "--povline",
        action="append",
        default=[],
        help="Poverty line for page scenarios. Repeat for more poverty lines.",
    )
    parser.add_argument(
        "--all-countries",
        action="store_true",
        help="Discover and use every country for page scenarios.",
    )
    parser.add_argument(
        "--all-poverty-lines",
        action="store_true",
        help="Discover and use every poverty line for calculator and page scenarios.",
    )
    parser.add_argument(
        "--url",
        action="append",
        default=[],
        help="Warm one exact URL instead of a named scenario. Repeat this option for more URLs.",
    )
    parser.add_argument(
        "--delay-ms",
        type=nonnegative_int,
        default=250,
        help="Delay between requests in milliseconds (default: 250)",
    )
    parser.add_argument(
        "--timeout",
        type=positive_float,
        default=180.0,
        help="Timeout for each request in seconds (default: 180)",
    )
    parser.add_argument(
        "--limit",
        type=positive_int,
        help="Use only the first N generated requests for a small verification run",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Send the requests. Without this flag, the script only prints the plan.",
    )
    args = parser.parse_args()

    if args.url and args.base_url:
        parser.error("use either --url or --base-url, not both")
    if not args.url and not args.base_url:
        parser.error("--base-url is required unless --url is used")
    if args.url and args.scenario is not None:
        parser.error("--scenario cannot be used with --url")
    if args.url and (
        args.country
        or args.povline
        or args.all_countries
        or args.all_poverty_lines
    ):
        parser.error("country and poverty-line options cannot be used with --url")
    args.scenario = args.scenario or "pip"
    if args.country and args.all_countries:
        parser.error("use either --country or --all-countries, not both")
    if args.povline and args.all_poverty_lines:
        parser.error("use either --povline or --all-poverty-lines, not both")
    if args.scenario == "pip" and (
        args.country
        or args.povline
        or args.all_countries
        or args.all_poverty_lines
    ):
        parser.error("country and poverty-line options do not apply to --scenario pip")
    if args.scenario in COUNTRY_SCENARIOS and not (
        args.country or args.all_countries
    ):
        parser.error(
            f"--scenario {args.scenario} requires --country or --all-countries"
        )
    if args.scenario in POVERTY_LINE_SCENARIOS and not (
        args.povline or args.all_poverty_lines
    ):
        parser.error(
            f"--scenario {args.scenario} requires --povline or --all-poverty-lines"
        )

    return args


def nonnegative_int(value: str) -> int:
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return number


def positive_int(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return number


def positive_float(value: str) -> float:
    number = float(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return number


def normalized_base_url(value: str) -> str:
    base_url = value.strip().rstrip("/")
    parsed = urlsplit(base_url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ValueError("--base-url must be a complete HTTP or HTTPS URL")
    if parsed.query or parsed.fragment:
        raise ValueError("--base-url must not contain a query string or fragment")
    return base_url


def exact_url(value: str) -> str:
    url = value.strip()
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ValueError("--url values must be complete HTTP or HTTPS URLs")
    return url


def unique_values(values: list[str], option: str) -> list[str]:
    unique: list[str] = []
    seen: set[str] = set()
    for value in values:
        item = value.strip()
        if not item:
            raise ValueError(f"{option} values must not be empty")
        if item not in seen:
            seen.add(item)
            unique.append(item)
    return unique


def get_json(url: str, timeout: float) -> Any:
    request = Request(url, headers={"Accept": "application/json"})
    with urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def response_rows(value: Any, description: str) -> list[dict[str, Any]]:
    if isinstance(value, dict):
        for key in ("data", "results"):
            if key in value:
                value = value[key]
                break
    if not isinstance(value, list) or not value:
        raise ValueError(f"{description} returned no rows")
    if not all(isinstance(row, dict) for row in value):
        raise ValueError(f"{description} returned an unexpected JSON structure")
    return value


def required_text(row: dict[str, Any], key: str, description: str) -> str:
    value = row.get(key)
    if value is None or not str(value).strip():
        raise ValueError(f"{description} does not contain '{key}'")
    return str(value).strip()


def decimal_value(value: str, description: str) -> Decimal:
    try:
        number = Decimal(value)
    except InvalidOperation as error:
        raise ValueError(f"{description} value '{value}' is not numeric") from error
    if not number.is_finite():
        raise ValueError(f"{description} value '{value}' is not finite")
    return number


def latest_prod_versions(
    base_url: str, timeout: float
) -> dict[str, tuple[Decimal, str, str]]:
    versions = response_rows(get_json(f"{base_url}/versions", timeout), "/versions")
    latest_by_ppp: dict[str, tuple[Decimal, str, str]] = {}

    for row in versions:
        if required_text(row, "identity", "/versions row") != "PROD":
            continue
        ppp_version = required_text(row, "ppp_version", "/versions PROD row")
        if ppp_version not in SUPPORTED_PPP_VERSIONS:
            continue
        release_version = required_text(row, "release_version", "/versions PROD row")
        resolved_version = required_text(row, "version", "/versions PROD row")
        candidate = (
            decimal_value(release_version, "release_version"),
            release_version,
            resolved_version,
        )
        current = latest_by_ppp.get(ppp_version)
        if current is None or (candidate[0], candidate[2]) > (current[0], current[2]):
            latest_by_ppp[ppp_version] = candidate

    missing_ppp_versions = [
        version for version in SUPPORTED_PPP_VERSIONS if version not in latest_by_ppp
    ]
    if missing_ppp_versions:
        raise ValueError(
            "/versions returned no PROD version for supported PPP year(s): "
            + ", ".join(missing_ppp_versions)
        )

    return latest_by_ppp


def version_snapshot(
    versions: dict[str, tuple[Decimal, str, str]]
) -> tuple[str, ...]:
    snapshot = []
    for ppp_version in SUPPORTED_PPP_VERSIONS:
        _, release_version, resolved_version = versions[ppp_version]
        snapshot.append(f"{ppp_version}|{release_version}|{resolved_version}")
    return tuple(snapshot)


def discover_poverty_lines(
    base_url: str,
    timeout: float,
    versions: dict[str, tuple[Decimal, str, str]],
) -> dict[str, list[str]]:
    discovered: dict[str, list[str]] = {}
    for ppp_version in SUPPORTED_PPP_VERSIONS:
        _, _, resolved_version = versions[ppp_version]
        query = urlencode((("version", resolved_version),))
        rows = response_rows(
            get_json(f"{base_url}/poverty-lines?{query}", timeout),
            f"/poverty-lines for {resolved_version}",
        )
        names = {
            required_text(row, "name", f"/poverty-lines row for {resolved_version}")
            for row in rows
        }
        discovered[ppp_version] = sorted(
            names, key=lambda value: (decimal_value(value, "poverty-line name"), value)
        )
    return discovered


def discover_countries(
    base_url: str,
    timeout: float,
    versions: dict[str, tuple[Decimal, str, str]],
) -> dict[str, list[str]]:
    discovered: dict[str, list[str]] = {}
    for ppp_version in SUPPORTED_PPP_VERSIONS:
        _, _, resolved_version = versions[ppp_version]
        query = urlencode((("table", "countries"), ("version", resolved_version)))
        rows = response_rows(
            get_json(f"{base_url}/aux?{query}", timeout),
            f"/aux countries for {resolved_version}",
        )
        discovered[ppp_version] = sorted(
            {
                required_text(row, "country_code", "/aux countries row")
                for row in rows
            }
        )
    return discovered


def request_item(
    base_url: str,
    path: str,
    parameters: tuple[tuple[str, str], ...] = (),
    response_format: Optional[str] = "json",
    required_csv_header: tuple[str, ...] = (),
) -> WarmRequest:
    query = f"?{urlencode(parameters)}" if parameters else ""
    label_parameters = " ".join(f"{key}={value}" for key, value in parameters)
    label = path.lstrip("/")
    if label_parameters:
        label = f"{label} {label_parameters}"
    return WarmRequest(
        url=f"{base_url}{path}{query}",
        label=label,
        response_format=response_format,
        required_csv_header=required_csv_header,
    )


def pip_requests(
    base_url: str,
    poverty_lines: dict[str, list[str]],
) -> list[WarmRequest]:
    requests: list[WarmRequest] = []
    for ppp_version in SUPPORTED_PPP_VERSIONS:
        for povline in poverty_lines[ppp_version]:
            for fill_gaps in ("true", "false"):
                for response_format in SUPPORTED_DATA_FORMATS:
                    requests.append(
                        request_item(
                            base_url,
                            "/pip",
                            (
                                ("country", "all"),
                                ("year", "all"),
                                ("povline", povline),
                                ("ppp_version", ppp_version),
                                ("fill_gaps", fill_gaps),
                                ("format", response_format),
                            ),
                            response_format=response_format,
                            required_csv_header=(
                                "country_code",
                                "reporting_year",
                                "poverty_line",
                                "headcount",
                                "poverty_gap",
                                "mean",
                            ),
                        )
                    )
    return requests


def pip_group_requests(
    base_url: str,
    poverty_lines: dict[str, list[str]],
) -> list[WarmRequest]:
    requests: list[WarmRequest] = []
    for ppp_version in SUPPORTED_PPP_VERSIONS:
        for povline in poverty_lines[ppp_version]:
            for fill_gaps in ("true", "false"):
                for response_format in SUPPORTED_DATA_FORMATS:
                    requests.append(
                        request_item(
                            base_url,
                            "/pip-grp",
                            (
                                ("country", "all"),
                                ("year", "all"),
                                ("povline", povline),
                                ("ppp_version", ppp_version),
                                ("group_by", "wb"),
                                ("fill_gaps", fill_gaps),
                                ("format", response_format),
                            ),
                            response_format=response_format,
                        )
                    )
    return requests


PAGE_ENDPOINTS: dict[str, tuple[tuple[str, tuple[str, ...]], ...]] = {
    "homepage": (
        ("/hp-stacked", ("povline", "ppp_version")),
        ("/hp-countries", ("country", "povline", "ppp_version")),
        ("/decomposition-vars", ("ppp_version",)),
        ("/poverty-lines", ("ppp_version",)),
        ("/indicators", ("ppp_version",)),
    ),
    "country-profile": (
        ("/cp-download", ("country", "povline", "ppp_version")),
        ("/cp-key-indicators", ("country", "povline", "ppp_version")),
        ("/cp-charts", ("country", "povline", "ppp_version")),
    ),
}

SCENARIOS = (
    "pip",
    "pip-grp",
    "poverty-calculator",
    "homepage",
    "country-profile",
    "pages",
    "all",
)
COUNTRY_SCENARIOS = {"homepage", "country-profile", "pages", "all"}
POVERTY_LINE_SCENARIOS = {
    "pip-grp",
    "poverty-calculator",
    "homepage",
    "country-profile",
    "pages",
    "all",
}


def page_requests(
    base_url: str,
    groups: tuple[str, ...],
    countries: dict[str, list[str]],
    poverty_lines: dict[str, list[str]],
) -> list[WarmRequest]:
    requests: list[WarmRequest] = []
    for group in groups:
        for path, parameter_names in PAGE_ENDPOINTS[group]:
            ppp_versions = (
                SUPPORTED_PPP_VERSIONS if "ppp_version" in parameter_names else (None,)
            )
            for ppp_version in ppp_versions:
                parameter_values = {
                    "country": countries.get(ppp_version or "", []),
                    "povline": poverty_lines.get(ppp_version or "", []),
                    "ppp_version": [ppp_version] if ppp_version else [],
                    "format": list(SUPPORTED_DATA_FORMATS),
                }
                if "country" in parameter_names and "povline" in parameter_names:
                    parameter_sets = (
                        tuple(
                            (name, values[name]) for name in parameter_names
                        )
                        for povline in parameter_values["povline"]
                        for country in parameter_values["country"]
                        for response_format in (
                            parameter_values["format"]
                            if "format" in parameter_names
                            else ("json",)
                        )
                        for values in (
                            {
                                "country": country,
                                "povline": povline,
                                "ppp_version": ppp_version,
                                "format": response_format,
                            },
                        )
                    )
                else:
                    parameter_sets = (
                        tuple(zip(parameter_names, values))
                        for values in itertools.product(
                            *(parameter_values[name] for name in parameter_names)
                        )
                    )
                for parameters in parameter_sets:
                    response_format = dict(parameters).get("format", "json")
                    requests.append(
                        request_item(
                            base_url,
                            path,
                            parameters,
                            response_format=response_format,
                        )
                    )
    return requests


def poverty_calculator_requests(
    base_url: str, poverty_lines: dict[str, list[str]]
) -> list[WarmRequest]:
    requests: list[WarmRequest] = []
    for ppp_version in SUPPORTED_PPP_VERSIONS:
        for povline in poverty_lines[ppp_version]:
            common = (
                ("country", "all"),
                ("year", "all"),
                ("povline", povline),
                ("ppp_version", ppp_version),
            )
            requests.extend(
                (
                    request_item(
                        base_url,
                        "/pc-charts",
                        common + (("fill_gaps", "true"),),
                    ),
                    request_item(
                        base_url,
                        "/pc-charts",
                        common + (("fill_gaps", "false"),),
                    ),
                    request_item(base_url, "/pc-regional-aggregates", common),
                )
            )
    return requests


def build_scenario_plan(
    scenario: str,
    base_url: str,
    timeout: float,
    countries: list[str],
    poverty_lines: list[str],
    all_countries: bool,
    all_poverty_lines: bool,
) -> WarmPlan:
    versions = latest_prod_versions(base_url, timeout)
    initial_snapshot = version_snapshot(versions)
    if all_poverty_lines or scenario in ("pip", "pip-grp"):
        poverty_lines_by_ppp = discover_poverty_lines(base_url, timeout, versions)
    else:
        poverty_lines_by_ppp = {
            ppp_version: poverty_lines for ppp_version in SUPPORTED_PPP_VERSIONS
        }
    if all_countries:
        countries_by_ppp = discover_countries(base_url, timeout, versions)
    else:
        countries_by_ppp = {
            ppp_version: countries for ppp_version in SUPPORTED_PPP_VERSIONS
        }

    requests: list[WarmRequest] = []
    if scenario in ("pip", "all"):
        requests.extend(pip_requests(base_url, poverty_lines_by_ppp))
    if scenario in ("pip-grp", "all"):
        requests.extend(pip_group_requests(base_url, poverty_lines_by_ppp))
    if scenario in ("poverty-calculator", "all"):
        requests.extend(
            poverty_calculator_requests(base_url, poverty_lines_by_ppp)
        )

    groups: tuple[str, ...] = ()
    if scenario in ("homepage", "pages", "all"):
        groups += ("homepage",)
    if scenario in ("country-profile", "pages", "all"):
        groups += ("country-profile",)
    requests.extend(
        page_requests(base_url, groups, countries_by_ppp, poverty_lines_by_ppp)
    )

    def verify_versions() -> None:
        final_snapshot = version_snapshot(latest_prod_versions(base_url, timeout))
        if final_snapshot != initial_snapshot:
            raise ValueError("the selected PROD versions changed during the run")

    unique_requests = list({request.url: request for request in requests}.values())
    return WarmPlan(requests=unique_requests, verify=verify_versions)


def send_request(item: WarmRequest, timeout: float) -> tuple[int, int, float]:
    started = time.perf_counter()
    request = Request(item.url)
    with urlopen(request, timeout=timeout) as response:
        status = response.status
        content_type = response.headers.get_content_type()
        body = response.read()

    if status != 200:
        raise ValueError(f"expected HTTP 200, received {status}")
    if not body:
        raise ValueError("response body is empty")

    if item.response_format == "json":
        if content_type != "application/json":
            raise ValueError(f"expected application/json, received {content_type}")
        encoding = response.headers.get_content_charset() or "utf-8"
        payload = json.loads(body.decode(encoding))
        if isinstance(payload, dict):
            if payload.get("error") is not None or payload.get("ok") is False:
                raise ValueError("JSON response contains an API error")
            if not payload:
                raise ValueError("JSON response object is empty")
        elif isinstance(payload, list):
            if not payload:
                raise ValueError("JSON response array is empty")
        else:
            raise ValueError("JSON response is not an array or object")

    if item.response_format == "csv":
        if content_type != "text/csv":
            raise ValueError(f"expected text/csv, received {content_type}")
        encoding = response.headers.get_content_charset() or "utf-8-sig"
        rows = csv.reader(io.StringIO(body.decode(encoding)))
        header = next(rows, [])
        if header:
            header[0] = header[0].lstrip("\ufeff")
        first_data_row = next(rows, [])
        if item.required_csv_header and not set(item.required_csv_header).issubset(
            header
        ):
            raise ValueError("CSV response does not contain the required header")
        if not first_data_row:
            raise ValueError("CSV response does not contain a data row")

    if item.response_format == "rds" and content_type != "application/rds":
        raise ValueError(f"expected application/rds, received {content_type}")

    return status, len(body), time.perf_counter() - started


def main() -> int:
    args = parse_args()
    try:
        if args.url:
            plan = WarmPlan(
                requests=[
                    WarmRequest(url=url, label=url)
                    for url in map(exact_url, args.url)
                ]
            )
        else:
            base_url = normalized_base_url(args.base_url)
            countries = unique_values(args.country, "--country")
            poverty_lines = unique_values(args.povline, "--povline")
            plan = build_scenario_plan(
                args.scenario,
                base_url,
                args.timeout,
                countries,
                poverty_lines,
                args.all_countries,
                args.all_poverty_lines,
            )
    except (
        HTTPError,
        URLError,
        TimeoutError,
        OSError,
        HTTPException,
        ValueError,
        json.JSONDecodeError,
    ) as error:
        print(f"Discovery failed: {error}", file=sys.stderr)
        return 1

    total_requests = len(plan.requests)
    requests = plan.requests
    if args.limit is not None:
        requests = requests[: args.limit]
    if not requests:
        print("No cache-warming requests were generated.", file=sys.stderr)
        return 1

    if len(requests) == total_requests:
        print(f"Prepared {total_requests} request(s).", flush=True)
    else:
        print(
            f"Prepared {total_requests} request(s); selected the first "
            f"{len(requests)} because of --limit.",
            flush=True,
        )
    if not args.execute:
        for index, item in enumerate(requests, start=1):
            print(f"[{index}/{len(requests)}] {item.url}")
        print("Preview only. Add --execute to send these requests.")
        return 0

    failures = 0
    started = time.perf_counter()
    for index, item in enumerate(requests, start=1):
        request_started = time.perf_counter()
        try:
            status, size, elapsed = send_request(item, args.timeout)
            print(
                f"[{index}/{len(requests)}] {status} {item.label} "
                f"{elapsed:.2f}s {size} bytes"
            )
        except (
            HTTPError,
            URLError,
            TimeoutError,
            OSError,
            HTTPException,
            ValueError,
            UnicodeError,
            LookupError,
            csv.Error,
            json.JSONDecodeError,
        ) as error:
            failures += 1
            elapsed = time.perf_counter() - request_started
            print(
                f"[{index}/{len(requests)}] FAILED {item.label} "
                f"after {elapsed:.2f}s: {error}",
                file=sys.stderr,
            )

        if index < len(requests) and args.delay_ms:
            time.sleep(args.delay_ms / 1000)

    if plan.verify is not None:
        try:
            plan.verify()
        except (
            HTTPError,
            URLError,
            TimeoutError,
            OSError,
            HTTPException,
            ValueError,
            UnicodeError,
            json.JSONDecodeError,
        ) as error:
            failures += 1
            print(f"Post-run version check failed: {error}", file=sys.stderr)

    total = time.perf_counter() - started
    print(
        f"Finished {len(requests)} request(s) in {total:.2f}s; "
        f"{failures} failed."
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
