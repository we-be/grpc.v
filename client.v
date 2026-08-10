module grpc

import net.http
import time

// Client speaks unary gRPC over V's stdlib HTTP client. Real gRPC needs
// HTTP/2, which net.http negotiates via ALPN on https URLs only — plain
// http targets fall back to HTTP/1.1 and conforming servers refuse them.
pub struct Client {
pub mut:
	base_url string              // scheme://host[:port], no trailing slash
	metadata map[string][]string // default headers merged into every call
}

// unary sends one framed request to path ('/pkg.Service/Method') and returns
// the response payload plus response metadata. Client.metadata forms the
// defaults; CallOptions layer on top (deadline, per-call metadata). Non-OK
// outcomes — including a fired deadline — surface as StatusError.
pub fn (mut c Client) unary(path string, msg []u8, opts ...CallOption) !RawReply {
	mut cfg := CallConfig{
		metadata: c.metadata.clone()
	}
	for o in opts {
		o(mut cfg)
	}
	mut h := http.new_header()
	h.add(.content_type, 'application/grpc+proto')
	h.add_custom('te', 'trailers')!
	if cfg.timeout > 0 {
		h.add_custom('grpc-timeout', encode_grpc_timeout(cfg.timeout))!
	}
	for k, vals in cfg.metadata {
		for v in vals {
			h.add_custom(k, v)!
		}
	}
	mut fc := http.FetchConfig{
		url:    c.base_url + path
		method: .post
		header: h
		data:   encode_frame(msg, false).bytestr()
	}
	if cfg.timeout > 0 {
		// enforce the deadline client-side too, not just as a server hint
		fc.read_timeout = cfg.timeout
		fc.write_timeout = cfg.timeout
	}
	start := time.now()
	resp := http.fetch(fc) or {
		// attribute the failure to the deadline only if the deadline actually
		// elapsed — robust regardless of how the transport words the error
		deadline_hit := cfg.timeout > 0 && time.since(start) >= cfg.timeout
		return transport_error(err, deadline_hit)
	}
	payload := parse_unary_response(resp.status_code, resp.header, resp.body.bytes())!
	return RawReply{
		payload:  payload
		metadata: response_metadata(resp.header)
	}
}

// transport_error maps a failed fetch to a gRPC status: a fired deadline to
// deadline_exceeded, any other transport failure (refused, reset, DNS) to
// unavailable — the gRPC convention.
fn transport_error(err IError, deadline_hit bool) StatusError {
	code := if deadline_hit { Code.deadline_exceeded } else { Code.unavailable }
	return StatusError{
		status: Status{
			code:    code
			message: err.msg()
		}
	}
}

// response_metadata collects response headers/trailers, minus the gRPC control
// headers the client consumes itself, so callers see only application metadata.
fn response_metadata(h http.Header) map[string][]string {
	skip := ['grpc-status', 'grpc-message', 'content-type', 'te']
	mut m := map[string][]string{}
	for k in h.keys() {
		if k.to_lower() in skip {
			continue
		}
		vals := h.custom_values(k, exact: false)
		if vals.len > 0 {
			m[k] = vals
		}
	}
	return m
}

// split from unary so the response contract is testable without a server;
// the h2 layer merges response trailers into the header set, so
// grpc-status is readable here either way
fn parse_unary_response(status_code int, h http.Header, body []u8) ![]u8 {
	if status_code != 200 {
		return StatusError{
			status: Status{
				code:    code_from_http(status_code)
				message: 'HTTP ${status_code}'
			}
		}
	}
	ct := h.get(.content_type) or { '' }
	if !ct.starts_with('application/grpc') {
		return StatusError{
			status: Status{
				code:    .unknown
				message: 'unexpected content-type `${ct}`'
			}
		}
	}
	gs := h.get_custom('grpc-status') or {
		return StatusError{
			status: Status{
				code:    .unknown
				message: 'missing grpc-status'
			}
		}
	}
	// .int() parses garbage as 0, which would read as OK — reject first
	if gs.len == 0 || !gs.bytes().all(it >= `0` && it <= `9`) {
		return StatusError{
			status: Status{
				code:    .unknown
				message: 'malformed grpc-status `${gs}`'
			}
		}
	}
	code := code_from_int(gs.int()) or {
		return StatusError{
			status: Status{
				code:    .unknown
				message: err.msg()
			}
		}
	}
	if code != .ok {
		return StatusError{
			status: Status{
				code:    code
				message: percent_decode(h.get_custom('grpc-message') or { '' })
			}
		}
	}
	frames := decode_frames(body)!
	if frames.len != 1 {
		return StatusError{
			status: Status{
				code:    .internal
				message: 'expected 1 response message, got ${frames.len}'
			}
		}
	}
	if frames[0].compressed {
		return StatusError{
			status: Status{
				code:    .unimplemented
				message: 'compressed response not supported'
			}
		}
	}
	return frames[0].payload
}

// HTTP status to gRPC code, per the gRPC-over-HTTP/2 spec
fn code_from_http(status int) Code {
	return match status {
		400 { Code.internal }
		401 { Code.unauthenticated }
		403 { Code.permission_denied }
		404 { Code.unimplemented }
		429, 502, 503, 504 { Code.unavailable }
		else { Code.unknown }
	}
}
