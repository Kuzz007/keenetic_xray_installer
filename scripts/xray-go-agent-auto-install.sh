#!/opt/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
REF="${REF:-main}"
FORCE_AGENT="${FORCE_AGENT:-auto}"

usage() {
  cat <<EOF
Usage: xray-go-agent-auto-install [options]

Options are passed through to the selected installer:
  --server-url URL
  --router-id ID
  --router-name NAME
  --agent-token TOKEN
  --poll-interval SEC
  --agent auto|go|shell  Force agent type, default auto
  -h, --help

Auto policy:
  - arm64/aarch64: Go-agent
  - mips/mipsel/mipsle/mipselsf: Legacy shell-agent
  - unknown: Legacy shell-agent
EOF
}

opkg_arch() {
  if command -v opkg >/dev/null 2>&1; then
    opkg print-architecture 2>/dev/null | awk 'NR==1{print $2}'
  fi
}

kernel_arch() {
  uname -m 2>/dev/null || echo unknown
}

detect_agent() {
  forced="$1"
  case "$forced" in
    go|shell) echo "$forced"; return 0 ;;
    auto) ;;
    *) echo "ERROR: invalid --agent value: $forced" >&2; exit 1 ;;
  esac

  oa="$(opkg_arch || true)"
  ka="$(kernel_arch)"
  case "$oa:$ka" in
    *aarch64*:*|*arm64*:*|*:aarch64|*:arm64)
      echo go
      ;;
    *mips*:*|*:mips*)
      echo shell
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
  echo "Downloading: $url"
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
  echo "$dst"
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

  selected="$(detect_agent "$FORCE_AGENT")"
  echo "Detected Entware arch: $(opkg_arch || true)"
  echo "Detected kernel arch: $(kernel_arch)"
  echo "Selected agent: $selected"

  case "$selected" in
    go)
      /opt/etc/init.d/S28xray-go-agent-shell stop 2>/dev/null || true
      rm -f /opt/etc/init.d/S28xray-go-agent-shell /opt/bin/xray-go-agent-shell
      installer="$(download_installer xray-go-agent-install)"
      ;;
    shell)
      installer="$(download_installer xray-go-agent-shell-install)"
      ;;
  esac

  eval "\"$installer\"$args"
}

main "$@"
