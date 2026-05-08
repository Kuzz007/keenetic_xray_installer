#!/bin/sh
set -e

# Initializes a safe modular layout without changing script behavior.
# It keeps original monolithic installers in legacy/monolith/ and creates
# editable source copies under src/full/ and src/minimal/.

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

FULL_ROOT="xray_vless_failover.sh"
MINIMAL_ROOT="xray_vless_failover_minimal.sh"

LEGACY_DIR="legacy/monolith"
SRC_FULL_DIR="src/full"
SRC_MINIMAL_DIR="src/minimal"

mkdir -p "$LEGACY_DIR" "$SRC_FULL_DIR" "$SRC_MINIMAL_DIR" scripts

copy_if_missing() {
    SRC="$1"
    DST="$2"
    if [ ! -f "$SRC" ]; then
        echo "Missing source: $SRC" >&2
        return 1
    fi
    if [ -f "$DST" ]; then
        echo "Keep existing: $DST"
    else
        cp "$SRC" "$DST"
        echo "Created: $DST"
    fi
}

copy_if_missing "$FULL_ROOT" "$LEGACY_DIR/$FULL_ROOT"
copy_if_missing "$MINIMAL_ROOT" "$LEGACY_DIR/$MINIMAL_ROOT"
copy_if_missing "$FULL_ROOT" "$SRC_FULL_DIR/$FULL_ROOT"
copy_if_missing "$MINIMAL_ROOT" "$SRC_MINIMAL_DIR/$MINIMAL_ROOT"

cat > scripts/build-installers.sh <<'BUILD'
#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

FULL_SRC="src/full/xray_vless_failover.sh"
MINIMAL_SRC="src/minimal/xray_vless_failover_minimal.sh"
FULL_OUT="xray_vless_failover.sh"
MINIMAL_OUT="xray_vless_failover_minimal.sh"

[ -f "$FULL_SRC" ] || { echo "Missing: $FULL_SRC" >&2; exit 1; }
[ -f "$MINIMAL_SRC" ] || { echo "Missing: $MINIMAL_SRC" >&2; exit 1; }

cp "$FULL_SRC" "$FULL_OUT"
cp "$MINIMAL_SRC" "$MINIMAL_OUT"

chmod +x "$FULL_OUT" "$MINIMAL_OUT"
sh -n "$FULL_OUT"
sh -n "$MINIMAL_OUT"

echo "Built: $FULL_OUT"
echo "Built: $MINIMAL_OUT"
BUILD

chmod +x scripts/build-installers.sh

cat > legacy/README.md <<'README'
# Legacy monolithic installers

This directory stores original monolithic installer scripts as a safety backup.

Do not edit files here for normal development.
Use `src/full/` and `src/minimal/` instead, then run:

```sh
sh scripts/build-installers.sh
```
README

cat > src/README.md <<'README'
# Source installers

This directory is the editable source area.

Current first-stage layout:

- `src/full/xray_vless_failover.sh`
- `src/minimal/xray_vless_failover_minimal.sh`

Build root installers with:

```sh
sh scripts/build-installers.sh
```

Later these files can be split into smaller modules such as:

- `proxy0.sh`
- `healthcheck.sh`
- `daemon.sh`
- `status.sh`
- `menu.sh`
README

echo
echo "Modular layout initialized."
echo
echo "Next commands:"
echo "  sh scripts/build-installers.sh"
echo "  git status"
echo "  git add legacy src scripts/build-installers.sh scripts/init-modular-layout.sh"
echo "  git commit -m 'Initialize modular installer layout'"
echo "  git push"
