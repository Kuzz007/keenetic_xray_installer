#!/bin/sh
set -eu

AWG_GO_VERSION="${AWG_GO_VERSION:-v3.0.20260805}"
AWG_GO_COMMIT="${AWG_GO_COMMIT:-08d68cdae27762c3e07f36bbb12d2bad32f81926}"
AWG_TOOLS_VERSION="${AWG_TOOLS_VERSION:-v3.0.20260805}"
AWG_TOOLS_COMMIT="${AWG_TOOLS_COMMIT:-9f70177d204d5be66c5b043518a57b7d62b3f9d1}"
TARGET_ARCH="${TARGET_ARCH:-}"
OUT_DIR="${OUT_DIR:-dist/awg-runtime-probe}"

case "$TARGET_ARCH" in
amd64)
    goarch="amd64"
    cc="gcc"
    ;;
arm64)
    goarch="arm64"
    cc="aarch64-linux-gnu-gcc"
    ;;
mipsle)
    goarch="mipsle"
    cc="mipsel-linux-gnu-gcc"
    ;;
*)
    echo "ERROR: TARGET_ARCH must be amd64, arm64 or mipsle" >&2
    exit 2
    ;;
esac

for command_name in git go make "$cc" sha256sum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    fi
done

build_tmp="$(mktemp -d "${TMPDIR:-/tmp}/keenetic-awg-build.XXXXXX")"
cleanup() {
    rm -rf "$build_tmp"
}
trap cleanup 0 1 2 15

go_source="$build_tmp/amneziawg-go"
tools_source="$build_tmp/amneziawg-tools"

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$AWG_GO_VERSION" \
    https://github.com/amnezia-vpn/amneziawg-go.git "$go_source"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$AWG_TOOLS_VERSION" \
    https://github.com/amnezia-vpn/amneziawg-tools.git "$tools_source"

actual_go_commit="$(git -C "$go_source" rev-parse HEAD)"
actual_tools_commit="$(git -C "$tools_source" rev-parse HEAD)"
if [ "$actual_go_commit" != "$AWG_GO_COMMIT" ]; then
    echo "ERROR: amneziawg-go tag resolved to $actual_go_commit, expected $AWG_GO_COMMIT" >&2
    exit 1
fi
if [ "$actual_tools_commit" != "$AWG_TOOLS_COMMIT" ]; then
    echo "ERROR: amneziawg-tools tag resolved to $actual_tools_commit, expected $AWG_TOOLS_COMMIT" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(CDPATH= cd -- "$OUT_DIR" && pwd)"
runtime_out="$OUT_DIR/amneziawg-go-linux-$TARGET_ARCH"
tools_out="$OUT_DIR/amneziawg-tools-linux-$TARGET_ARCH"
tools_source_out="$OUT_DIR/amneziawg-tools-source-${AWG_TOOLS_VERSION#v}.tar.gz"

(
    cd "$go_source"
    CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOMIPS=softfloat \
        go build -trimpath -ldflags "-s -w" -o "$runtime_out" .
)

make -C "$tools_source/src" TARGET_ARCH= clean >/dev/null
make -C "$tools_source/src" \
    TARGET_ARCH= \
    PLATFORM=linux \
    RUNSTATEDIR=/var/run \
    CC="$cc" \
    LDFLAGS="-static -s" \
    wg
cp "$tools_source/src/wg" "$tools_out"
git -C "$tools_source" archive --format=tar.gz \
    --prefix="amneziawg-tools-${AWG_TOOLS_VERSION#v}/" \
    -o "$tools_source_out" HEAD
cp "$go_source/LICENSE" "$OUT_DIR/amneziawg-go-LICENSE.txt"
cp "$tools_source/COPYING" "$OUT_DIR/amneziawg-tools-COPYING.txt"
chmod 0755 "$runtime_out" "$tools_out"

sha256sum "$runtime_out" | awk '{print $1}' >"$runtime_out.sha256"
sha256sum "$tools_out" | awk '{print $1}' >"$tools_out.sha256"
sha256sum "$tools_source_out" | awk '{print $1}' >"$tools_source_out.sha256"

cat >"$OUT_DIR/awg-runtime-provenance.txt" <<EOF
amneziawg_go_version=$AWG_GO_VERSION
amneziawg_go_commit=$AWG_GO_COMMIT
amneziawg_tools_version=$AWG_TOOLS_VERSION
amneziawg_tools_commit=$AWG_TOOLS_COMMIT
target=linux/$TARGET_ARCH
runtime_source=https://github.com/amnezia-vpn/amneziawg-go
tools_source=https://github.com/amnezia-vpn/amneziawg-tools
EOF

printf 'Built %s (%s bytes)\n' "$runtime_out" "$(wc -c <"$runtime_out" | tr -d ' ')"
printf 'Built %s (%s bytes)\n' "$tools_out" "$(wc -c <"$tools_out" | tr -d ' ')"
