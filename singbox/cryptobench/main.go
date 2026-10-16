// cryptobench: single-core throughput of the AEAD / primitive code paths Go's TLS uses.
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"fmt"
	"os"
	"strconv"
	"time"

	chachaarm "github.com/sagernet/sing-box/cmd/cryptobench/chacha20arm"
	poly26 "github.com/sagernet/sing-box/cmd/cryptobench/poly26"
	"golang.org/x/crypto/chacha20"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/poly1305"
)

const record = 16384

func bench(name string, d time.Duration, f func()) {
	n := 0
	start := time.Now()
	for time.Since(start) < d {
		for i := 0; i < 16; i++ {
			f()
		}
		n += 16
	}
	el := time.Since(start).Seconds()
	mbs := float64(n*record) / el / 1e6
	fmt.Printf("%-34s %7.1f MB/s  (%6.1f Mbit/s per core)\n", name, mbs, mbs*8)
}

func main() {
	d := 2 * time.Second
	if len(os.Args) > 1 && os.Args[1] == "verify" {
		verifyPoly26()
		verifyChacha()
		return
	}
	if len(os.Args) > 1 {
		if s, err := strconv.Atoi(os.Args[1]); err == nil {
			d = time.Duration(s) * time.Second
		}
	}
	key := make([]byte, 32)
	nonce := make([]byte, 12)
	buf := make([]byte, record+16)
	plain := buf[:record]

	cc, _ := chacha20poly1305.New(key)
	sealed := cc.Seal(nil, nonce, plain, nil)
	out := make([]byte, 0, record+16)
	bench("chacha20poly1305 Seal (encrypt)", d, func() { cc.Seal(out[:0], nonce, plain, nil) })
	bench("chacha20poly1305 Open (decrypt)", d, func() { cc.Open(out[:0], nonce, sealed, nil) })

	bench("chacha20 keystream only", d, func() {
		s, _ := chacha20.NewUnauthenticatedCipher(key, nonce)
		s.XORKeyStream(plain, plain)
	})
	bench("chacha20 keystream (ARM asm patch)", d, func() {
		s, _ := chachaarm.NewUnauthenticatedCipher(key, nonce)
		s.XORKeyStream(plain, plain)
	})
	var pk [32]byte
	bench("poly1305 MAC only", d, func() { poly1305.Sum(&[16]byte{}, plain, &pk) })
	bench("poly1305 MAC only (26-bit patch)", d, func() { poly26.Sum(&[16]byte{}, plain, &pk) })

	block, _ := aes.NewCipher(key[:16])
	gcm, _ := cipher.NewGCM(block)
	gsealed := gcm.Seal(nil, nonce, plain, nil)
	bench("aes-128-gcm Open (decrypt)", d, func() { gcm.Open(out[:0], nonce, gsealed, nil) })

	bench("memcpy 16 KiB", d, func() { copy(buf[16:], plain[:record-16]) })
}
