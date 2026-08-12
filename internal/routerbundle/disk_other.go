//go:build !linux

package routerbundle

func availableInstallBytes(string) (uint64, bool, error) {
	return 0, false, nil
}
