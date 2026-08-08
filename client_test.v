module grpc

import net.http

fn hdr(pairs map[string]string) http.Header {
	mut h := http.new_header()
	for k, v in pairs {
		h.add_custom(k, v) or { panic(err) }
	}
	return h
}

const ok_hdr = {
	'content-type': 'application/grpc+proto'
	'grpc-status':  '0'
}

fn expect_status(status_code int, h http.Header, body []u8, want Code, msg_part string) {
	if _ := parse_unary_response(status_code, h, body) {
		assert false, 'expected StatusError ${want}'
	} else {
		if err is StatusError {
			assert err.status.code == want, 'got ${err.status.code}: ${err.status.message}'
			assert err.status.message.contains(msg_part), err.status.message
		} else {
			assert false, 'not a StatusError: ${err.msg()}'
		}
	}
}

fn test_ok_response() ! {
	payload := 'response bytes'.bytes()
	body := encode_frame(payload, false)
	got := parse_unary_response(200, hdr(ok_hdr), body)!
	assert got == payload
}

fn test_error_status_with_percent_message() {
	h := hdr({
		'content-type': 'application/grpc+proto'
		'grpc-status':  '3'
		'grpc-message': 'bad%20arg%3A%20id'
	})
	expect_status(200, h, [], .invalid_argument, 'bad arg: id')
}

fn test_missing_grpc_status() {
	h := hdr({
		'content-type': 'application/grpc+proto'
	})
	expect_status(200, h, [], .unknown, 'missing grpc-status')
}

fn test_malformed_grpc_status() {
	h := hdr({
		'content-type': 'application/grpc+proto'
		'grpc-status':  'abc'
	})
	expect_status(200, h, [], .unknown, 'malformed')
}

fn test_out_of_range_grpc_status() {
	h := hdr({
		'content-type': 'application/grpc+proto'
		'grpc-status':  '99'
	})
	expect_status(200, h, [], .unknown, 'invalid status code')
}

fn test_http_error_mapping() {
	expect_status(404, hdr({}), [], .unimplemented, 'HTTP 404')
	expect_status(503, hdr({}), [], .unavailable, 'HTTP 503')
	expect_status(418, hdr({}), [], .unknown, 'HTTP 418')
}

fn test_wrong_content_type() {
	h := hdr({
		'content-type': 'text/html'
		'grpc-status':  '0'
	})
	expect_status(200, h, [], .unknown, 'content-type')
}

fn test_multiple_frames_rejected() {
	mut body := encode_frame('a'.bytes(), false)
	body << encode_frame('b'.bytes(), false)
	expect_status(200, hdr(ok_hdr), body, .internal, 'expected 1')
}

fn test_compressed_frame_rejected() {
	body := encode_frame('a'.bytes(), true)
	expect_status(200, hdr(ok_hdr), body, .unimplemented, 'compressed')
}

fn test_percent_decode() {
	assert percent_decode('plain') == 'plain'
	assert percent_decode('a%20b%3a%3B') == 'a b:;'
	assert percent_decode('bad%zz%2') == 'bad%zz%2'
	assert percent_decode('%F0%9F%9A%80') == '🚀'
}
