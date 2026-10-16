package main

import (
	"bytes"
	"fmt"
	"math/rand"
	"os"

	chachaarm "github.com/sagernet/sing-box/cmd/cryptobench/chacha20arm"
	"golang.org/x/crypto/chacha20"
)

// verifyChacha compares the ARM assembly ChaCha20 with upstream x/crypto: random keys,
// nonces, start counters, lengths, unaligned offsets, in-place use and split calls.
func verifyChacha() {
	rng := rand.New(rand.NewSource(2))
	key := make([]byte, 32)
	nonce := make([]byte, 12)
	src := make([]byte, 4096+8)
	want := make([]byte, len(src))
	got := make([]byte, len(src)+8)
	checks := 0
	for iter := 0; iter < 20000; iter++ {
		rng.Read(key)
		rng.Read(nonce)
		rng.Read(src)
		counter := rng.Uint32() % 1000000
		if iter%50 == 0 {
			counter = 0xffffffff - uint32(rng.Intn(70)) // near the 32-bit limit
		}
		n := rng.Intn(4096)
		if iter%5 == 0 {
			n = 64 * rng.Intn(64)
		}
		maxBlocks := (uint64(n) + 63) / 64
		if uint64(counter)+maxBlocks > 1<<32 {
			n = int((1<<32 - uint64(counter)) * 64)
		}
		soff, doff := rng.Intn(8), rng.Intn(8)

		ref, _ := chacha20.NewUnauthenticatedCipher(key, nonce)
		ref.SetCounter(counter)
		ref.XORKeyStream(want[:n], src[soff:soff+n])

		c, _ := chachaarm.NewUnauthenticatedCipher(key, nonce)
		c.SetCounter(counter)
		if iter%3 == 0 { // in place, unaligned
			copy(got[doff:], src[soff:soff+n])
			c.XORKeyStream(got[doff:doff+n], got[doff:doff+n])
		} else { // split into random pieces, separate buffers
			rest, out := src[soff:soff+n], got[doff:doff+n]
			for len(rest) > 0 {
				k := 1 + rng.Intn(700)
				if k > len(rest) {
					k = len(rest)
				}
				c.XORKeyStream(out[:k], rest[:k])
				rest, out = rest[k:], out[k:]
			}
		}
		if !bytes.Equal(got[doff:doff+n], want[:n]) {
			fmt.Printf("MISMATCH iter=%d n=%d counter=%d soff=%d doff=%d\n", iter, n, counter, soff, doff)
			os.Exit(1)
		}
		checks++
	}
	fmt.Printf("chacha20 ARM verify: %d comparisons, all identical to upstream\n", checks)
}
