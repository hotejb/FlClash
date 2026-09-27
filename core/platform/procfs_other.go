//go:build !linux

package platform

import "net"

// QuerySocketUidFromProcFs is only meaningful where /proc/net is available.
func QuerySocketUidFromProcFs(_, _ net.Addr) int {
	return -1
}
