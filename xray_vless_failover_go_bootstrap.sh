#!/bin/sh
set -e

REPO_URL="${REPO_URL:-https://github.com/Kuzz007/keenetic_xray_installer.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/opt/root/keenetic_xray_installer}"
INSTALLER_SCRIPT="xray_vless_failover_go.sh"

ensure_entware() {
    if ! command -v opkg >/dev/null 2>&1; then
        echo "ERROR: opkg not found. Entware is required." >&2
        exit 1
    fi
}

ensure_packages() {
    echo "[1/4] Checking required packages..."
    opkg update

    if ! command -v git >/dev/null 2>&1; then
        opkg install git git-http ca-bundle || opkg install git ca-bundle
    else
        opkg install ca-bundle >/dev/null 2>&1 || true
    fi

    if ! command -v curl >/dev/null 2>&1; then
        opkg install curl ca-bundle
    fi
}

clone_or_update_repo() {
    echo "[2/4] Preparing local repository..."
    mkdir -p "$(dirname "$REPO_DIR")"

    if [ -d "$REPO_DIR/.git" ]; then
        echo "Updating existing clone: $REPO_DIR"
        cd "$REPO_DIR"
        git fetch origin "$REPO_BRANCH"
        git checkout "$REPO_BRANCH"
        git reset --hard "origin/$REPO_BRANCH"
        git clean -fd
    else
        if [ -e "$REPO_DIR" ]; then
            echo "ERROR: $REPO_DIR exists but is not a git repository." >&2
            echo "Move it away or set REPO_DIR=/another/path." >&2
            exit 1
        fi
        echo "Cloning $REPO_URL#$REPO_BRANCH into $REPO_DIR"
        git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
    fi
}

run_installer() {
    echo "[3/4] Running local experimental Go installer..."
    cd "$REPO_DIR"

    if [ ! -f "$INSTALLER_SCRIPT" ]; then
        echo "ERROR: installer not found: $REPO_DIR/$INSTALLER_SCRIPT" >&2
        exit 1
    fi

    chmod +x "$INSTALLER_SCRIPT"
    sh "$INSTALLER_SCRIPT"
}

print_summary() {
    echo "[4/4] Done."
    echo "Local repository: $REPO_DIR"
    echo "Branch: $REPO_BRANCH"
    echo "Installer: $REPO_DIR/$INSTALLER_SCRIPT"
    echo ""
    echo "Update repo and rerun installer later:"
    echo "  xray-go-repo-update"
}

create_update_command() {
    cat > /opt/bin/xray-go-repo-update <<UPDATE
#!/bin/sh
set -e
REPO_URL="${REPO_URL}"
REPO_BRANCH="${REPO_BRANCH}"
REPO_DIR="${REPO_DIR}"
INSTALLER_SCRIPT="${INSTALLER_SCRIPT}"

if ! command -v git >/dev/null 2>&1; then
    opkg update
    opkg install git git-http ca-bundle || opkg install git ca-bundle
fi

if [ ! -d "\$REPO_DIR/.git" ]; then
    mkdir -p "\$(dirname "\$REPO_DIR")"
    git clone --depth 1 --branch "\$REPO_BRANCH" "\$REPO_URL" "\$REPO_DIR"
else
    cd "\$REPO_DIR"
    git fetch origin "\$REPO_BRANCH"
    git checkout "\$REPO_BRANCH"
    git reset --hard "origin/\$REPO_BRANCH"
    git clean -fd
fi

cd "\$REPO_DIR"
chmod +x "\$INSTALLER_SCRIPT"
sh "\$INSTALLER_SCRIPT"
UPDATE
    chmod +x /opt/bin/xray-go-repo-update
}

main() {
    ensure_entware
    ensure_packages
    clone_or_update_repo
    create_update_command
    run_installer
    print_summary
}

main "$@"
