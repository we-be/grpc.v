// Exercises the registry showcase end to end: wire and protojson
// roundtrips over a node that touches every showcased feature, Any
// pack/unpack with a @type-tagged payload, and a call through the
// generated Connect dispatch in the JSON codec.
//
// Roundtrip assertions compare encode() == encode() rather than the
// values directly: with maps involved, canonical wire bytes are a more
// reliable equality than struct == across platforms.
module main

import grpc
import time

fn sample() Node {
	return Node{
		name:       'db'
		health:     .health_passing
		meta:       {
			'region': 'us-east'
			'tier':   'gold'
		}
		registered: GoogleProtobuf_Timestamp{
			seconds: 1_700_000_000 // 2023-11-14T22:13:20Z
		}
		ttl:        GoogleProtobuf_Duration.from_duration(30 * time.second)
		children:   [
			Node{
				name:   'db-0'
				health: .health_passing
			},
			Node{
				name:   'db-1'
				health: .health_critical
			},
		]
		leader:     &Node{ // singular recursion (?&Node): the primary child
			name:   'db-0'
			health: .health_passing
		}
		detail:     GetRequest{ // opaque typed payload, packed into Any
			path: 'db'
		}.to_any()
	}
}

fn test_wire_roundtrip() {
	n := sample()
	back := Node.decode(n.encode())!
	assert back.encode() == n.encode()
}

fn test_json_roundtrip() {
	n := sample()
	j := n.json()!
	// WKT special forms land in the JSON text
	assert j.contains('2023-11-14T22:13:20Z')
	assert j.contains('"ttl":"30s"')
	back := Node.from_json(j)!
	assert back.encode() == n.encode()
}

fn test_allow_alias() {
	// HEALTH_OK aliases HEALTH_PASSING (= 1); both name the same value
	assert int(Health.health_passing) == 1
	n := Node{
		name:   'x'
		health: .health_passing
	}
	assert n.json()!.contains('HEALTH_PASSING')
}

fn test_any_pack_unpack() {
	n := sample()
	a := n.detail or { panic('sample has no detail') }
	// canonical Any JSON carries the fully-qualified @type
	assert n.json()!.contains('registry.GetRequest')
	got := GetRequest.from_any(a)!
	assert got.path == 'db'
}

fn test_service_dispatch() {
	mut svc := RegistryService{
		h: Store{}
	}
	put_body := PutRequest{
		root: sample()
	}.json()!
	pres, put_found := svc.call('/registry.Registry/Put', .json, put_body.bytes())!
	assert put_found
	pr := PutResponse.from_json(pres.bytestr())!
	assert pr.nodes == 3 // root + two children

	get_body := GetRequest{
		path: 'db'
	}.json()!
	gres, get_found := svc.call('/registry.Registry/Get', .json, get_body.bytes())!
	assert get_found
	gr := GetResponse.from_json(gres.bytestr())!
	assert gr.found
	got := gr.node or { panic('stored node missing') }
	assert got.encode() == sample().encode()

	// unknown path is not this service's -> found=false
	_, other := svc.call('/registry.Registry/Nope', .json, get_body.bytes())!
	assert !other
}

fn test_put_rejects_empty_root() {
	mut svc := RegistryService{
		h: Store{}
	}
	body := PutRequest{
		root: Node{}
	}.json()!
	if _, _ := svc.call('/registry.Registry/Put', .json, body.bytes()) {
		panic('empty root name should have been rejected')
	} else {
		assert err is grpc.StatusError
	}
}

// a real generated dispatch (recursive Node schema included) must survive
// hostile bodies with a clean error, never a panic or hang
fn test_dispatch_survives_malformed_bodies() {
	mut svc := RegistryService{
		h: Store{}
	}
	// malformed JSON errors cleanly
	if _, _ := svc.call('/registry.Registry/Put', .json, 'not json{'.bytes()) {
		panic('malformed JSON should error')
	} else {
		assert err.msg().len > 0
	}
	// fuzz random proto + json bodies; the only contract is: no panic
	mut seed := u64(0x9E3779B97F4A7C15)
	next := fn [mut seed] () u64 {
		seed ^= seed << 13
		seed ^= seed >> 7
		seed ^= seed << 17
		return seed
	}
	for _ in 0 .. 8000 {
		n := int(next() % 32)
		mut b := []u8{len: n}
		for i in 0 .. n {
			b[i] = u8(next())
		}
		svc.call('/registry.Registry/Put', .proto, b) or {}
		svc.call('/registry.Registry/Get', .proto, b) or {}
		svc.call('/registry.Registry/Put', .json, b) or {}
	}
}
