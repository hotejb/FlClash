//go:build android && cgo

package main

//#include "bride.h"
import "C"
import "unsafe"

func protect(callback unsafe.Pointer, fd int) bool {
	return C.protect(callback, C.int(fd)) != 0
}

func resolveUid(callback unsafe.Pointer, protocol int, source, target string) int {
	s := C.CString(source)
	defer C.free(unsafe.Pointer(s))
	t := C.CString(target)
	defer C.free(unsafe.Pointer(t))
	return int(C.resolve_uid(callback, C.int(protocol), s, t))
}

func resolvePackage(callback unsafe.Pointer, uid int) string {
	return takeCString(C.resolve_package(callback, C.int(uid)))
}
