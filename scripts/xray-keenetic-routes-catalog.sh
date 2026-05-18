#!/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
REF="${REF:-main}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/routes}"
CACHE_DIR="${CACHE_DIR:-/opt/var/cache/xray-routes}"
BACKUP_DIR="${BACKUP_DIR:-/opt/etc/xray/route-backups}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
POLICY_NAME="${POLICY_NAME:-Policy0}"
INDEX_FILE="$CACHE_DIR/index.json"
FAILED_CMDS_FILE=""

need_fetch_tool() {
  if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL"
  elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO-"
  else
    echo "ERROR: curl or wget required" >&2
    exit 1
  fi
}

need_ndmc() {
  if ! command -v ndmc >/dev/null 2>&1; then
    echo "ERROR: ndmc not found. Run on Keenetic/Entware." >&2
    exit 1
  fi
}

fetch_url() {
  need_fetch_tool
  # shellcheck disable=SC2086
  $FETCH "$1"
}

valid_id() {
  case "$1" in
    ""|*[!a-zA-Z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

index_fetch() {
  mkdir -p "$CACHE_DIR"
  tmp="$INDEX_FILE.tmp.$$"
  fetch_url "$BASE_URL/index.json" > "$tmp"
  grep -q '"lists"' "$tmp" || { rm -f "$tmp"; echo "ERROR: invalid index: lists not found" >&2; exit 1; }
  mv "$tmp" "$INDEX_FILE"
  echo "Fetched index: $INDEX_FILE"
}

index_require() {
  if [ ! -s "$INDEX_FILE" ]; then
    index_fetch >/dev/null
  fi
}

list_catalog() {
  index_fetch >/dev/null
  echo "Routes catalog:"
  awk '
    /"id"[[:space:]]*:/ { id=$0; gsub(/^.*"id"[[:space:]]*:[[:space:]]*"/, "", id); gsub(/".*$/, "", id) }
    /"title"[[:space:]]*:/ { title=$0; gsub(/^.*"title"[[:space:]]*:[[:space:]]*"/, "", title); gsub(/".*$/, "", title); if (id != "") { printf "  %s | %s\n", id, title; id="" } }
  ' "$INDEX_FILE"
}

file_for_id() {
  id="$1"
  valid_id "$id" || { echo "ERROR: invalid list id: $id" >&2; exit 1; }
  index_require
  awk -v want="$id" '
    /"id"[[:space:]]*:/ { id=$0; gsub(/^.*"id"[[:space:]]*:[[:space:]]*"/, "", id); gsub(/".*$/, "", id) }
    /"file"[[:space:]]*:/ { file=$0; gsub(/^.*"file"[[:space:]]*:[[:space:]]*"/, "", file); gsub(/".*$/, "", file); if (id == want) { print file; found=1; exit } }
    END { if (!found) exit 1 }
  ' "$INDEX_FILE" || { echo "ERROR: list id not found in index: $id" >&2; exit 1; }
}

download_list() {
  id="$1"
  file="$(file_for_id "$id")"
  case "$file" in
    *../*|/*|*\\*) echo "ERROR: unsafe file path in index: $file" >&2; exit 1 ;;
  esac
  mkdir -p "$CACHE_DIR/lists"
  out="$CACHE_DIR/lists/$id.txt"
  tmp="$out.tmp.$$"
  fetch_url "$BASE_URL/$file" > "$tmp"
  validate_list_file "$id" "$tmp"
  mv "$tmp" "$out"
  echo "$out"
}

validate_list_file() {
  id="$1"
  path="$2"
  awk -F'|' -v want="$id" '
    NF != 2 { printf "ERROR: invalid line %d: %s\n", NR, $0 > "/dev/stderr"; exit 1 }
    $1 != want { printf "ERROR: list id mismatch line %d: expected %s got %s\n", NR, want, $1 > "/dev/stderr"; exit 1 }
    $2 == "" { printf "ERROR: empty value line %d\n", NR > "/dev/stderr"; exit 1 }
  ' "$path"
}

is_ipv4_or_cidr() {
  case "$1" in
    *[!0-9./]*|*.*.*.*.*|*/*/*) return 1 ;;
    *.*.*.*) return 0 ;;
    *) return 1 ;;
  esac
}

count_ipv4_or_cidr() {
  path="$1"
  awk -F'|' '{print $2}' "$path" | while read -r item; do
    is_ipv4_or_cidr "$item" && echo yes || true
  done | wc -l | tr -d ' '
}

preview_list() {
  id="$1"
  path="$(download_list "$id")"
  total="$(wc -l < "$path" | tr -d ' ')"
  cidr="$(count_ipv4_or_cidr "$path")"
  fqdn=$((total - cidr))
  echo "Route list preview"
  echo "id: $id"
  echo "source: $BASE_URL/$(file_for_id "$id")"
  echo "entries: $total"
  echo "fqdn: $fqdn"
  echo "ipv4_cidr: $cidr"
  echo
  echo "First entries:"
  sed -n '1,30p' "$path"
}

quiet_ndmc() {
  ndmc -c "$1" >/dev/null 2>&1 || true
}

try_ndmc() {
  cmd="$1"
  out="$(ndmc -c "$cmd" 2>&1)" && return 0
  rc="$?"
  if [ -n "$FAILED_CMDS_FILE" ]; then
    {
      echo "+ ndmc -c $cmd"
      echo "$out"
      echo "rc=$rc"
      echo
    } >> "$FAILED_CMDS_FILE"
  fi
  return "$rc"
}

run_ndmc() {
  echo "+ ndmc -c $1"
  ndmc -c "$1"
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  backup="$BACKUP_DIR/running-config-before-route-list-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now).txt"
  ndmc -c "show running-config" > "$backup"
  echo "$backup"
}

cidr_to_mask() {
  prefix="$1"
  case "$prefix" in
    0) echo "0.0.0.0" ;; 1) echo "128.0.0.0" ;; 2) echo "192.0.0.0" ;; 3) echo "224.0.0.0" ;;
    4) echo "240.0.0.0" ;; 5) echo "248.0.0.0" ;; 6) echo "252.0.0.0" ;; 7) echo "254.0.0.0" ;;
    8) echo "255.0.0.0" ;; 9) echo "255.128.0.0" ;; 10) echo "255.192.0.0" ;; 11) echo "255.224.0.0" ;;
    12) echo "255.240.0.0" ;; 13) echo "255.248.0.0" ;; 14) echo "255.252.0.0" ;; 15) echo "255.254.0.0" ;;
    16) echo "255.255.0.0" ;; 17) echo "255.255.128.0" ;; 18) echo "255.255.192.0" ;; 19) echo "255.255.224.0" ;;
    20) echo "255.255.240.0" ;; 21) echo "255.255.248.0" ;; 22) echo "255.255.252.0" ;; 23) echo "255.255.254.0" ;;
    24) echo "255.255.255.0" ;; 25) echo "255.255.255.128" ;; 26) echo "255.255.255.192" ;; 27) echo "255.255.255.224" ;;
    28) echo "255.255.255.240" ;; 29) echo "255.255.255.248" ;; 30) echo "255.255.255.252" ;; 31) echo "255.255.255.254" ;;
    32) echo "255.255.255.255" ;; *) return 1 ;;
  esac
}

ip_route_parts() {
  item="$1"
  case "$item" in
    */*)
      network="${item%/*}"
      prefix="${item#*/}"
      mask="$(cidr_to_mask "$prefix")" || return 1
      if [ "$prefix" = "32" ]; then echo "$network"; else echo "$network $mask"; fi
      ;;
    *) echo "$item" ;;
  esac
}

remove_policy_route() {
  route_parts="$1"
  # Different KeeneticOS builds accept different no-route forms.
  # Try the most specific forms first; treat at least one success as removed.
  ok=1
  try_ndmc "ip policy $POLICY_NAME no route $route_parts $PROXY_IFACE auto" && ok=0
  try_ndmc "ip policy $POLICY_NAME no route $route_parts $PROXY_IFACE" && ok=0
  try_ndmc "ip policy $POLICY_NAME no route $route_parts" && ok=0
  try_ndmc "no ip policy $POLICY_NAME route $route_parts $PROXY_IFACE auto" && ok=0
  try_ndmc "no ip policy $POLICY_NAME route $route_parts $PROXY_IFACE" && ok=0
  try_ndmc "no ip policy $POLICY_NAME route $route_parts" && ok=0
  return "$ok"
}

remove_list_nosave() {
  id="$1"
  quiet_ndmc "dns-proxy no route object-group $id $PROXY_IFACE auto"
  quiet_ndmc "no dns-proxy route object-group $id $PROXY_IFACE auto"
  quiet_ndmc "no object-group fqdn $id"
}

apply_list() {
  id="$1"
  need_ndmc
  path="$(download_list "$id")"
  total="$(wc -l < "$path" | tr -d ' ')"
  cidr_total="$(count_ipv4_or_cidr "$path")"
  fqdn_total=$((total - cidr_total))
  FAILED_CMDS_FILE="/tmp/xray-routes-failed.$$"
  : > "$FAILED_CMDS_FILE"

  backup="$(backup_config)"
  remove_list_nosave "$id"

  fqdn_ok=0
  web_cidr_ok=0
  cidr_policy_ok=0
  failed=0

  try_ndmc "object-group fqdn $id" || failed=$((failed + 1))
  try_ndmc "object-group fqdn $id description xray-route-list-$id" || failed=$((failed + 1))

  while IFS='|' read -r _ item; do
    [ -n "$item" ] || continue
    if is_ipv4_or_cidr "$item"; then
      if try_ndmc "object-group fqdn $id include $item"; then
        web_cidr_ok=$((web_cidr_ok + 1))
      else
        failed=$((failed + 1))
      fi
      route_parts="$(ip_route_parts "$item")" || { failed=$((failed + 1)); continue; }
      if try_ndmc "ip policy $POLICY_NAME route $route_parts $PROXY_IFACE auto"; then
        cidr_policy_ok=$((cidr_policy_ok + 1))
      else
        failed=$((failed + 1))
      fi
    else
      if try_ndmc "object-group fqdn $id include $item"; then
        fqdn_ok=$((fqdn_ok + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done < "$path"

  try_ndmc "dns-proxy route object-group $id $PROXY_IFACE auto" || failed=$((failed + 1))

  save_status="failed"
  if run_ndmc "system configuration save"; then
    save_status="ok"
  else
    failed=$((failed + 1))
  fi

  echo
  echo "Routes apply summary"
  echo "id: $id"
  echo "backup: $backup"
  echo "fqdn_added: $fqdn_ok/$fqdn_total"
  echo "web_visible_cidr_added: $web_cidr_ok/$cidr_total"
  echo "ipv4_cidr_policy_added: $cidr_policy_ok/$cidr_total"
  echo "failed_commands: $failed"
  echo "save: $save_status"

  if [ "$failed" -gt 0 ]; then
    echo
    echo "Failed ndmc commands:"
    sed -n '1,80p' "$FAILED_CMDS_FILE"
    rm -f "$FAILED_CMDS_FILE"
    return 1
  fi

  rm -f "$FAILED_CMDS_FILE"
  echo "Applied: $id"
}

remove_list() {
  id="$1"
  need_ndmc
  valid_id "$id" || { echo "ERROR: invalid list id: $id" >&2; exit 1; }
  path="$(download_list "$id")"
  cidr_total="$(count_ipv4_or_cidr "$path")"
  FAILED_CMDS_FILE="/tmp/xray-routes-failed.$$"
  : > "$FAILED_CMDS_FILE"

  backup="$(backup_config)"

  cidr_removed=0
  failed=0
  while IFS='|' read -r _ item; do
    [ -n "$item" ] || continue
    if is_ipv4_or_cidr "$item"; then
      route_parts="$(ip_route_parts "$item")" || { failed=$((failed + 1)); continue; }
      if remove_policy_route "$route_parts"; then
        cidr_removed=$((cidr_removed + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done < "$path"

  remove_list_nosave "$id"

  save_status="failed"
  if run_ndmc "system configuration save"; then
    save_status="ok"
  else
    failed=$((failed + 1))
  fi

  echo
  echo "Routes remove summary"
  echo "id: $id"
  echo "backup: $backup"
  echo "ipv4_cidr_policy_removed: $cidr_removed/$cidr_total"
  echo "failed_commands: $failed"
  echo "save: $save_status"

  if [ "$failed" -gt 0 ]; then
    echo
    echo "Failed ndmc commands:"
    sed -n '1,80p' "$FAILED_CMDS_FILE"
    rm -f "$FAILED_CMDS_FILE"
    return 1
  fi

  rm -f "$FAILED_CMDS_FILE"
  echo "Removed managed route list: $id"
}

usage() {
  cat <<EOF
Usage: $0 <command> [list_id]

Commands:
  fetch-index          Download routes/index.json from repo
  list                 Show lists from repo catalog
  preview <list_id>    Download and preview one list
  apply <list_id>      Apply one list to Keenetic
  remove <list_id>     Remove one managed list from Keenetic

Environment:
  REPO=$REPO
  REF=$REF
  BASE_URL=$BASE_URL
  PROXY_IFACE=$PROXY_IFACE
  POLICY_NAME=$POLICY_NAME
EOF
}

cmd="${1:-help}"
case "$cmd" in
  fetch-index) index_fetch ;;
  list) list_catalog ;;
  preview) [ "${2:-}" ] || { usage; exit 1; }; preview_list "$2" ;;
  apply) [ "${2:-}" ] || { usage; exit 1; }; apply_list "$2" ;;
  remove) [ "${2:-}" ] || { usage; exit 1; }; remove_list "$2" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
