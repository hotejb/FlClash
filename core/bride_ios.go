//go:build ios && cgo

package main

import "unsafe"

// On iOS the NEPacketTunnelProvider's own sockets are never routed back into
// the tunnel, so there is nothing to protect.
func protect(_ unsafe.Pointer, _ int) bool {
	return true
}

// iOS does not expose the owning process of a connection to a packet tunnel
// provider, so process-based rules see no owner.
func resolveUid(_ unsafe.Pointer, _ int, _, _ string) int {
	return -1
}

func resolvePackage(_ unsafe.Pointer, _ int) string {
	return ""
}
