module grpc

import net.http
import json2

// Connect-protocol unary server (connectrpc.com) over V's stdlib HTTP/1.1
// server: POST /pkg.Service/Method with a bare message body in the proto
// or JSON codec. Errors leave as Connect JSON ({"code","message"}) with
// the spec's HTTP status mapping. gRPC clients cannot talk to this — that
// needs HTTP/2 trailers — but connect-go and connect-es clients can,
// natively, and Envoy bridges the rest.

pub enum Codec {
	proto
	json
}

// Service is implemented by vpbgen's generated <Name>Service dispatch
// structs; found=false means the path belongs to another service
pub interface Service {
mut:
	call(path string, codec Codec, body []u8) !([]u8, bool)
}

pub struct ConnectServer {
pub mut:
	addr     string
	services []Service
}

pub fn (mut s ConnectServer) mount(svc Service) {
	s.services << svc
}

pub fn (mut s ConnectServer) listen_and_serve() ! {
	mut srv := http.Server{
		addr:    s.addr
		handler: s
	}
	srv.listen_and_serve()
}

// handle implements http.Handler; exposed so tests can drive it without
// sockets
pub fn (mut s ConnectServer) handle(req http.Request) http.Response {
	if req.method != .post {
		return plain_response(405, 'Connect requires POST')
	}
	path := req.url.all_before('?')
	ct := req.header.get(.content_type) or { '' }
	codec := if ct.starts_with('application/json') {
		Codec.json
	} else if ct.starts_with('application/proto') {
		Codec.proto
	} else {
		return plain_response(415, 'unsupported codec `${ct}`')
	}
	if enc := req.header.get(.content_encoding) {
		if enc != '' && enc != 'identity' {
			return connect_error_response(.unimplemented, 'compression is not supported')
		}
	}
	body := req.data.bytes()
	for mut svc in s.services {
		res, found := svc.call(path, codec, body) or {
			if err is StatusError {
				return connect_error_response(err.status.code, err.status.message)
			}
			return connect_error_response(.internal, err.msg())
		}
		if found {
			out_ct := if codec == .json { 'application/json' } else { 'application/proto' }
			mut resp := http.Response{
				http_version: '1.1'
				status_code:  200
				status_msg:   'OK'
				body:         res.bytestr()
			}
			resp.header.add(.content_type, out_ct)
			resp.header.add(.content_length, res.len.str())
			return resp
		}
	}
	return connect_error_response(.unimplemented, 'no such procedure: ${path}')
}

// Connect error codes are the gRPC snake_case names, except the US
// spelling of canceled
fn connect_code_name(c Code) string {
	if c == .cancelled {
		return 'canceled'
	}
	return c.str()
}

// HTTP status per the Connect protocol's code table
fn connect_http_status(c Code) int {
	return match c {
		.cancelled { 499 }
		.invalid_argument, .failed_precondition, .out_of_range { 400 }
		.unauthenticated { 401 }
		.permission_denied { 403 }
		.not_found { 404 }
		.deadline_exceeded { 408 }
		.already_exists, .aborted { 409 }
		.resource_exhausted { 429 }
		.unimplemented { 501 }
		.unavailable { 503 }
		else { 500 }
	}
}

fn connect_error_response(code Code, message string) http.Response {
	body := json2.Any({
		'code':    json2.Any(connect_code_name(code))
		'message': json2.Any(message)
	}).json_str()
	mut resp := http.Response{
		http_version: '1.1'
		status_code:  connect_http_status(code)
		body:         body
	}
	resp.header.add(.content_type, 'application/json')
	resp.header.add(.content_length, body.len.str())
	return resp
}

fn plain_response(status int, msg string) http.Response {
	mut resp := http.Response{
		http_version: '1.1'
		status_code:  status
		body:         msg
	}
	resp.header.add(.content_type, 'text/plain')
	resp.header.add(.content_length, msg.len.str())
	return resp
}
