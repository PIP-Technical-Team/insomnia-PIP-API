#!/usr/bin/env python3
"""Warm selected PIP API gateway cache entries with sequential GET requests."""

from __future__ import annotations

import argparse
import csv
import io
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


@dataclass(frozen=True)
class WarmRequest:
    url: str
    label: str
    response_format: Optional[str] = None


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
        default="pip",
        help="Named cache scenario to build (default: pip)",
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

    if not latest_by_ppp:
        raise ValueError("/versions returned no PROD versions")

    return latest_by_ppp


def version_snapshot(
    versions: dict[str, tuple[Decimal, str, str]]
) -> tuple[str, ...]:
    return tuple(
        f"{ppp_version}|{release_version}|{resolved_version}"
        for ppp_version, (_, release_version, resolved_version) in sorted(
            versions.items(), key=lambda item: decimal_value(item[0], "ppp_version")
        )
    )


def build_pip_plan(base_url: str, timeout: float) -> WarmPlan:
    latest_by_ppp = latest_prod_versions(base_url, timeout)
    initial_snapshot = version_snapshot(latest_by_ppp)
    requests: list[WarmRequest] = []
    seen: set[tuple[str, str, str]] = set()
    for ppp_version in sorted(
        latest_by_ppp, key=lambda value: decimal_value(value, "ppp_version")
    ):
        _, _, resolved_version = latest_by_ppp[ppp_version]
        query = urlencode((("version", resolved_version),))
        poverty_lines = response_rows(
            get_json(f"{base_url}/poverty-lines?{query}", timeout),
            f"/poverty-lines for {resolved_version}",
        )
        names = {
            required_text(row, "name", f"/poverty-lines row for {resolved_version}")
            for row in poverty_lines
        }

        for povline in sorted(
            names, key=lambda value: (decimal_value(value, "poverty-line name"), value)
        ):
            for response_format in ("json", "csv"):
                key = (ppp_version, povline, response_format)
                if key in seen:
                    continue
                seen.add(key)
                cache_query = urlencode(
                    (
                        ("country", "all"),
                        ("year", "all"),
                        ("povline", povline),
                        ("ppp_version", ppp_version),
                        ("format", response_format),
                    )
                )
                requests.append(
                    WarmRequest(
                        url=f"{base_url}/pip?{cache_query}",
                        label=(
                            f"ppp={ppp_version} povline={povline} "
                            f"format={response_format}"
                        ),
                        response_format=response_format,
                    )
                )

    def verify_versions() -> None:
        final_snapshot = version_snapshot(latest_prod_versions(base_url, timeout))
        if final_snapshot != initial_snapshot:
            raise ValueError("the selected PROD versions changed during the run")

    return WarmPlan(requests=requests, verify=verify_versions)


SCENARIOS: dict[str, Callable[[str, float], WarmPlan]] = {
    "pip": build_pip_plan,
}


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
        required_header = {
            "country_code",
            "reporting_year",
            "poverty_line",
            "headcount",
            "poverty_gap",
            "mean",
        }
        if not required_header.issubset(header):
            raise ValueError("CSV response does not contain the required header")
        if not first_data_row:
            raise ValueError("CSV response does not contain a data row")

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
            plan = SCENARIOS[args.scenario](base_url, args.timeout)
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

    requests = plan.requests
    if args.limit is not None:
        requests = requests[: args.limit]
    if not requests:
        print("No cache-warming requests were generated.", file=sys.stderr)
        return 1

    print(f"Prepared {len(requests)} request(s).", flush=True)
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
