module grpc

import net.http

// Client speaks unary gRPC over V's stdlib HTTP client. Real gRPC needs
// HTTP/2, which net.http negotiates via ALPN on https URLs only — plain
// http targets fall back to HTTP/1.1 and conforming servers refuse them.
pub struct Client {
pub mut:
	base_url string            // scheme://host[:port], no trailing slash
	metadata map[string]string // extra headers sent with every call
}

// unary sends one framed request to path ('/pkg.Service/Method') and
// returns the response message bytes. Non-OK outcomes surface as
// StatusError.
pub fn (mut c Client) unary(path string, msg []u8) ![]u8 {
	mut h := http.new_header()
	h.add(.content_type, 'application/grpc+proto')
	h.add_custom('te', 'trailers')!
	for k, v in c.metadata {
		h.add_custom(k, v)!
	}
	resp := http.fetch(
		url:    c.base_url + path
		method: .post
		header: h
		data:   encode_frame(msg, false).bytestr()
	)!
	return parse_unary_response(resp.status_code, resp.header, resp.body.bytes())
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
