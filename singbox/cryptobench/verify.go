package main

import (
	"bytes"
	"fmt"
	"math/rand"
	"os"

	poly26 "github.com/sagernet/sing-box/cmd/cryptobench/poly26"
	"golang.org/x/crypto/poly1305"
)

// verifyPoly26 compares the patched Poly1305 against upstream x/crypto on random and
// worst-case inputs, both one-shot and streamed in random chunk sizes.
func verifyPoly26() {
	rng := rand.New(rand.NewSource(1))
	var key [32]byte
	msg := make([]byte, 5000)
	checks := 0
	fail := func(what string, n int) {
		fmt.Printf("MISMATCH (%s) len=%d key=%x\n", what, n, key)
		os.Exit(1)
	}
	for iter := 0; iter < 60000; iter++ {
		switch iter % 4 {
		case 0: // all bits set: largest limb values
			for i := range key {
				key[i] = 0xff
			}
			for i := range msg {
				msg[i] = 0xff
			}
		case 1:
			rng.Read(key[:])
			for i := range msg {
				msg[i] = 0xff
			}
		default:
			rng.Read(key[:])
			rng.Read(msg)
		}
		n := iter % len(msg)
		if iter%3 == 0 {
			n = rng.Intn(len(msg))
		}
		var want, got [16]byte
		poly1305.Sum(&want, msg[:n], &key)
		poly26.Sum(&got, msg[:n], &key)
		if want != got {
			fail("one-shot", n)
		}
		// streamed writes, as chacha20poly1305 does (aad, ciphertext, lengths)
		h := poly26.New(&key)
		rest := msg[:n]
		for len(rest) > 0 {
			k := 1 + rng.Intn(300)
			if rng.Intn(4) == 0 {
				k = 16 * (1 + rng.Intn(64))
			}
			if k > len(rest) {
				k = len(rest)
			}
			h.Write(rest[:k])
			rest = rest[k:]
		}
		if !bytes.Equal(h.Sum(nil), want[:]) {
			fail("streamed", n)
		}
		checks += 2
	}
	fmt.Printf("poly26 verify: %d comparisons, all identical to upstream\n", checks)
}
