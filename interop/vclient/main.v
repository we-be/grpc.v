// Live interop assertions against the Go reference server (run.sh drives
// this). kv_pb.v / kv_grpc.v are copies of the examples/kv generated code.
module main

import os
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
	if p1.replaced {
		fail('first put claimed replaced')
	}
	p2 := client.put(PutRequest{ key: 'k1', value: 'v2'.bytes() }) or {
		fail('put 2: ${err.msg()}')
	}
	if !p2.replaced {
		fail('second put not replaced')
	}

	g := client.get(GetRequest{ key: 'k1' }) or { fail('get: ${err.msg()}') }
	if !g.found || g.value != 'v2'.bytes() {
		fail('get roundtrip: found=${g.found} value=${g.value}')
	}

	miss := client.get(GetRequest{ key: 'nope' }) or { fail('get miss: ${err.msg()}') }
	if miss.found {
		fail('missing key reported found')
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
