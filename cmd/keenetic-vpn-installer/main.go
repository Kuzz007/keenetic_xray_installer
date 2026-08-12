package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/Kuzz007/keenetic_xray_installer/internal/routerbundle"
)

var installerVersion = "dev"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	command := "info"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		command = args[0]
		args = args[1:]
	}
	if command == "help" || command == "-h" || command == "--help" {
		usage()
		return nil
	}

	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	bundlePath := flags.String("bundle", "", "bundle executable path (defaults to this executable)")
	root := flags.String("root", "/", "installation root")
	yes := flags.Bool("yes", false, "confirm installation")
	allowArchMismatch := flags.Bool("allow-arch-mismatch", false, "allow installing a bundle built for another architecture")
	jsonOutput := flags.Bool("json", false, "print machine-readable JSON")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			usage()
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected argument %q", flags.Arg(0))
	}

	if *bundlePath == "" {
		self, err := os.Executable()
		if err != nil {
			return fmt.Errorf("resolve installer path: %w", err)
		}
		*bundlePath = self
	}
	bundle, err := routerbundle.Open(*bundlePath)
	if err != nil {
		return err
	}

	switch command {
	case "info":
		if *jsonOutput {
			return json.NewEncoder(os.Stdout).Encode(bundle.Manifest)
		}
		printInfo(bundle)
		fmt.Println("Run with 'verify', 'plan' or 'install --yes'.")
		return nil
	case "verify":
		if err := bundle.Verify(); err != nil {
			return err
		}
		fmt.Printf("OK: %s %s for linux/%s is intact\n", bundle.Manifest.Edition, bundle.Manifest.Version, bundle.Manifest.Arch)
		return nil
	case "list", "plan":
		if command == "plan" && !*allowArchMismatch {
			if err := checkRuntime(bundle.Manifest); err != nil {
				return err
			}
		}
		printPlan(bundle)
		return nil
	case "install":
		if !*yes {
			return fmt.Errorf("installation requires --yes; run '%s plan' first", os.Args[0])
		}
		if !*allowArchMismatch {
			if err := checkRuntime(bundle.Manifest); err != nil {
				return err
			}
		}
		result, err := bundle.Install(*root)
		if err != nil {
			return err
		}
		fmt.Printf("Installed %s %s (%s): %d file(s) updated", bundle.Manifest.Edition, bundle.Manifest.Version, bundle.Manifest.Channel, len(result.Installed))
		if len(result.Preserved) > 0 {
			fmt.Printf(", %d existing file(s) preserved", len(result.Preserved))
		}
		if len(result.Unchanged) > 0 {
			fmt.Printf(", %d file(s) already current", len(result.Unchanged))
		}
		fmt.Println()
		fmt.Println("VPN sources and /opt/etc/xray configuration were not changed.")
		return nil
	case "version":
		fmt.Printf("keenetic-vpn-installer %s\n", installerVersion)
		return nil
	default:
		usage()
		return fmt.Errorf("unknown command %q", command)
	}
}

func printInfo(bundle *routerbundle.Bundle) {
	manifest := bundle.Manifest
	fmt.Println("Keenetic VPN router bundle")
	fmt.Printf("Edition: %s\n", strings.ToUpper(manifest.Edition))
	fmt.Printf("Version: %s\n", manifest.Version)
	fmt.Printf("Channel: %s\n", manifest.Channel)
	fmt.Printf("Platform: %s/%s\n", manifest.OS, manifest.Arch)
	fmt.Printf("Published: %s\n", manifest.PublishedAt)
	fmt.Printf("Files: %d\n", len(manifest.Files))
}

func printPlan(bundle *routerbundle.Bundle) {
	printInfo(bundle)
	fmt.Println("Plan:")
	for _, file := range bundle.Manifest.Files {
		fmt.Printf("  %-8s %04o %8d  %s  (%s)\n", file.Policy, file.Mode, file.Size, file.TargetPath, file.Role)
	}
	fmt.Println("No VPN configuration, source URL, token or router policy is part of this bundle.")
}

func checkRuntime(manifest routerbundle.Manifest) error {
	if runtime.GOOS != manifest.OS {
		return fmt.Errorf("bundle is for %s/%s, current system is %s/%s", manifest.OS, manifest.Arch, runtime.GOOS, runtime.GOARCH)
	}
	if runtime.GOARCH != manifest.Arch {
		return fmt.Errorf("bundle is for %s/%s, current system is %s/%s", manifest.OS, manifest.Arch, runtime.GOOS, runtime.GOARCH)
	}
	return nil
}

func usage() {
	fmt.Println(`keenetic-vpn-installer - verified FULL/MINIMAL router bundle

Usage:
  keenetic-vpn-installer info [--json]
  keenetic-vpn-installer verify
  keenetic-vpn-installer list
  keenetic-vpn-installer plan
  keenetic-vpn-installer install --yes
  keenetic-vpn-installer version

The installer updates project-managed binaries and small helper scripts only.
Existing VPN sources, agent credentials and Xray configuration are preserved.`)
}
