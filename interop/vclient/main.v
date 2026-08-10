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
