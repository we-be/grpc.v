module grpc

// Adversarial + generative fuzzing of the frame decoder: hostile input must
// never panic, over-allocate, or hang — only parse cleanly or return an error.

// deterministic xorshift so a failure is reproducible from the seed
struct Rng {
mut:
	s u64
}

fn (mut r Rng) next() u64 {
	mut x := r.s
	x ^= x << 13
	x ^= x >> 7
	x ^= x << 17
	r.s = x
	return x
}

fn test_decode_frame_fuzz_never_panics() {
	mut r := Rng{
		s: 0xC0FFEE123
	}
	for _ in 0 .. 50000 {
		// small buffers hit the header/length-boundary logic hardest
		n := int(r.next() % 40)
		mut buf := []u8{len: n}
		for i in 0 .. n {
			buf[i] = u8(r.next())
		}
		frame, consumed := decode_frame(buf) or {
			// an error is fine; a second call on hostile input must also not panic
			decode_frames(buf) or {}
			continue
		}
		if consumed == 0 {
			continue // valid but incomplete prefix
		}
		// a parsed frame must stay within bounds and round-trip byte-exactly
		assert consumed >= frame_header_len
		assert consumed <= buf.len
		assert encode_frame(frame.payload, frame.compressed) == buf[..consumed]
		decode_frames(buf) or {}
	}
}

fn test_decode_frame_adversarial_cases() {
	// length prefix of 0xFFFFFFFF must be rejected before any allocation
	if _, _ := decode_frame([u8(0), 0xFF, 0xFF, 0xFF, 0xFF, 0x00]) {
		assert false, 'oversized length should error'
	} else {
		assert err.msg().contains('exceeds')
	}
	// invalid compressed flag
	if _, _ := decode_frame([u8(9), 0, 0, 0, 0]) {
		assert false, 'flag > 1 should error'
	} else {
		assert err.msg().contains('compressed flag')
	}
	// a header claiming more bytes than present is incomplete, not an error
	// and must not allocate the claimed length
	f, consumed := decode_frame([u8(0), 0, 0, 0x10, 0x00, 0xAA])!
	assert consumed == 0
	assert f.payload.len == 0
	// exact one-byte frame round-trips
	f2, c2 := decode_frame([u8(0), 0, 0, 0, 1, 0x42])!
	assert c2 == 6 && f2.payload == [u8(0x42)] && !f2.compressed
	// trailing bytes after a complete frame are a truncated second frame
	mut two := encode_frame([u8(1), 2], false)
	two << [u8(0), 0, 0] // partial header
	if _ := decode_frames(two) {
		assert false, 'trailing partial frame should error'
	} else {
		assert err.msg().contains('truncated')
	}
	// empty input decodes to zero frames
	assert decode_frames([]u8{})!.len == 0
}
