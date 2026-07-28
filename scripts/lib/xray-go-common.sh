# Shared helpers used across install.sh and several scripts/*.sh entrypoints.
#
# This file is not meant to be sourced at runtime - scripts/build-generated-scripts.sh
# concatenates it into each published script (from scripts/src/direct/ and
# scripts/src/misc/) so every one of them stays a single self-contained file,
# safe to curl and run directly. Edit the functions here, then run
# scripts/build-generated-scripts.sh to regenerate the published scripts; do
# not hand-edit these function bodies in the generated files.
#
# Not every published script uses every function here - each still gets the
# full set, since a few unused shell functions cost nothing at runtime and
# it keeps this file the single source of truth rather than tracking a
# per-script subset.

fetch_url() {
    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o "$output" "$url"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
        return $?
    fi

    echo "ERROR: curl or wget is required." >&2
    echo "Hint: opkg update && opkg install curl" >&2
    return 127
}

sha256_file() {
    file="$1"
    [ -s "$file" ] || { echo ""; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    else
        echo ""
    fi
}

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
}
