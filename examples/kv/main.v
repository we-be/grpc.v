// Generated-stub smoke example: kv_pb.v + kv_grpc.v come from
//   v run cmd/vpbgen -m main -o kv_pb.v -grpc kv_grpc.v kv.proto
// (in the protobuf.v repo). No server here — this exists to prove the
// generated surface compiles and to show what calling it looks like.
module main

import grpc

fn main() {
	mut client := KVClient{
		c: grpc.Client{
			base_url: 'https://localhost:50051'
		}
	}
	resp := client.get(GetRequest{ key: 'answer' }) or {
		if err is grpc.StatusError {
			println('rpc failed with ${err.status.code}: ${err.status.message}')
		} else {
			println('transport error (expected without a server): ${err.msg()}')
		}
		return
	}
	println('found=${resp.found} value=${resp.value.bytestr()}')
}
