// ex6150v2 patch: ARM assembly Poly1305 block loop (see poly26_arm.s).

//go:build gc && !purego

package poly1305

//go:noescape
func poly26BlocksARM(h *[5]uint32, r *[9]uint32, msg *byte, blocks int)

func poly26Blocks(h *[5]uint32, r *[9]uint32, msg []byte) {
	if len(msg) >= TagSize {
		poly26BlocksARM(h, r, &msg[0], len(msg)/TagSize)
	}
}
