package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
)

func ensurePrivateDir(path string) error {
	if err := os.MkdirAll(path, 0700); err != nil {
		return fmt.Errorf("create AWG state directory: %w", err)
	}
	if err := os.Chmod(path, 0700); err != nil {
		return fmt.Errorf("protect AWG state directory: %w", err)
	}
	return nil
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) (resultErr error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer func() {
		_ = temporary.Close()
		if resultErr != nil {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(mode); err != nil {
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	return os.Chmod(path, mode)
}

func loadState(opts options) (runtimeState, error) {
	data, err := os.ReadFile(statePath(opts))
	if err != nil {
		return runtimeState{}, err
	}
	var state runtimeState
	if err := json.Unmarshal(data, &state); err != nil {
		return runtimeState{}, errors.New("AWG runtime state is invalid")
	}
	if state.Schema != stateSchema || state.Runtime == "" || state.Tools == "" || state.Interface == "" {
		return runtimeState{}, errors.New("AWG runtime state has an unsupported format")
	}
	if normalizedProfileSlot(state.ProfileSlot) == "" {
		return runtimeState{}, errors.New("AWG runtime state has an invalid profile slot")
	}
	networkValues := 0
	for _, value := range []uint32{state.RouteTable, state.RouteMark, state.RulePref} {
		if value != 0 {
			networkValues++
		}
	}
	if networkValues != 0 && networkValues != 3 {
		return runtimeState{}, errors.New("AWG runtime state has an incomplete network plan")
	}
	if networkValues == 3 {
		if len(state.RoutePrefixes) == 0 {
			return runtimeState{}, errors.New("AWG runtime state has an incomplete network plan")
		}
		for _, prefix := range state.RoutePrefixes {
			if _, err := netip.ParsePrefix(prefix); err != nil {
				return runtimeState{}, errors.New("AWG runtime state has an invalid route prefix")
			}
		}
	}
	return state, nil
}

func saveState(opts options, state runtimeState) error {
	state.Schema = stateSchema
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return errors.New("encode AWG runtime state failed")
	}
	return writeFileAtomic(statePath(opts), append(data, '\n'), 0600)
}
