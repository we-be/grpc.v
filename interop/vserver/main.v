// The V Connect server under test: KVHandler over an in-memory map,
// mounted on grpc.ConnectServer. connect_run.sh drives connect-go
// clients against it in both codecs.
module main

import os
import grpc

struct Store {
mut:
	m map[string][]u8
}

fn (mut s Store) get(req GetRequest) !GetResponse {
	if req.key == 'boom' {
		return grpc.StatusError{
			status: grpc.Status{
				code:    .invalid_argument
				message: 'bad key: 🚀 boom'
			}
		}
	}
	// `code:<n>` drives the full error-code table: return gRPC code n with a
	// unicode message, so the client can assert both the code and the
	// percent-encoded grpc-message survive the Connect round-trip.
	if req.key.starts_with('code:') {
		n := req.key['code:'.len..].int()
		code := grpc.code_from_int(n) or {
			return grpc.StatusError{
				status: grpc.Status{
					code:    .internal
					message: 'bad code ${n}'
				}
			}
		}
		return grpc.StatusError{
			status: grpc.Status{
				code:    code
				message: 'status 🚀 ${n}'
			}
		}
	}
	if v := s.m[req.key] {
		return GetResponse{
			value: v
			found: true
		}
	}
	return GetResponse{}
}

fn (mut s Store) put(req PutRequest) !PutResponse {
	replaced := req.key in s.m
	s.m[req.key] = req.value
	return PutResponse{
		replaced: replaced
	}
}

fn main() {
	addr := if os.args.len > 1 { os.args[1] } else { ':8181' }
	mut srv := grpc.ConnectServer{
		addr: addr
	}
	srv.mount(KVService{
		h: Store{}
	})
	println('READY')
	srv.listen_and_serve() or { panic(err) }
}
