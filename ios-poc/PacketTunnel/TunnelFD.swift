import Darwin
import NetworkExtension

enum TunnelFD {
    /// Finds the utun file descriptor backing this NEPacketTunnelProvider.
    ///
    /// iOS does not expose it, so scan the process's fds for a kernel-control
    /// socket that answers getsockopt(SYSPROTO_CONTROL, UTUN_OPT_IFNAME) with a
    /// "utunN" name (the approach used by sing-box's Apple client; mihomo's own
    /// listener/sing_tun/tun_name_darwin.go uses the same call). Falls back to
    /// the private `packetFlow.socket.fileDescriptor` KVC path, which only
    /// works on older iOS versions.
    static func find(packetFlow: NEPacketTunnelFlow) -> Int32? {
        let sysprotoControl: Int32 = 2 // SYSPROTO_CONTROL
        let utunOptIfname: Int32 = 2 // UTUN_OPT_IFNAME
        var name = [CChar](repeating: 0, count: 16) // IFNAMSIZ
        for fd: Int32 in 0...1024 {
            var length = socklen_t(name.count)
            if getsockopt(fd, sysprotoControl, utunOptIfname, &name, &length) == 0,
               String(cString: name).hasPrefix("utun")
            {
                return fd
            }
        }
        // Check selectors first: KVC on a missing key raises an ObjC exception.
        if packetFlow.responds(to: NSSelectorFromString("socket")),
           let socket = packetFlow.value(forKey: "socket") as? NSObject,
           socket.responds(to: NSSelectorFromString("fileDescriptor")),
           let fd = socket.value(forKey: "fileDescriptor") as? Int32, fd > 0
        {
            return fd
        }
        return nil
    }

    static func interfaceName(fd: Int32) -> String? {
        var name = [CChar](repeating: 0, count: 16)
        var length = socklen_t(name.count)
        guard getsockopt(fd, 2, 2, &name, &length) == 0 else { return nil }
        return String(cString: name)
    }
}
