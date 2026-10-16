// ex6150v2 patch: portable Poly1305 block loop for every other platform.

//go:build !arm || !gc || purego

package poly1305

func poly26Blocks(h *[5]uint32, r *[9]uint32, msg []byte) { poly26BlocksGo(h, r, msg) }
