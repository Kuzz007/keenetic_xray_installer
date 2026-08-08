#!/opt/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
REF="${REF:-main}"
TAG="${TAG:-}"
BOOTSTRAP_CONF="${BOOTSTRAP_CONF:-/opt/etc/xray/xray-go-agent.conf}"
FORCE_AGENT="${FORCE_AGENT:-auto}"
FORCE_LEGACY_SHELL="${FORCE_LEGACY_SHELL:-0}"
BOOTSTRAP_ARGS=""

usage() {
  cat <<EOF
Usage: xray-go-agent-auto-install [options]

Options are passed through to the selected installer:
  --server-url URL
  --router-id ID
  --router-name NAME
  --agent-token TOKEN
  --poll-interval SEC
  --agent auto|unified|go|shell|legacy-shell  Force agent type, default auto
  -h, --help

Auto policy:
  - arm64/aarch64: unified Go-agent
  - mipsel/mipsle/mipselsf: unified Go-agent mipsle asset
  - mips: unified Go-agent mips asset
  - unknown: legacy shell-agent fallback

Migration compatibility:
  - old shell-agent self-update calls this installer with --agent shell
  - --agent shell is treated as unified migration by default

Rollback:
  - pass --agent legacy-shell to install legacy shell-agent explicitly
  - or use FORCE_LEGACY_SHELL=1 with --agent shell
  - pass --agent go to install legacy Go-agent installer explicitly
EOF
}

opkg_arches() {
  if command -v opkg >/dev/null 2>&1; then
    opkg print-architecture 2>/dev/null | awk '{print $2}' | tr '\n' ' '
  fi
}

kernel_arch() {
  uname -m 2>/dev/null || echo unknown
}

detect_agent() {
  forced="$1"
  case "$forced" in
    unified|go) echo "$forced"; return 0 ;;
    legacy-shell) echo shell; return 0 ;;
    shell)
      if [ "$FORCE_LEGACY_SHELL" = "1" ]; then
        echo shell
      else
        echo unified
      fi
      return 0
      ;;
    auto) ;;
    *) echo "ERROR: invalid --agent value: $forced" >&2; exit 1 ;;
  esac

  oa="$(opkg_arches || true)"
  ka="$(kernel_arch)"
  hint="$oa $ka"
  case "$hint" in
    *aarch64*|*arm64*|*mipselsf*|*mipsel*|*mipsle*|*mips*)
      echo unified
      ;;
    *)
      echo shell
      ;;
  esac
}

download_installer() {
  name="$1"
  dst="/opt/bin/$name"
  url="https://raw.githubusercontent.com/${REPO}/${REF}/scripts/${name}.sh"
  tmp="${dst}.tmp.$$"
  mkdir -p /opt/bin
  echo "Downloading: $url" >&2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tmp" "$url"
  else
    echo "ERROR: curl or wget required" >&2
    exit 1
  fi
  chmod +x "$tmp"
  mv "$tmp" "$dst"
  echo "Installed installer: $dst" >&2
  printf '%s\n' "$dst"
}

shell_quote() {
  printf '%s' "$1" | sed "s/'/'\\''/g"
}

discover_bootstrap_profile() {
  if [ -n "$TAG" ]; then
    export TAG
    return 0
  fi
  TAG="latest"
  [ -f "$BOOTSTRAP_CONF" ] || { export TAG; return 0; }
  if ! grep -Eq '^[[:space:]]*(SERVER_URL|AGENT_TOKEN)=' "$BOOTSTRAP_CONF" 2>/dev/null; then
    export TAG
    return 0
  fi

  SERVER_URL="" AGENT_TOKEN=""
  . "$BOOTSTRAP_CONF" || true
  [ -n "${SERVER_URL:-}" ] && [ -n "${AGENT_TOKEN:-}" ] || { export TAG; return 0; }
  case "$SERVER_URL" in
    http://*|https://*) ;;
    *) export TAG; return 0 ;;
  esac

  endpoint="${SERVER_URL%/}/agent/bootstrap"
  response="/opt/tmp/xray-go-agent-bootstrap.$$"
  rm -f "$response"
  if command -v curl >/dev/null 2>&1; then
    case "$endpoint" in
      https://*) curl -kfsS --max-time 20 -H "Authorization: Bearer $AGENT_TOKEN" -o "$response" "$endpoint" 2>/dev/null || true ;;
      *) curl -fsS --max-time 20 -H "Authorization: Bearer $AGENT_TOKEN" -o "$response" "$endpoint" 2>/dev/null || true ;;
    esac
  elif command -v wget >/dev/null 2>&1; then
    case "$endpoint" in
      https://*) wget --no-check-certificate -qO "$response" --header="Authorization: Bearer $AGENT_TOKEN" "$endpoint" 2>/dev/null || true ;;
      *) wget -qO "$response" --header="Authorization: Bearer $AGENT_TOKEN" "$endpoint" 2>/dev/null || true ;;
    esac
  fi
  [ -s "$response" ] || { rm -f "$response"; export TAG; return 0; }

  channel="$(sed -n 's/^channel=//p' "$response" | sed -n '1p')"
  bootstrap_server="$(sed -n 's/^server_url=//p' "$response" | sed -n '1p')"
  bootstrap_fingerprint="$(sed -n 's/^server_fingerprint=//p' "$response" | sed -n '1p' | tr 'A-F' 'a-f')"
  rm -f "$response"

  case "$channel" in
    latest|dev) TAG="$channel" ;;
    *) TAG="latest" ;;
  esac
  case "$bootstrap_server" in
    https://*) ;;
    *) bootstrap_server="" ;;
  esac
  case "$bootstrap_server" in
    *[[:space:]]*) bootstrap_server="" ;;
  esac
  case "$bootstrap_fingerprint" in
    *[!0-9a-f]*) bootstrap_fingerprint="" ;;
  esac
  [ "${#bootstrap_fingerprint}" -eq 64 ] || bootstrap_fingerprint=""

  if [ -n "$bootstrap_server" ] && [ -n "$bootstrap_fingerprint" ]; then
    quoted_server="$(shell_quote "$bootstrap_server")"
    quoted_fingerprint="$(shell_quote "$bootstrap_fingerprint")"
    BOOTSTRAP_ARGS=" --server-url '$quoted_server' --server-fingerprint '$quoted_fingerprint'"
    echo "Control-server bootstrap: selected $TAG and pinned TLS migration."
  else
    echo "Control-server bootstrap: selected $TAG; existing connection settings preserved."
  fi
  export TAG
}

main() {
  args=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent)
        [ "$#" -ge 2 ] || { echo "ERROR: --agent requires value" >&2; exit 1; }
        FORCE_AGENT="$2"; shift 2 ;;
      --agent=*)
        FORCE_AGENT="${1#--agent=}"; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        quoted="$(printf "%s" "$1" | sed "s/'/'\\''/g")"
        args="$args '$quoted'"
        shift ;;
    esac
  done

  discover_bootstrap_profile

  selected="$(detect_agent "$FORCE_AGENT")"
  echo "Detected Entware arch: $(opkg_arches || true)"
  echo "Detected kernel arch: $(kernel_arch)"
  echo "Requested agent: $FORCE_AGENT"
  echo "Selected agent: $selected"
  echo "Selected release channel: $TAG"

  case "$selected" in
    unified)
      installer="$(download_installer xray-go-agent-unified-install)"
      ;;
    go)
      /opt/etc/init.d/S28xray-go-agent-shell stop 2>/dev/null || true
      rm -f /opt/etc/init.d/S28xray-go-agent-shell /opt/bin/xray-go-agent-shell
      installer="$(download_installer xray-go-agent-install)"
      ;;
    shell)
      installer="$(download_installer xray-go-agent-shell-install)"
      ;;
  esac

  eval "\"$installer\"$BOOTSTRAP_ARGS$args"
}

main "$@"
