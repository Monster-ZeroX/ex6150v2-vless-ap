// ex6150v2 patch: scalar ARM assembly ChaCha20 core (see chacha_arm.s).

//go:build gc && !purego

package chacha20

const bufSize = blockSize

//go:noescape
func xorKeyStreamARM(dst, src *byte, blocks int, state *[16]uint32)

func (s *Cipher) xorKeyStreamBlocks(dst, src []byte) {
	blocks := len(src) / blockSize
	if blocks == 0 {
		return
	}
	_ = dst[len(src)-1]
	state := [16]uint32{
		j0, j1, j2, j3,
		s.key[0], s.key[1], s.key[2], s.key[3],
		s.key[4], s.key[5], s.key[6], s.key[7],
		s.counter, s.nonce[0], s.nonce[1], s.nonce[2],
	}
	xorKeyStreamARM(&dst[0], &src[0], blocks, &state)
	s.counter = state[12]
}
