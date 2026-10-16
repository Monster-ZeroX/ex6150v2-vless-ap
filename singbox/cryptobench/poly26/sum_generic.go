// Copyright 2018 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// This file provides the generic implementation of Sum and MAC. Other files
// might provide optimized assembly implementations of some of this code.

package poly1305

import (
	"encoding/binary"
	"math/bits"
)

// Poly1305 [RFC 7539] is a relatively simple algorithm: the authentication tag
// for a 64 bytes message is approximately
//
//     s + m[0:16] * r⁴ + m[16:32] * r³ + m[32:48] * r² + m[48:64] * r  mod  2¹³⁰ - 5
//
// for some secret r and s. It can be computed sequentially like
//
//     for len(msg) > 0:
//         h += read(msg, 16)
//         h *= r
//         h %= 2¹³⁰ - 5
//     return h + s
//
// All the complexity is about doing performant constant-time math on numbers
// larger than any available numeric type.

func sumGeneric(out *[TagSize]byte, msg []byte, key *[32]byte) {
	h := newMACGeneric(key)
	h.Write(msg)
	h.Sum(out)
}

func newMACGeneric(key *[32]byte) macGeneric {
	m := macGeneric{}
	initialize(key, &m.macState)
	return m
}

// macState holds numbers in saturated 64-bit little-endian limbs. That is,
// the value of [x0, x1, x2] is x[0] + x[1] * 2⁶⁴ + x[2] * 2¹²⁸.
type macState struct {
	// h is the main accumulator. It is to be interpreted modulo 2¹³⁰ - 5, but
	// can grow larger during and after rounds. It must, however, remain below
	// 2 * (2¹³⁰ - 5).
	h [3]uint64
	// r and s are the private key components.
	r [2]uint64
	s [2]uint64
}

type macGeneric struct {
	macState

	buffer [TagSize]byte
	offset int
}

// Write splits the incoming message into TagSize chunks, and passes them to
// update. It buffers incomplete chunks.
func (h *macGeneric) Write(p []byte) (int, error) {
	nn := len(p)
	if h.offset > 0 {
		n := copy(h.buffer[h.offset:], p)
		if h.offset+n < TagSize {
			h.offset += n
			return nn, nil
		}
		p = p[n:]
		h.offset = 0
		updateGeneric(&h.macState, h.buffer[:])
	}
	if n := len(p) - (len(p) % TagSize); n > 0 {
		updateGeneric(&h.macState, p[:n])
		p = p[n:]
	}
	if len(p) > 0 {
		h.offset += copy(h.buffer[h.offset:], p)
	}
	return nn, nil
}

// Sum flushes the last incomplete chunk from the buffer, if any, and generates
// the MAC output. It does not modify its state, in order to allow for multiple
// calls to Sum, even if no Write is allowed after Sum.
func (h *macGeneric) Sum(out *[TagSize]byte) {
	state := h.macState
	if h.offset > 0 {
		updateGeneric(&state, h.buffer[:h.offset])
	}
	finalize(out, &state.h, &state.s)
}

// [rMask0, rMask1] is the specified Poly1305 clamping mask in little-endian. It
// clears some bits of the secret coefficient to make it possible to implement
// multiplication more efficiently.
const (
	rMask0 = 0x0FFFFFFC0FFFFFFF
	rMask1 = 0x0FFFFFFC0FFFFFFC
)

// initialize loads the 256-bit key into the two 128-bit secret values r and s.
func initialize(key *[32]byte, m *macState) {
	m.r[0] = binary.LittleEndian.Uint64(key[0:8]) & rMask0
	m.r[1] = binary.LittleEndian.Uint64(key[8:16]) & rMask1
	m.s[0] = binary.LittleEndian.Uint64(key[16:24])
	m.s[1] = binary.LittleEndian.Uint64(key[24:32])
}

// uint128 holds a 128-bit number as two 64-bit limbs, for use with the
// bits.Mul64 and bits.Add64 intrinsics.
type uint128 struct {
	lo, hi uint64
}

func mul64(a, b uint64) uint128 {
	hi, lo := bits.Mul64(a, b)
	return uint128{lo, hi}
}

func add128(a, b uint128) uint128 {
	lo, c := bits.Add64(a.lo, b.lo, 0)
	hi, c := bits.Add64(a.hi, b.hi, c)
	if c != 0 {
		panic("poly1305: unexpected overflow")
	}
	return uint128{lo, hi}
}

func shiftRightBy2(a uint128) uint128 {
	a.lo = a.lo>>2 | (a.hi&3)<<62
	a.hi = a.hi >> 2
	return a
}

// updateGeneric64 absorbs msg into the state.h accumulator. For each chunk m of
// 128 bits of message, it computes
//
//	h₊ = (h + m) * r  mod  2¹³⁰ - 5
//
// If the msg length is not a multiple of TagSize, it assumes the last
// incomplete chunk is the final one.
func updateGeneric64(state *macState, msg []byte) {
	h0, h1, h2 := state.h[0], state.h[1], state.h[2]
	r0, r1 := state.r[0], state.r[1]

	for len(msg) > 0 {
		var c uint64

		// For the first step, h + m, we use a chain of bits.Add64 intrinsics.
		// The resulting value of h might exceed 2¹³⁰ - 5, but will be partially
		// reduced at the end of the multiplication below.
		//
		// The spec requires us to set a bit just above the message size, not to
		// hide leading zeroes. For full chunks, that's 1 << 128, so we can just
		// add 1 to the most significant (2¹²⁸) limb, h2.
		if len(msg) >= TagSize {
			h0, c = bits.Add64(h0, binary.LittleEndian.Uint64(msg[0:8]), 0)
			h1, c = bits.Add64(h1, binary.LittleEndian.Uint64(msg[8:16]), c)
			h2 += c + 1

			msg = msg[TagSize:]
		} else {
			var buf [TagSize]byte
			copy(buf[:], msg)
			buf[len(msg)] = 1

			h0, c = bits.Add64(h0, binary.LittleEndian.Uint64(buf[0:8]), 0)
			h1, c = bits.Add64(h1, binary.LittleEndian.Uint64(buf[8:16]), c)
			h2 += c

			msg = nil
		}

		// Multiplication of big number limbs is similar to elementary school
		// columnar multiplication. Instead of digits, there are 64-bit limbs.
		//
		// We are multiplying a 3 limbs number, h, by a 2 limbs number, r.
		//
		//                        h2    h1    h0  x
		//                              r1    r0  =
		//                       ----------------
		//                      h2r0  h1r0  h0r0     <-- individual 128-bit products
		//            +   h2r1  h1r1  h0r1
		//               ------------------------
		//                 m3    m2    m1    m0      <-- result in 128-bit overlapping limbs
		//               ------------------------
		//         m3.hi m2.hi m1.hi m0.hi           <-- carry propagation
		//     +         m3.lo m2.lo m1.lo m0.lo
		//        -------------------------------
		//           t4    t3    t2    t1    t0      <-- final result in 64-bit limbs
		//
		// The main difference from pen-and-paper multiplication is that we do
		// carry propagation in a separate step, as if we wrote two digit sums
		// at first (the 128-bit limbs), and then carried the tens all at once.

		h0r0 := mul64(h0, r0)
		h1r0 := mul64(h1, r0)
		h2r0 := mul64(h2, r0)
		h0r1 := mul64(h0, r1)
		h1r1 := mul64(h1, r1)
		h2r1 := mul64(h2, r1)

		// Since h2 is known to be at most 7 (5 + 1 + 1), and r0 and r1 have their
		// top 4 bits cleared by rMask{0,1}, we know that their product is not going
		// to overflow 64 bits, so we can ignore the high part of the products.
		//
		// This also means that the product doesn't have a fifth limb (t4).
		if h2r0.hi != 0 {
			panic("poly1305: unexpected overflow")
		}
		if h2r1.hi != 0 {
			panic("poly1305: unexpected overflow")
		}

		m0 := h0r0
		m1 := add128(h1r0, h0r1) // These two additions don't overflow thanks again
		m2 := add128(h2r0, h1r1) // to the 4 masked bits at the top of r0 and r1.
		m3 := h2r1

		t0 := m0.lo
		t1, c := bits.Add64(m1.lo, m0.hi, 0)
		t2, c := bits.Add64(m2.lo, m1.hi, c)
		t3, _ := bits.Add64(m3.lo, m2.hi, c)

		// Now we have the result as 4 64-bit limbs, and we need to reduce it
		// modulo 2¹³⁰ - 5. The special shape of this Crandall prime lets us do
		// a cheap partial reduction according to the reduction identity
		//
		//     c * 2¹³⁰ + n  =  c * 5 + n  mod  2¹³⁰ - 5
		//
		// because 2¹³⁰ = 5 mod 2¹³⁰ - 5. Partial reduction since the result is
		// likely to be larger than 2¹³⁰ - 5, but still small enough to fit the
		// assumptions we make about h in the rest of the code.
		//
		// See also https://speakerdeck.com/gtank/engineering-prime-numbers?slide=23

		// We split the final result at the 2¹³⁰ mark into h and cc, the carry.
		// Note that the carry bits are effectively shifted left by 2, in other
		// words, cc = c * 4 for the c in the reduction identity.
		h0, h1, h2 = t0, t1, t2&maskLow2Bits
		cc := uint128{t2 & maskNotLow2Bits, t3}

		// To add c * 5 to h, we first add cc = c * 4, and then add (cc >> 2) = c.

		h0, c = bits.Add64(h0, cc.lo, 0)
		h1, c = bits.Add64(h1, cc.hi, c)
		h2 += c

		cc = shiftRightBy2(cc)

		h0, c = bits.Add64(h0, cc.lo, 0)
		h1, c = bits.Add64(h1, cc.hi, c)
		h2 += c

		// h2 is at most 3 + 1 + 1 = 5, making the whole of h at most
		//
		//     5 * 2¹²⁸ + (2¹²⁸ - 1) = 6 * 2¹²⁸ - 1
	}

	state.h[0], state.h[1], state.h[2] = h0, h1, h2
}

const (
	maskLow2Bits    uint64 = 0x0000000000000003
	maskNotLow2Bits uint64 = ^maskLow2Bits
)

// select64 returns x if v == 1 and y if v == 0, in constant time.
func select64(v, x, y uint64) uint64 { return ^(v-1)&x | (v-1)&y }

// [p0, p1, p2] is 2¹³⁰ - 5 in little endian order.
const (
	p0 = 0xFFFFFFFFFFFFFFFB
	p1 = 0xFFFFFFFFFFFFFFFF
	p2 = 0x0000000000000003
)

// finalize completes the modular reduction of h and computes
//
//	out = h + s  mod  2¹²⁸
func finalize(out *[TagSize]byte, h *[3]uint64, s *[2]uint64) {
	h0, h1, h2 := h[0], h[1], h[2]

	// After the partial reduction in updateGeneric, h might be more than
	// 2¹³⁰ - 5, but will be less than 2 * (2¹³⁰ - 5). To complete the reduction
	// in constant time, we compute t = h - (2¹³⁰ - 5), and select h as the
	// result if the subtraction underflows, and t otherwise.

	hMinusP0, b := bits.Sub64(h0, p0, 0)
	hMinusP1, b := bits.Sub64(h1, p1, b)
	_, b = bits.Sub64(h2, p2, b)

	// h = h if h < p else h - p
	h0 = select64(b, h0, hMinusP0)
	h1 = select64(b, h1, hMinusP1)

	// Finally, we compute the last Poly1305 step
	//
	//     tag = h + s  mod  2¹²⁸
	//
	// by just doing a wide addition with the 128 low bits of h and discarding
	// the overflow.
	h0, c := bits.Add64(h0, s[0], 0)
	h1, _ = bits.Add64(h1, s[1], c)

	binary.LittleEndian.PutUint64(out[0:8], h0)
	binary.LittleEndian.PutUint64(out[8:16], h1)
}

// ---------------------------------------------------------------------------
// ex6150v2 patch: 32-bit friendly Poly1305 block loop.
//
// updateGeneric64 (above, unchanged upstream code) relies on bits.Mul64/Add64,
// which a 32-bit CPU such as the Cortex-A7 has to emulate. update26 processes
// whole 16-byte blocks with five 26-bit limbs ("poly1305-donna-32" layout), so
// every product is a native 32x32->64 multiply (UMULL/UMLAL). The accumulator is
// converted from/to the 64-bit limb macState at the edges of each call, so key
// setup, partial final blocks and finalize stay on the upstream code.
// The block loop itself is poly26Blocks (poly26_generic.go, or poly26_arm.s).

func updateGeneric(state *macState, msg []byte) {
	if n := len(msg) &^ (TagSize - 1); n >= 4*TagSize {
		update26(state, msg[:n])
		msg = msg[n:]
	}
	if len(msg) > 0 {
		updateGeneric64(state, msg)
	}
}

const mask26 = 0x3ffffff

// update26 absorbs len(msg)/16 full blocks; len(msg) must be a multiple of 16.
func update26(state *macState, msg []byte) {
	// r: 128-bit clamped coefficient -> 26-bit limbs, followed by s_i = 5*r_i
	var r [9]uint32
	w0, w1 := uint32(state.r[0]), uint32(state.r[0]>>32)
	w2, w3 := uint32(state.r[1]), uint32(state.r[1]>>32)
	r[0] = w0 & mask26
	r[1] = (w0>>26 | w1<<6) & mask26
	r[2] = (w1>>20 | w2<<12) & mask26
	r[3] = (w2>>14 | w3<<18) & mask26
	r[4] = w3 >> 8
	r[5], r[6], r[7], r[8] = r[1]*5, r[2]*5, r[3]*5, r[4]*5

	// h: 64-bit limbs (h[2] <= 7) -> 26-bit limbs (h4 < 2^27)
	var h [5]uint32
	w0, w1 = uint32(state.h[0]), uint32(state.h[0]>>32)
	w2, w3 = uint32(state.h[1]), uint32(state.h[1]>>32)
	h[0] = w0 & mask26
	h[1] = (w0>>26 | w1<<6) & mask26
	h[2] = (w1>>20 | w2<<12) & mask26
	h[3] = (w2>>14 | w3<<18) & mask26
	h[4] = w3>>8 | uint32(state.h[2])<<24

	poly26Blocks(&h, &r, msg)

	// normalise so that h0..h3 < 2^26 and h4 <= 2^26, then repack into 64-bit limbs
	h0, h1, h2, h3, h4 := h[0], h[1], h[2], h[3], h[4]
	var c uint32
	c = h1 >> 26
	h1 &= mask26
	h2 += c
	c = h2 >> 26
	h2 &= mask26
	h3 += c
	c = h3 >> 26
	h3 &= mask26
	h4 += c
	c = h4 >> 26
	h4 &= mask26
	h0 += c * 5
	c = h0 >> 26
	h0 &= mask26
	h1 += c
	c = h1 >> 26
	h1 &= mask26
	h2 += c
	c = h2 >> 26
	h2 &= mask26
	h3 += c
	c = h3 >> 26
	h3 &= mask26
	h4 += c

	state.h[0] = uint64(h0) | uint64(h1)<<26 | uint64(h2)<<52
	state.h[1] = uint64(h2)>>12 | uint64(h3)<<14 | uint64(h4)<<40
	state.h[2] = uint64(h4) >> 24
}

// poly26BlocksGo is the portable block loop: h = (h + m) * r mod 2^130-5 per block.
// Limbs stay < 2^28 and r limbs are clamped (r4 < 2^20), so every column sum is
// < 2^57 and the carries fit in 32 bits, as in poly1305-donna-32.
func poly26BlocksGo(h *[5]uint32, r *[9]uint32, msg []byte) {
	r0, r1, r2, r3, r4 := r[0], r[1], r[2], r[3], r[4]
	s1, s2, s3, s4 := r[5], r[6], r[7], r[8]
	h0, h1, h2, h3, h4 := h[0], h[1], h[2], h[3], h[4]

	for len(msg) >= TagSize {
		m0 := binary.LittleEndian.Uint32(msg[0:4])
		m1 := binary.LittleEndian.Uint32(msg[4:8])
		m2 := binary.LittleEndian.Uint32(msg[8:12])
		m3 := binary.LittleEndian.Uint32(msg[12:16])
		msg = msg[TagSize:]

		h0 += m0 & mask26
		h1 += (m0>>26 | m1<<6) & mask26
		h2 += (m1>>20 | m2<<12) & mask26
		h3 += (m2>>14 | m3<<18) & mask26
		h4 += m3>>8 | 1<<24

		d0 := uint64(h0)*uint64(r0) + uint64(h1)*uint64(s4) + uint64(h2)*uint64(s3) + uint64(h3)*uint64(s2) + uint64(h4)*uint64(s1)
		d1 := uint64(h0)*uint64(r1) + uint64(h1)*uint64(r0) + uint64(h2)*uint64(s4) + uint64(h3)*uint64(s3) + uint64(h4)*uint64(s2)
		d2 := uint64(h0)*uint64(r2) + uint64(h1)*uint64(r1) + uint64(h2)*uint64(r0) + uint64(h3)*uint64(s4) + uint64(h4)*uint64(s3)
		d3 := uint64(h0)*uint64(r3) + uint64(h1)*uint64(r2) + uint64(h2)*uint64(r1) + uint64(h3)*uint64(r0) + uint64(h4)*uint64(s4)
		d4 := uint64(h0)*uint64(r4) + uint64(h1)*uint64(r3) + uint64(h2)*uint64(r2) + uint64(h3)*uint64(r1) + uint64(h4)*uint64(r0)

		c := uint32(d0 >> 26)
		h0 = uint32(d0) & mask26
		d1 += uint64(c)
		c = uint32(d1 >> 26)
		h1 = uint32(d1) & mask26
		d2 += uint64(c)
		c = uint32(d2 >> 26)
		h2 = uint32(d2) & mask26
		d3 += uint64(c)
		c = uint32(d3 >> 26)
		h3 = uint32(d3) & mask26
		d4 += uint64(c)
		c = uint32(d4 >> 26)
		h4 = uint32(d4) & mask26
		h0 += c * 5
		c = h0 >> 26
		h0 &= mask26
		h1 += c
	}
	h[0], h[1], h[2], h[3], h[4] = h0, h1, h2, h3, h4
}
