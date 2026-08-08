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
