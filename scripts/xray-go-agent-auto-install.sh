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
  --agent auto|unified|go|shell  Force agent type, default auto
  -h, --help

Auto policy:
  - arm64/aarch64: unified Go-agent
  - mipsel/mipsle/mipselsf: unified Go-agent mipsle asset
  - mips: unified Go-agent mips asset
  - unknown: legacy shell-agent fallback

Rollback:
  - pass --agent shell to install legacy shell-agent explicitly
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
    unified|go|shell) echo "$forced"; return 0 ;;
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
  echo "Detected Entware arch: $(opkg_arches || true)"
  echo "Detected kernel arch: $(kernel_arch)"
  echo "Selected agent: $selected"

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

  eval "\"$installer\"$args"
}

main "$@"
