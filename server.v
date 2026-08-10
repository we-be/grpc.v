module grpc

import net.http
import json2
import encoding.base64

// Connect-protocol unary server (connectrpc.com) over V's stdlib HTTP/1.1
// server: POST /pkg.Service/Method with a bare message body in the proto or
// JSON codec. Errors leave as Connect JSON ({"code","message","details"})
// with the spec's HTTP status mapping. gRPC clients cannot talk to this — that
// needs HTTP/2 trailers — but connect-go and connect-es clients can, natively,
// and Envoy bridges the rest.

pub enum Codec {
	proto
	json
}

// ServerContext carries per-call metadata between the transport and a handler:
// request leading metadata in, response leading metadata (headers) and
// trailing metadata (trailers) out. In the Connect unary protocol, trailers
// are sent as response headers with a `Trailer-` prefix.
pub struct ServerContext {
mut:
	resp_headers  map[string]string
	resp_trailers map[string]string
pub:
	request_headers map[string]string
}

// header returns an incoming request metadata value (case-insensitive), or ''.
pub fn (c &ServerContext) header(key string) string {
	return c.request_headers[key.to_lower()] or { '' }
}

// has_header reports whether the request carried this metadata key.
pub fn (c &ServerContext) has_header(key string) bool {
	return key.to_lower() in c.request_headers
}

// set_header adds leading response metadata.
pub fn (mut c ServerContext) set_header(key string, value string) {
	c.resp_headers[key.to_lower()] = value
}

// set_trailer adds trailing response metadata.
pub fn (mut c ServerContext) set_trailer(key string, value string) {
	c.resp_trailers[key.to_lower()] = value
}

// Service is implemented by vpbgen's generated <Name>Service dispatch
// structs; found=false means the path belongs to another service
pub interface Service {
mut:
	call(path string, codec Codec, body []u8, mut ctx ServerContext) !([]u8, bool)
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
			return connect_error_response(.unimplemented, 'compression is not supported', ServerContext{})
		}
	}
	mut ctx := ServerContext{
		request_headers: request_metadata(req.header)
	}
	body := req.data.bytes()
	for mut svc in s.services {
		res, found := svc.call(path, codec, body, mut ctx) or {
			if err is StatusError {
				return connect_error(err.status, ctx)
			}
			return connect_error_response(.internal, err.msg(), ctx)
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
			apply_metadata(mut resp, ctx)
			return resp
		}
	}
	return connect_error_response(.unimplemented, 'no such procedure: ${path}', ctx)
}

// request_metadata lowercases every incoming header into a flat map the
// handler reads as leading request metadata.
fn request_metadata(h http.Header) map[string]string {
	mut m := map[string]string{}
	for k in h.keys() {
		m[k.to_lower()] = h.get_custom(k, exact: true) or { continue }
	}
	return m
}

// apply_metadata writes a handler's response metadata onto the wire: leading
// metadata as plain headers, trailing metadata as `Trailer-`-prefixed headers
// per the Connect unary protocol.
fn apply_metadata(mut resp http.Response, ctx ServerContext) {
	for k, v in ctx.resp_headers {
		resp.header.add_custom(k, v) or {}
	}
	for k, v in ctx.resp_trailers {
		resp.header.add_custom('trailer-${k}', v) or {}
	}
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
// (connectrpc.com/docs/protocol#error-codes). else = 500: ok, unknown,
// internal, data_loss.
fn connect_http_status(c Code) int {
	return match c {
		.cancelled { 499 }
		.invalid_argument, .out_of_range { 400 }
		.unauthenticated { 401 }
		.permission_denied { 403 }
		.not_found { 404 }
		.deadline_exceeded { 504 }
		.already_exists, .aborted { 409 }
		.failed_precondition { 412 }
		.resource_exhausted { 429 }
		.unimplemented { 501 }
		.unavailable { 503 }
		else { 500 }
	}
}

// connect_error renders a Status as a Connect error response: the JSON error
// body (code, message, and any typed details base64-encoded) with the spec
// HTTP status, plus the handler's response metadata.
fn connect_error(status Status, ctx ServerContext) http.Response {
	mut obj := {
		'code':    json2.Any(connect_code_name(status.code))
		'message': json2.Any(status.message)
	}
	if status.details.len > 0 {
		mut arr := []json2.Any{}
		for d in status.details {
			arr << json2.Any({
				'type':  json2.Any(d.type_name)
				'value': json2.Any(base64.encode(d.value))
			})
		}
		obj['details'] = json2.Any(arr)
	}
	body := json2.Any(obj).json_str()
	mut resp := http.Response{
		http_version: '1.1'
		status_code:  connect_http_status(status.code)
		body:         body
	}
	resp.header.add(.content_type, 'application/json')
	resp.header.add(.content_length, body.len.str())
	apply_metadata(mut resp, ctx)
	return resp
}

fn connect_error_response(code Code, message string, ctx ServerContext) http.Response {
	return connect_error(Status{ code: code, message: message }, ctx)
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
