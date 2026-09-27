//go:build android && cgo

package main

import (
	"strings"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
)

var (
	dnsUpdateMu  sync.Mutex
	dnsUpdateSeq atomic.Uint64
)

func handleUpdateDns(value string) {
	seq := dnsUpdateSeq.Add(1)
	safeGoDetached("updateDns", func() {
		dnsUpdateMu.Lock()
		defer dnsUpdateMu.Unlock()
		if seq != dnsUpdateSeq.Load() {
			return
		}
		log.Infoln("[DNS] updateDns %s", value)
		dns.UpdateSystemDNS(strings.Split(value, ","))
		dns.FlushCacheWithDefaultResolver()
	})
}
