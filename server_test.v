module grpc

import net.http

// echoes the body back for one path, errors for another
struct FakeService {
mut:
	last_codec Codec
}

fn (mut s FakeService) call(path string, codec Codec, body []u8) !([]u8, bool) {
	s.last_codec = codec
	match path {
		'/t.Echo/Do' {
			return body, true
		}
		'/t.Echo/Boom' {
			return StatusError{
				status: Status{
					code:    .not_found
					message: 'nope'
				}
			}
		}
		'/t.Echo/Stop' {
			return StatusError{
				status: Status{
					code: .cancelled
				}
			}
		}
		'/t.Echo/Fail' {
			// a plain (non-StatusError) failure, e.g. a body that failed to decode
			return error('handler blew up')
		}
		else {
			return []u8{}, false
		}
	}
}

fn post(mut s ConnectServer, path string, ct string, body string) http.Response {
	mut h := http.new_header()
	if ct != '' {
		h.add(.content_type, ct)
	}
	return s.handle(http.Request{
		method: .post
		url:    path
		data:   body
		header: h
	})
}

fn server() ConnectServer {
	mut s := ConnectServer{}
	s.mount(FakeService{})
	return s
}

fn test_proto_roundtrip() {
	mut s := server()
	resp := post(mut s, '/t.Echo/Do', 'application/proto', 'payload')
	assert resp.status_code == 200
	assert resp.body == 'payload'
	assert resp.header.get(.content_type) or { '' } == 'application/proto'
}

fn test_json_codec_selected() {
	mut s := server()
	resp := post(mut s, '/t.Echo/Do', 'application/json; charset=utf-8', '{"a":1}')
	assert resp.status_code == 200
	assert resp.header.get(.content_type) or { '' } == 'application/json'
}

fn test_status_error_mapping() {
	mut s := server()
	resp := post(mut s, '/t.Echo/Boom', 'application/proto', '')
	assert resp.status_code == 404
	assert resp.body.contains('"code":"not_found"')
	assert resp.body.contains('"message":"nope"')
	assert resp.header.get(.content_type) or { '' } == 'application/json'
}

fn test_canceled_spelling_and_499() {
	mut s := server()
	resp := post(mut s, '/t.Echo/Stop', 'application/proto', '')
	assert resp.status_code == 499
	assert resp.body.contains('"code":"canceled"')
}

fn test_unknown_procedure() {
	mut s := server()
	resp := post(mut s, '/t.Other/Nope', 'application/proto', '')
	assert resp.status_code == 501
	assert resp.body.contains('unimplemented')
}

fn test_non_post_rejected() {
	mut s := server()
	resp := s.handle(http.Request{
		method: .get
		url:    '/t.Echo/Do'
	})
	assert resp.status_code == 405
}

fn test_unsupported_codec() {
	mut s := server()
	resp := post(mut s, '/t.Echo/Do', 'text/xml', '<x/>')
	assert resp.status_code == 415
}

fn test_compression_refused() {
	mut s := server()
	mut h := http.new_header()
	h.add(.content_type, 'application/proto')
	h.add(.content_encoding, 'gzip')
	resp := s.handle(http.Request{
		method: .post
		url:    '/t.Echo/Do'
		data:   'x'
		header: h
	})
	assert resp.status_code == 501
	assert resp.body.contains('compression')
}

fn test_non_status_error_becomes_internal() {
	mut s := server()
	resp := post(mut s, '/t.Echo/Fail', 'application/proto', '')
	assert resp.status_code == 500
	assert resp.body.contains('"code":"internal"')
	assert resp.body.contains('handler blew up')
}

fn test_missing_content_type_rejected() {
	mut s := server()
	resp := post(mut s, '/t.Echo/Do', '', 'x')
	assert resp.status_code == 415
}

fn test_identity_encoding_allowed() {
	mut s := server()
	mut h := http.new_header()
	h.add(.content_type, 'application/proto')
	h.add(.content_encoding, 'identity')
	resp := s.handle(http.Request{
		method: .post
		url:    '/t.Echo/Do'
		data:   'ok'
		header: h
	})
	assert resp.status_code == 200
	assert resp.body == 'ok'
}

fn test_query_string_stripped_from_path() {
	mut s := server()
	resp := post(mut s, '/t.Echo/Do?trace=1', 'application/proto', 'q')
	assert resp.status_code == 200
	assert resp.body == 'q'
}

// pins the full Connect error-code table (connectrpc.com/docs/protocol#error-codes)
// to both the HTTP status and the wire code name, for every gRPC code — the
// interop only exercises one, so these guard the other 16 without a socket.
fn test_connect_error_code_table() {
	cases := [
		Code.cancelled,
		.unknown,
		.invalid_argument,
		.deadline_exceeded,
		.not_found,
		.already_exists,
		.permission_denied,
		.resource_exhausted,
		.failed_precondition,
		.aborted,
		.out_of_range,
		.unimplemented,
		.internal,
		.unavailable,
		.data_loss,
		.unauthenticated,
	]
	want_status := {
		Code.cancelled:       499
		.unknown:             500
		.invalid_argument:    400
		.deadline_exceeded:   504
		.not_found:           404
		.already_exists:      409
		.permission_denied:   403
		.resource_exhausted:  429
		.failed_precondition: 412
		.aborted:             409
		.out_of_range:        400
		.unimplemented:       501
		.internal:            500
		.unavailable:         503
		.data_loss:           500
		.unauthenticated:     401
	}
	for c in cases {
		resp := connect_error_response(c, 'x')
		assert resp.status_code == want_status[c], '${c}: got HTTP ${resp.status_code}'
		// cancelled is the one code whose wire name diverges from the enum (US spelling)
		name := if c == .cancelled { 'canceled' } else { c.str() }
		assert resp.body.contains('"code":"${name}"'), '${c}: body ${resp.body}'
	}
}
