// registry: a Connect server storing a tree of service nodes in memory.
// The point of this example is breadth — it exercises protobuf.v's WKTs,
// maps, Any, an allow_alias enum, and both flavors of recursion through a
// single generated service. registry_test.v drives the same handler.
//
//   v run examples/registry            # serves on :8383
//   curl -X POST localhost:8383/registry.Registry/Get \
//        -H 'content-type: application/json' -d '{"path":"db"}'
module main

import os
import grpc

struct Store {
mut:
	trees map[string]Node // keyed by root node name
}

// count returns the size of a subtree (the node plus all descendants).
fn count(n Node) int {
	mut c := 1
	for ch in n.children {
		c += count(ch)
	}
	return c
}

fn (mut s Store) put(mut ctx grpc.ServerContext, req PutRequest) !PutResponse {
	root := req.root or {
		return grpc.StatusError{
			status: grpc.Status{
				code:    .invalid_argument
				message: 'root node required'
			}
		}
	}

	if root.name == '' {
		return grpc.StatusError{
			status: grpc.Status{
				code:    .invalid_argument
				message: 'root name must not be empty'
			}
		}
	}
	s.trees[root.name] = root
	return PutResponse{
		nodes: count(root)
	}
}

fn (mut s Store) get(mut ctx grpc.ServerContext, req GetRequest) !GetResponse {
	if n := s.trees[req.path] {
		return GetResponse{
			node:  n
			found: true
		}
	}
	return GetResponse{}
}

fn main() {
	addr := if os.args.len > 1 { os.args[1] } else { ':8383' }
	mut srv := grpc.GrpcServer{
		addr: addr
	}
	srv.mount(RegistryService{
		h: Store{}
	})
	println('registry serving on ${addr}')
	srv.listen_and_serve() or { panic(err) }
}
