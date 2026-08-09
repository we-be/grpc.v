// Generated-stub smoke example: kv_pb.v + kv_grpc.v come from
//   v run cmd/vpbgen -m main -o kv_pb.v -grpc kv_grpc.v kv.proto
// (in the protobuf.v repo). No server here — this exists to prove the
// generated surface compiles and to show what calling it looks like.
module main

import grpc
import time

fn main() {
	mut client := KVClient{
		c: grpc.Client{
			base_url: 'https://localhost:50051'
		}
	}
	// per-call options compose functionally: a deadline plus request metadata
	reply := client.get(GetRequest{ key: 'answer' }, grpc.timeout(2 * time.second), grpc.header('authorization',
		'Bearer demo')) or {
		if err is grpc.StatusError {
			println('rpc failed with ${err.status.code}: ${err.status.message}')
		} else {
			println('transport error (expected without a server): ${err.msg()}')
		}
		return
	}
	// reply carries the decoded message plus the server's response metadata
	println('found=${reply.msg.found} value=${reply.msg.value.bytestr()}')
	if reply.metadata.len > 0 {
		println('response metadata: ${reply.metadata}')
	}
}
