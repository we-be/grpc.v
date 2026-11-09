module grpc

import net.http
import encoding.base64
import protobuf

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

// GrpcService is the native-gRPC dispatch a generated <Name>Service satisfies
// (alongside Service, the Connect one): a list of request message payloads in,
// a list of response message payloads out — so one call covers unary (one in,
// one out), server-streaming (one in, many out), and client-streaming (many in,
// one out). found=false means the path belongs to another mounted service.
pub interface GrpcService {
mut:
	grpc_call(path string, reqs [][]u8, mut ctx ServerContext) !([][]u8, bool)
}

pub struct GrpcServer {
pub mut:
	addr     string
	services []GrpcService
	// TLS termination: set both to serve gRPC over HTTPS (ALPN h2). Left empty,
	// the server runs cleartext h2c — what insecure gRPC clients use.
	cert     string
	cert_key string
	// max_receive_bytes caps each request message: a larger one is rejected
	// with resource_exhausted before any handler runs. 0 means no limit beyond
	// the frame decoder's max_frame_len.
	max_receive_bytes int
}

pub fn (mut s GrpcServer) mount(svc GrpcService) {
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
	// a request that is not gRPC at all gets the spec's plain HTTP 415, not a
	// gRPC-framed status: whatever sent it cannot read trailers anyway
	if !ct.starts_with('application/grpc') {
		return plain_response(415, 'unsupported media type `${ct}`: gRPC requires application/grpc')
	}
	// the content-type's sub-format names the codec; the generated dispatch
	// decodes proto, so any other codec is one we do not implement
	if !grpc_codec_is_proto(ct) {
		return grpc_error(Status{ code: .unimplemented, message: 'unsupported codec `${ct}`' },
			ctx)
	}
	// we negotiate no compression: a request encoded with anything but
	// identity is unimplemented, and the reply names what we do accept
	encoding := ctx.header('grpc-encoding')
	if encoding != '' && encoding != 'identity' {
		mut resp := grpc_error(Status{
			code:    .unimplemented
			message: 'unsupported compression `${encoding}`'
		}, ctx)
		resp.header.add_custom('grpc-accept-encoding', 'identity') or {}
		return resp
	}
	// unary + client-streaming both arrive as one or more length-prefixed
	// request messages in the body
	reqs := decode_request_frames(req.data.bytes(), s.max_receive_bytes) or {
		if err is StatusError {
			return grpc_error(err.status, ctx)
		}
		return grpc_error(Status{ code: .internal, message: err.msg() }, ctx)
	}
	for mut svc in s.services {
		replies, found := svc.grpc_call(path, reqs, mut ctx) or {
			if err is StatusError {
				return grpc_error(err.status, ctx)
			}
			return grpc_error(Status{ code: .internal, message: err.msg() }, ctx)
		}
		if found {
			return grpc_ok(replies, ctx)
		}
	}
	return grpc_error(Status{ code: .unimplemented, message: 'no such procedure: ${path}' }, ctx)
}

// grpc_codec_is_proto reads the codec off a gRPC content-type: bare
// `application/grpc` means proto, as does an explicit `+proto`.
fn grpc_codec_is_proto(ct string) bool {
	base := ct.all_before(';').trim_space()
	return base == 'application/grpc' || base == 'application/grpc+proto'
}

// decode_request_frames splits the request body into its message payloads,
// rejecting one over max_bytes (when > 0) as resource_exhausted and a
// truncated one as a decode error. handle has already established that
// grpc-encoding is identity, so a frame flagged compressed is a protocol
// error (the spec's INTERNAL), not a codec we lack.
fn decode_request_frames(body []u8, max_bytes int) ![][]u8 {
	frames := decode_frames(body)!
	mut msgs := [][]u8{cap: frames.len}
	for f in frames {
		if f.compressed {
			return StatusError{
				status: Status{
					code:    .internal
					message: 'compressed message under identity grpc-encoding'
				}
			}
		}
		if max_bytes > 0 && f.payload.len > max_bytes {
			return StatusError{
				status: Status{
					code:    .resource_exhausted
					message: receive_limit_message(f.payload.len, max_bytes)
				}
			}
		}
		msgs << f.payload
	}
	return msgs
}

// grpc_ok frames every reply message into the body and closes the stream with
// grpc-status: 0 — one message for unary, many for server-streaming, none for
// an empty stream (which folds to a Trailers-Only success).
fn grpc_ok(replies [][]u8, ctx ServerContext) http.Response {
	mut out := []u8{}
	for r in replies {
		out << encode_frame(r, false)
	}
	mut resp := http.Response{
		status_code: 200
		body:        out.bytestr()
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
	if status.details.len > 0 {
		trailers.add_custom('grpc-status-details-bin', encode_bin_header(encode_rpc_status(status))) or {}
	}
	apply_trailing(mut trailers, ctx)
	resp.trailers = trailers
	return resp
}

// encode_rpc_status serializes a Status as google.rpc.Status — int32 code (1),
// string message (2), repeated Any details (3) — the message gRPC carries in
// the grpc-status-details-bin trailer so typed error details reach the client.
// Each ErrorDetail becomes an Any whose type_url is the conventional
// `type.googleapis.com/` plus the detail's fully-qualified proto name.
fn encode_rpc_status(status Status) []u8 {
	mut e := protobuf.Encoder{}
	if status.code != .ok {
		e.write_int32_field(1, int(status.code))
	}
	if status.message != '' {
		e.write_string_field(2, status.message)
	}
	for d in status.details {
		mut a := protobuf.Encoder{}
		a.write_string_field(1, 'type.googleapis.com/' + d.type_name)
		if d.value.len > 0 {
			a.write_bytes_field(2, d.value)
		}
		e.write_message_field(3, a.buf)
	}
	return e.buf
}

// encode_bin_header renders a `-bin` metadata value: base64 without padding,
// as grpc-go emits it (the spec has receivers accept padded and unpadded).
fn encode_bin_header(b []u8) string {
	return base64.encode(b).trim_right('=')
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
