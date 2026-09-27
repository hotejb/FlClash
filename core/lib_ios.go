//go:build ios && cgo

package main

import (
	"github.com/metacubex/mihomo/log"
	"os"
	"runtime/debug"
)

// iOS kills a NEPacketTunnelProvider that exceeds its memory limit (~50MB
// phys_footprint), so keep the Go heap well below that by default. The limit
// can be overridden with the standard GOMEMLIMIT environment variable.
const defaultIOSMemoryLimit = 35 << 20

func init() {
	if _, ok := os.LookupEnv("GOMEMLIMIT"); ok {
		return
	}
	debug.SetMemoryLimit(defaultIOSMemoryLimit)
}

// mihomo only lets the host override the system resolver on Android
// (dns.UpdateSystemDNS is android-only), so on iOS the config's own
// nameservers are used and this is a no-op.
func handleUpdateDns(value string) {
	log.Warnln("[DNS] updateDns is not supported on iOS, ignoring %s", value)
}
