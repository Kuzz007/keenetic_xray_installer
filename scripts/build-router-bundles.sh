#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist/router-bundles}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/dist/router-bundle-work}"
ARCHES="${ARCHES:-arm64 mipsle}"
VERSION="${VERSION:-dev}"
CHANNEL="${CHANNEL:-dev}"
COMMIT="${COMMIT:-}"
PUBLISHED_AT="${PUBLISHED_AT:-}"

if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: go command not found" >&2
    exit 1
fi

if [ -z "$COMMIT" ] && command -v git >/dev/null 2>&1; then
    COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
fi
if [ -z "$PUBLISHED_AT" ]; then
    PUBLISHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

mkdir -p "$OUT_DIR" "$WORK_DIR/tools"
cd "$ROOT_DIR"

echo "Building host router-bundle packer..."
CGO_ENABLED=0 go build -trimpath -o "$WORK_DIR/tools/router-bundle-packer" ./cmd/router-bundle-packer

for arch in $ARCHES; do
    case "$arch" in
        arm64|mipsle) ;;
        *) echo "ERROR: unsupported router bundle architecture: $arch" >&2; exit 1 ;;
    esac

    arch_dir="$WORK_DIR/$arch"
    mkdir -p "$arch_dir"
    echo "Building router payload for linux/$arch..."
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GOMIPS=softfloat \
        go build -trimpath -ldflags "-s -w -X main.version=$VERSION" \
        -o "$arch_dir/xray-failover-go" ./cmd/xray-failover-go
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GOMIPS=softfloat \
        go build -trimpath -ldflags "-s -w -X main.agentVersion=$VERSION" \
        -o "$arch_dir/xray-go-agent" ./cmd/xray-go-agent
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GOMIPS=softfloat \
        go build -trimpath -ldflags "-s -w -X main.installerVersion=$VERSION" \
        -o "$arch_dir/keenetic-vpn-installer" ./cmd/keenetic-vpn-installer
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GOMIPS=softfloat \
        go build -trimpath -ldflags "-s -w -X main.slotVersion=$VERSION" \
        -o "$arch_dir/keenetic-awg-slot" ./cmd/keenetic-awg-slot

    echo "Building pinned AmneziaWG runtime for linux/$arch..."
    TARGET_ARCH="$arch" \
    OUT_DIR="$arch_dir/awg-runtime" \
    PROJECT_COMMIT="$COMMIT" \
        sh scripts/build-awg-runtime-probe.sh
    cp "$arch_dir/awg-runtime/amneziawg-go-linux-$arch" "$arch_dir/amneziawg-go"
    cp "$arch_dir/awg-runtime/amneziawg-tools-linux-$arch" "$arch_dir/amneziawg-tools"
    cp "$arch_dir/awg-runtime/amneziawg-go-LICENSE.txt" "$arch_dir/amneziawg-go-LICENSE.txt"
    cp "$arch_dir/awg-runtime/amneziawg-tools-COPYING.txt" "$arch_dir/amneziawg-tools-COPYING.txt"
    cp "$arch_dir/awg-runtime/amneziawg-tools-source-3.0.20260805.tar.gz" "$arch_dir/amneziawg-tools-source.tar.gz"
    cp "$arch_dir/awg-runtime/awg-runtime-provenance.txt" "$arch_dir/awg-runtime-provenance.txt"

    for edition in full minimal; do
        output="$OUT_DIR/keenetic-vpn-$edition-linux-$arch.run"
        "$WORK_DIR/tools/router-bundle-packer" \
            -stub "$arch_dir/keenetic-vpn-installer" \
            -spec "$ROOT_DIR/packaging/router/$edition.json" \
            -source-root "$ROOT_DIR" \
            -binary-dir "$arch_dir" \
            -out "$output" \
            -version "$VERSION" \
            -channel "$CHANNEL" \
            -commit "$COMMIT" \
            -arch "$arch" \
            -published-at "$PUBLISHED_AT"
        chmod 755 "$output"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$output" | awk '{print $1}' >"$output.sha256"
        fi
    done
done

echo "Router bundles are ready in: $OUT_DIR"
