#!/usr/bin/env python3
"""Update machine-readable route lists under routes/.

The repository stores route entries as:

    <list_id>|<domain-or-ipv4-cidr>

This updater intentionally touches only lists backed by stable public APIs. Manual
or mixed domain lists are left unchanged.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import sys
import urllib.request
from datetime import date
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
ROUTES_DIR = ROOT / "routes"
INDEX_PATH = ROUTES_DIR / "index.json"

USER_AGENT = "keenetic-xray-routes-updater/1.0 (+https://github.com/Kuzz007/keenetic_xray_installer)"
TIMEOUT = 45


def fetch_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:  # nosec: controlled updater URLs
        return resp.read().decode("utf-8")


def fetch_json(url: str) -> object:
    return json.loads(fetch_text(url))


def clean_ipv4_networks(values: Iterable[str]) -> list[str]:
    networks: set[ipaddress.IPv4Network] = set()
    for raw in values:
        value = str(raw).strip()
        if not value:
            continue
        try:
            net = ipaddress.ip_network(value, strict=False)
        except ValueError as exc:
            raise ValueError(f"invalid network from upstream: {value!r}") from exc
        if net.version != 4:
            continue
        networks.add(net)  # type: ignore[arg-type]
    return [str(net) for net in sorted(networks, key=lambda n: (int(n.network_address), n.prefixlen))]


def fetch_cloudflare() -> list[str]:
    # Official Cloudflare IPv4 list.
    return clean_ipv4_networks(fetch_text("https://www.cloudflare.com/ips-v4").splitlines())


def fetch_fastly() -> list[str]:
    # Official Fastly public IP API. Only IPv4 is useful for the current Keenetic route helper.
    data = fetch_json("https://api.fastly.com/public-ip-list")
    if not isinstance(data, dict):
        raise TypeError("Fastly response is not an object")
    return clean_ipv4_networks(data.get("addresses", []))


def fetch_aws_cloudfront() -> list[str]:
    # Official AWS IP ranges. The existing `amazon` route list is CloudFront-focused.
    data = fetch_json("https://ip-ranges.amazonaws.com/ip-ranges.json")
    if not isinstance(data, dict):
        raise TypeError("AWS response is not an object")
    prefixes = data.get("prefixes", [])
    if not isinstance(prefixes, list):
        raise TypeError("AWS prefixes is not a list")
    values = []
    for item in prefixes:
        if not isinstance(item, dict):
            continue
        if item.get("service") == "CLOUDFRONT" and "ip_prefix" in item:
            values.append(str(item["ip_prefix"]))
    return clean_ipv4_networks(values)


MANAGED_LISTS = {
    "amazon": fetch_aws_cloudfront,
    "cloudflare": fetch_cloudflare,
    "fastly": fetch_fastly,
}


def route_file_for_id(index: dict, list_id: str) -> Path:
    lists = index.get("lists")
    if not isinstance(lists, list):
        raise ValueError("routes/index.json does not contain a lists array")
    for item in lists:
        if isinstance(item, dict) and item.get("id") == list_id:
            filename = item.get("file")
            if not isinstance(filename, str) or not filename.endswith(".txt") or "/" in filename or "\\" in filename:
                raise ValueError(f"unsafe route file for {list_id}: {filename!r}")
            return ROUTES_DIR / filename
    raise KeyError(f"list id not found in index: {list_id}")


def render_list(list_id: str, values: list[str]) -> str:
    if not values:
        raise ValueError(f"upstream returned no entries for {list_id}")
    return "".join(f"{list_id}|{value}\n" for value in values)


def validate_route_text(list_id: str, text: str) -> None:
    seen = set()
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not line:
            raise ValueError(f"{list_id}: empty line at {lineno}")
        left, sep, right = line.partition("|")
        if sep != "|" or left != list_id or not right:
            raise ValueError(f"{list_id}: invalid line {lineno}: {line!r}")
        if right in seen:
            raise ValueError(f"{list_id}: duplicate value at line {lineno}: {right}")
        seen.add(right)
        try:
            net = ipaddress.ip_network(right, strict=False)
        except ValueError as exc:
            raise ValueError(f"{list_id}: invalid network at line {lineno}: {right}") from exc
        if net.version != 4:
            raise ValueError(f"{list_id}: IPv6 is not supported by this updater: {right}")


def update_index_date_if_needed(index: dict, changed: bool) -> None:
    if not changed:
        return
    index["updated"] = date.today().isoformat()
    INDEX_PATH.write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Update GitHub-hosted routes/*.txt from public APIs")
    parser.add_argument("--check", action="store_true", help="validate managed routes without writing")
    parser.add_argument("--list", dest="only", action="append", choices=sorted(MANAGED_LISTS), help="update only one managed list; may be repeated")
    args = parser.parse_args()

    index = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
    target_ids = args.only or sorted(MANAGED_LISTS)

    changed = False
    for list_id in target_ids:
        values = MANAGED_LISTS[list_id]()
        text = render_list(list_id, values)
        validate_route_text(list_id, text)
        path = route_file_for_id(index, list_id)
        old = path.read_text(encoding="utf-8") if path.exists() else ""
        if old != text:
            print(f"updated {path.relative_to(ROOT)}: {len(values)} entries")
            changed = True
            if not args.check:
                path.write_text(text, encoding="utf-8")
        else:
            print(f"unchanged {path.relative_to(ROOT)}: {len(values)} entries")

    if changed and not args.check:
        # Re-read index so any prior formatting is normalized only when route data changes.
        index = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
        update_index_date_if_needed(index, changed=True)
    elif changed and args.check:
        print("managed routes are out of date", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
