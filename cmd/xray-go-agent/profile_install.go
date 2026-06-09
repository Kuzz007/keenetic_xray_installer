package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const installShURL = "https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh"
const installShPath = "/opt/tmp/xray-go-install-main.sh"

func installGoProfile(profile string) (bool, string) {
	profile = strings.TrimSpace(profile)
	switch profile {
	case "minimal_go", "minimal-go", "minimal":
		return installMinimalGoProfile()
	case "full_go", "full-go", "full", "full_lite", "full-lite":
		return installFullGoProfile()
	default:
		return false, "неизвестный профиль установки: " + profile
	}
}

func installMinimalGoProfile() (bool, string) {
	cmd := strings.Join([]string{
		"set -e",
		"mkdir -p /opt/tmp",
		fetchInstallShShell(),
		"REPO_BRANCH=main sh " + installShPath + " --direct-experimental --install-binary",
		"REPO_BRANCH=main sh -c 'CB=\"$(date +%s)\"; curl -fL -H \"Cache-Control: no-cache\" -H \"Pragma: no-cache\" \"https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-direct-helper-profile.sh?cb=${CB}\" -o /opt/tmp/xray-go-direct-helper-profile.sh && sh -n /opt/tmp/xray-go-direct-helper-profile.sh && sh /opt/tmp/xray-go-direct-helper-profile.sh --profile minimal --apply --yes'",
		"REPO_BRANCH=main sh -c 'CB=\"$(date +%s)\"; curl -fL -H \"Cache-Control: no-cache\" -H \"Pragma: no-cache\" \"https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-xray-initial-install.sh?cb=${CB}\" -o /opt/tmp/xray-go-xray-initial-install.sh && sh -n /opt/tmp/xray-go-xray-initial-install.sh && sh /opt/tmp/xray-go-xray-initial-install.sh --apply --yes'",
		"rm -f /opt/bin/vless-go-xray-core-update /opt/bin/vless-go-socks-auth /opt/etc/xray/vless-go-socks-auth.conf",
		"[ -x /opt/bin/xray-go-size-check ] && /opt/bin/xray-go-size-check || true",
	}, "\n")
	ok, out := runShellProfileInstall(cmd, 15*time.Minute)
	return ok, profileInstallSummary("minimal_go", ok, out)
}

func installFullGoProfile() (bool, string) {
	cmd := strings.Join([]string{
		"set -e",
		"mkdir -p /opt/tmp",
		fetchInstallShShell(),
		"REPO_BRANCH=main sh " + installShPath + " --direct-one-command --yes --skip-setup",
		"rm -f /opt/bin/vless-go-xray-core-update /opt/bin/vless-go-socks-auth /opt/etc/xray/vless-go-socks-auth.conf",
		"[ -x /opt/bin/vless-go-failover ] && /opt/bin/vless-go-failover update-active --no-restart || true",
		"[ -x /opt/etc/init.d/S24xray ] && /opt/etc/init.d/S24xray restart || true",
		"[ -x /opt/etc/init.d/S26vless-go-watchdog ] && /opt/etc/init.d/S26vless-go-watchdog restart || true",
		"[ -x /opt/bin/xray-go-size-check ] && /opt/bin/xray-go-size-check || true",
	}, "\n")
	ok, out := runShellProfileInstall(cmd, 20*time.Minute)
	return ok, profileInstallSummary("full_go", ok, out)
}

func fetchInstallShShell() string {
	return "CB=\"$(date +%s)\"; curl -fL -H \"Cache-Control: no-cache\" -H \"Pragma: no-cache\" \"" + installShURL + "?cb=${CB}\" -o " + installShPath + " && sh -n " + installShPath
}

func runShellProfileInstall(script string, timeout time.Duration) (bool, string) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		return false, "не найден /bin/sh"
	}
	return runWithStdin([]string{"/bin/sh", "-s"}, script, timeout)
}

func profileInstallSummary(profile string, ok bool, out string) (bool, string) {
	status := "OK"
	if !ok {
		status = "FAIL"
	}
	parts := []string{
		"== Установка профиля " + profile + " ==",
		"статус: " + status,
		"политика: SOCKS без авторизации по умолчанию; xray-core update helper не ставится",
	}
	if exists("/opt/bin/xray-failover-go") {
		parts = append(parts, "Go resolver: OK")
	}
	if exists("/opt/sbin/xray") || exists("/opt/bin/xray") {
		parts = append(parts, "Xray: OK")
	}
	if exists("/opt/etc/xray/config.json") {
		parts = append(parts, "config.json: OK")
	}
	if exists("/opt/bin/vless-go-xray-core-update") {
		parts = append(parts, "manual-only updater: FAIL, найден /opt/bin/vless-go-xray-core-update")
	} else {
		parts = append(parts, "manual-only updater: отсутствует")
	}
	if exists("/opt/etc/xray/vless-go-socks-auth.conf") || exists("/opt/bin/vless-go-socks-auth") {
		parts = append(parts, "SOCKS auth: FAIL, найден старый auth")
	} else {
		parts = append(parts, "SOCKS auth: отключён/отсутствует")
	}
	trimmed := strings.TrimSpace(out)
	if trimmed != "" {
		if len(trimmed) > 3500 {
			trimmed = trimmed[len(trimmed)-3500:]
			trimmed = "...\n" + trimmed
		}
		parts = append(parts, "\n== Последний вывод ==\n"+trimmed)
	}
	return ok, strings.Join(parts, "\n")
}

func profileInstallCommandHelp() string {
	return fmt.Sprintf("Профили установки: minimal_go и full_go. Источник install.sh: %s", installShURL)
}
