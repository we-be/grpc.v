module grpc

import net.http

// Native unary gRPC server over V's HTTP/2 stack. Where ConnectServer speaks
// the Connect protocol on HTTP/1.1, GrpcServer speaks real gRPC: HTTP/2 (TLS
// via ALPN, or cleartext h2c on a plain listener), 5-byte-framed messages, and
// the terminal status in HTTP/2 trailers. Both drive the same generated
// Service dispatch, so one service is served over either transport unchanged.
//
// Unary only: V's net.http Handler is one-request/one-response — exactly a
// unary RPC, but it cannot express streaming (that needs an upstream
// streaming-handler API).

const grpc_content_type = 'application/grpc+proto'

pub struct GrpcServer {
pub mut:
	addr     string
	services []Service
	// TLS termination: set both to serve gRPC over HTTPS (ALPN h2). Left empty,
	// the server runs cleartext h2c — what insecure gRPC clients use.
	cert     string
	cert_key string
}

pub fn (mut s GrpcServer) mount(svc Service) {
	s.services << svc
}

pub fn (mut s GrpcServer) listen_and_serve() ! {
	mut srv := http.Server{
		addr:         s.addr
		handler:      s
		enable_http2: true
		cert:         s.cert
		cert_key:     s.cert_key
	}
	srv.listen_and_serve()
}

// handle implements http.Handler; exposed so tests can drive it without
// sockets. Every gRPC response is HTTP 200 — the real outcome rides in the
// grpc-status trailer — so even failures go out through grpc_error, never an
// HTTP error code.
pub fn (mut s GrpcServer) handle(req http.Request) http.Response {
	mut ctx := ServerContext{
		request_headers: request_metadata(req.header)
	}
	if req.method != .post {
		return grpc_error(Status{ code: .internal, message: 'gRPC requires POST' }, ctx)
	}
	path := req.url.all_before('?')
	ct := req.header.get(.content_type) or { '' }
	if !ct.starts_with('application/grpc') {
		return grpc_error(Status{ code: .internal, message: 'unexpected content-type `${ct}`' },
			ctx)
	}
	// unary: exactly one length-prefixed request message
	frame, n := decode_frame(req.data.bytes()) or {
		return grpc_error(Status{ code: .internal, message: err.msg() }, ctx)
	}
	if n == 0 {
		return grpc_error(Status{ code: .internal, message: 'truncated request frame' }, ctx)
	}
	if frame.compressed {
		return grpc_error(Status{ code: .unimplemented, message: 'compressed request not supported' },
			ctx)
	}
	for mut svc in s.services {
		reply, found := svc.call(path, .proto, frame.payload, mut ctx) or {
			if err is StatusError {
				return grpc_error(err.status, ctx)
			}
			return grpc_error(Status{ code: .internal, message: err.msg() }, ctx)
		}
		if found {
			return grpc_ok(reply, ctx)
		}
	}
	return grpc_error(Status{ code: .unimplemented, message: 'no such procedure: ${path}' }, ctx)
}

// grpc_ok frames the reply and closes the stream with grpc-status: 0.
fn grpc_ok(reply []u8, ctx ServerContext) http.Response {
	mut resp := http.Response{
		status_code: 200
		body:        encode_frame(reply, false).bytestr()
	}
	resp.header.add(.content_type, grpc_content_type)
	apply_leading(mut resp, ctx)
	mut trailers := http.new_header()
	trailers.add_custom('grpc-status', '0') or {}
	apply_trailing(mut trailers, ctx)
	resp.trailers = trailers
	return resp
}

// grpc_error sends a Trailers-Only response: no body, so V's h2 server folds
// the status into a single HEADERS block — also the shape gRPC uses when a call
// fails before producing a message.
fn grpc_error(status Status, ctx ServerContext) http.Response {
	mut resp := http.Response{
		status_code: 200
	}
	resp.header.add(.content_type, grpc_content_type)
	apply_leading(mut resp, ctx)
	mut trailers := http.new_header()
	trailers.add_custom('grpc-status', int(status.code).str()) or {}
	if status.message != '' {
		trailers.add_custom('grpc-message', percent_encode(status.message)) or {}
	}
	apply_trailing(mut trailers, ctx)
	resp.trailers = trailers
	return resp
}

// leading response metadata rides as ordinary headers; repeated values repeat.
fn apply_leading(mut resp http.Response, ctx ServerContext) {
	for k, vals in ctx.resp_headers {
		for v in vals {
			resp.header.add_custom(k, v) or {}
		}
	}
}

// trailing response metadata joins grpc-status/grpc-message in the trailers.
fn apply_trailing(mut trailers http.Header, ctx ServerContext) {
	for k, vals in ctx.resp_trailers {
		for v in vals {
			trailers.add_custom(k, v) or {}
		}
	}
}
