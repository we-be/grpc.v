// Live interop assertions against the Go reference server (run.sh drives
// this). kv_pb.v / kv_grpc.v are copies of the examples/kv generated code.
module main

import os
import time
import grpc

@[noreturn]
fn fail(msg string) {
	eprintln('FAIL: ${msg}')
	exit(1)
}

fn main() {
	if os.args.len < 2 {
		fail('usage: vclient <base_url>')
	}
	mut client := KVClient{
		c: grpc.Client{
			base_url: os.args[1]
		}
	}

	// first put inserts, second replaces
	p1 := client.put(PutRequest{ key: 'k1', value: 'hello grpc'.bytes() }) or {
		fail('put 1: ${err.msg()}')
	}
	if p1.msg.replaced {
		fail('first put claimed replaced')
	}
	p2 := client.put(PutRequest{ key: 'k1', value: 'v2'.bytes() }) or {
		fail('put 2: ${err.msg()}')
	}
	if !p2.msg.replaced {
		fail('second put not replaced')
	}

	g := client.get(GetRequest{ key: 'k1' }) or { fail('get: ${err.msg()}') }
	if !g.msg.found || g.msg.value != 'v2'.bytes() {
		fail('get roundtrip: found=${g.msg.found} value=${g.msg.value}')
	}

	miss := client.get(GetRequest{ key: 'nope' }) or { fail('get miss: ${err.msg()}') }
	if miss.msg.found {
		fail('missing key reported found')
	}

	// awkward payloads must round-trip byte-exact through the gRPC bytes
	// field + 5-byte framing: a 1 MiB blob, a binary value (NUL, high
	// bytes, multi-byte UTF-8), and the empty value. Mirrors the connect
	// interop client's payload coverage on the native-gRPC transport.
	mut big := []u8{len: 1 << 20}
	for i in 0 .. big.len {
		big[i] = u8(i * 31)
	}
	tricky := [u8(0x00), 0xff, 0xfe, 0xc3, 0xa9, 0xf0, 0x9f, 0x9a, 0x80, 0x0a, 0x09]
	payloads := {
		'big':    big
		'tricky': tricky
		'empty':  []u8{}
	}
	for name, val in payloads {
		key := 'payload-${name}'
		client.put(PutRequest{ key: key, value: val }) or { fail('${name} put: ${err.msg()}') }
		got := client.get(GetRequest{ key: key }) or { fail('${name} get: ${err.msg()}') }
		if !got.msg.found {
			fail('${name} not found')
		}
		if got.msg.value != val {
			fail('${name} roundtrip mismatch (${got.msg.value.len} bytes)')
		}
	}

	// metadata: a request header is echoed back as response metadata
	echoed := client.get(GetRequest{ key: 'k1' }, grpc.header('x-echo', 'ping')) or {
		fail('metadata call: ${err.msg()}')
	}
	if echoed.metadata['x-echoed'] != ['ping'] {
		fail('request metadata not echoed as response metadata: ${echoed.metadata}')
	}

	// deadline: a short timeout against a deliberately slow method must
	// surface as deadline_exceeded, not hang
	if _ := client.get(GetRequest{ key: 'slow' }, grpc.timeout(200 * time.millisecond)) {
		fail('slow call should have hit the deadline')
	} else {
		if err is grpc.StatusError {
			if err.status.code != .deadline_exceeded {
				fail('slow deadline code: ${err.status.code}')
			}
		} else {
			fail('slow not a StatusError: ${err.msg()}')
		}
	}

	// error path: grpc-status + percent-encoded unicode grpc-message
	if _ := client.get(GetRequest{ key: 'boom' }) {
		fail('boom should have errored')
	} else {
		if err is grpc.StatusError {
			if err.status.code != .invalid_argument {
				fail('boom code: ${err.status.code}')
			}
			if err.status.message != 'bad key: 🚀 boom' {
				fail('boom message: `${err.status.message}`')
			}
		} else {
			fail('boom not a StatusError: ${err.msg()}')
		}
	}
	println('INTEROP OK')
}
