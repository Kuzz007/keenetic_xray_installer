//go:build !linux

package main

func acquireLock(_ options) (func(), error) { return func() {}, nil }
