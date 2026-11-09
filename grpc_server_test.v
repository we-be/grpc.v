module grpc

import net.http
import encoding.base64
import protobuf

// A hand-rolled GrpcService so the server can be driven without generated
// stubs: /echo.Echo/Ok echoes every request message back and stamps leading +
// trailing metadata; /echo.Echo/Fan turns one request into three responses
// (server-streaming shape); /echo.Echo/Boom fails with a unicode message;
// /echo.Echo/Detail fails with a typed error detail attached; anything else is
// a routing miss.
struct EchoSvc {}

fn (mut e EchoSvc) grpc_call(path string, reqs [][]u8, mut ctx ServerContext) !([][]u8, bool) {
	match path {
		'/echo.Echo/Ok' {
			ctx.set_header('x-lead', 'L')
			ctx.set_trailer('x-trail', 'T')
			return reqs, true
		}
		'/echo.Echo/Fan' {
			return [reqs[0], reqs[0], reqs[0]], true
		}
		'/echo.Echo/Boom' {
			return StatusError{
				status: Status{
					code:    .invalid_argument
					message: 'nope 🚀'
				}
			}
		}
		'/echo.Echo/Detail' {
			return StatusError{
				status: Status{
					code:    .failed_precondition
					message: 'needs a detail'
					details: [
						ErrorDetail{
							type_name: 'google.rpc.ErrorInfo'
							value:     [u8(1), 2, 3, 4]
						},
					]
				}
			}
		}
		else {
			return [][]u8{}, false
		}
	}
}

fn grpc_request_multi(path string, payloads [][]u8) http.Request {
	mut h := http.new_header()
	h.add(.content_type, 'application/grpc+proto')
	mut body := []u8{}
	for p in payloads {
		body << encode_frame(p, false)
	}
	return http.Request{
		method: .post
		url:    path
		header: h
		data:   body.bytestr()
	}
}

fn grpc_request(path string, payload []u8) http.Request {
	return grpc_request_multi(path, [payload])
}

fn new_test_server() GrpcServer {
	mut s := GrpcServer{}
	s.mount(EchoSvc{})
	return s
}

fn test_grpc_ok_frames_reply_and_sets_status_trailer() {
	mut s := new_test_server()
	msg := 'hello world'.bytes()
	resp := s.handle(grpc_request('/echo.Echo/Ok', msg))

	assert resp.status_code == 200
	ct := resp.header.get(.content_type) or { '' }
	assert ct.starts_with('application/grpc')
	// body is exactly one uncompressed frame carrying the echoed payload
	frames := decode_frames(resp.body.bytes()) or { panic(err) }
	assert frames.len == 1
	assert !frames[0].compressed
	assert frames[0].payload == msg
	// grpc-status: 0 rides in the trailers
	assert (resp.trailers.get_custom('grpc-status') or { '' }) == '0'
}

fn test_grpc_metadata_leading_vs_trailing() {
	mut s := new_test_server()
	resp := s.handle(grpc_request('/echo.Echo/Ok', 'x'.bytes()))
	// set_header -> leading response header; set_trailer -> real h2 trailer
	assert (resp.header.get_custom('x-lead') or { '' }) == 'L'
	assert (resp.trailers.get_custom('x-trail') or { '' }) == 'T'
}

fn test_grpc_server_streaming_fans_out_frames() {
	mut s := new_test_server()
	msg := 'tick'.bytes()
	resp := s.handle(grpc_request('/echo.Echo/Fan', msg))
	assert resp.status_code == 200
	// one request -> three response frames, then grpc-status: 0
	frames := decode_frames(resp.body.bytes()) or { panic(err) }
	assert frames.len == 3
	for f in frames {
		assert f.payload == msg
	}
	assert (resp.trailers.get_custom('grpc-status') or { '' }) == '0'
}

fn test_grpc_client_streaming_reads_every_request_frame() {
	mut s := new_test_server()
	payloads := ['a'.bytes(), 'bb'.bytes(), 'ccc'.bytes()]
	resp := s.handle(grpc_request_multi('/echo.Echo/Ok', payloads))
	// server saw all three request messages (Ok echoes them straight back)
	frames := decode_frames(resp.body.bytes()) or { panic(err) }
	assert frames.len == 3
	assert frames[0].payload == 'a'.bytes()
	assert frames[2].payload == 'ccc'.bytes()
}

fn test_grpc_error_is_trailers_only_with_encoded_message() {
	mut s := new_test_server()
	resp := s.handle(grpc_request('/echo.Echo/Boom', 'x'.bytes()))

	assert resp.status_code == 200 // gRPC failures are still HTTP 200
	assert resp.body == '' // no body -> Trailers-Only fold
	assert (resp.trailers.get_custom('grpc-status') or { '' }) == '3' // invalid_argument
	// unicode message round-trips through percent-encoding
	enc := resp.trailers.get_custom('grpc-message') or { '' }
	assert percent_decode(enc) == 'nope 🚀'
}

fn test_grpc_unknown_procedure_is_unimplemented() {
	mut s := new_test_server()
	resp := s.handle(grpc_request('/echo.Echo/Missing', 'x'.bytes()))
	assert resp.status_code == 200
	assert (resp.trailers.get_custom('grpc-status') or { '' }) == '12' // unimplemented
}

fn grpc_request_with(path string, content_type string, extra map[string]string, body []u8) http.Request {
	mut h := http.new_header()
	h.add(.content_type, content_type)
	for k, v in extra {
		h.add_custom(k, v) or { panic(err) }
	}
	return http.Request{
		method: .post
		url:    path
		header: h
		data:   body.bytestr()
	}
}

fn test_grpc_error_details_ride_in_status_details_bin() {
	mut s := new_test_server()
	resp := s.handle(grpc_request('/echo.Echo/Detail', 'x'.bytes()))
	assert resp.body == ''
	assert (resp.trailers.get_custom('grpc-status') or { '' }) == '9' // failed_precondition
	// the trailer is unpadded base64 of a google.rpc.Status
	bin := resp.trailers.get_custom('grpc-status-details-bin') or { '' }
	assert bin != ''
	assert !bin.contains('=')
	mut padded := bin
	for padded.len % 4 != 0 {
		padded += '='
	}
	mut d := protobuf.Decoder{
		buf: base64.decode(padded)
	}
	mut code := 0
	mut message := ''
	mut type_url := ''
	mut value := []u8{}
	for d.more() {
		field, wt := d.read_tag() or { panic(err) }
		match field {
			1 {
				code = d.read_int32() or { panic(err) }
			}
			2 {
				message = d.read_string() or { panic(err) }
			}
			3 {
				mut any := protobuf.Decoder{
					buf: d.read_bytes() or { panic(err) }
				}
				for any.more() {
					af, awt := any.read_tag() or { panic(err) }
					match af {
						1 { type_url = any.read_string() or { panic(err) } }
						2 { value = any.read_bytes() or { panic(err) } }
						else { any.skip(awt) or { panic(err) } }
					}
				}
			}
			else {
				d.skip(wt) or { panic(err) }
			}
		}
	}
	assert code == 9
	assert message == 'needs a detail'
	assert type_url == 'type.googleapis.com/google.rpc.ErrorInfo'
	assert value == [u8(1), 2, 3, 4]
}

fn test_grpc_error_without_details_has_no_details_bin() {
	mut s := new_test_server()
	resp := s.handle(grpc_request('/echo.Echo/Boom', 'x'.bytes()))
	assert (resp.trailers.get_custom('grpc-status-details-bin') or { 'absent' }) == 'absent'
}

fn test_grpc_non_grpc_content_type_is_http_415() {
	mut s := new_test_server()
	resp := s.handle(grpc_request_with('/echo.Echo/Ok', 'application/json', {},
		encode_frame('x'.bytes(), false)))
	// the spec's answer to a non-gRPC request: a plain HTTP error, no trailers
	assert resp.status_code == 415
	assert (resp.trailers.get_custom('grpc-status') or { 'absent' }) == 'absent'
}

fn test_grpc_unknown_codec_is_unimplemented() {
	mut s := new_test_server()
	for ct in ['application/grpc+json', 'application/grpc+flatbuffers'] {
		resp := s.handle(grpc_request_with('/echo.Echo/Ok', ct, {}, encode_frame('x'.bytes(),
			false)))
		assert resp.status_code == 200
		assert (resp.trailers.get_custom('grpc-status') or { '' }) == '12' // unimplemented
	}
	// bare application/grpc and an explicit +proto both mean proto
	for ct in ['application/grpc', 'application/grpc+proto'] {
		resp := s.handle(grpc_request_with('/echo.Echo/Ok', ct, {}, encode_frame('x'.bytes(),
			false)))
		assert (resp.trailers.get_custom('grpc-status') or { '' }) == '0'
	}
}

fn test_grpc_unknown_compression_is_unimplemented_and_names_identity() {
	mut s := new_test_server()
	resp := s.handle(grpc_request_with('/echo.Echo/Ok', 'application/grpc', {
		'grpc-encoding': 'gzip'
	}, encode_frame('x'.bytes(), false)))
	assert (resp.trailers.get_custom('grpc-status') or { '' }) == '12' // unimplemented
	assert (resp.header.get_custom('grpc-accept-encoding') or { '' }) == 'identity'
	// identity, stated outright, is what we speak
	ok := s.handle(grpc_request_with('/echo.Echo/Ok', 'application/grpc', {
		'grpc-encoding': 'identity'
	}, encode_frame('x'.bytes(), false)))
	assert (ok.trailers.get_custom('grpc-status') or { '' }) == '0'
}

fn test_grpc_compressed_flag_under_identity_is_internal() {
	mut s := new_test_server()
	resp := s.handle(grpc_request_with('/echo.Echo/Ok', 'application/grpc', {},
		encode_frame('x'.bytes(), true)))
	assert (resp.trailers.get_custom('grpc-status') or { '' }) == '13' // internal
}

fn test_grpc_receive_limit_checks_each_message() {
	mut s := new_test_server()
	s.max_receive_bytes = 2
	// the third message is over the limit, so the whole call is refused
	over := s.handle(grpc_request_multi('/echo.Echo/Ok', ['a'.bytes(), 'bb'.bytes(), 'ccc'.bytes()]))
	assert over.status_code == 200
	assert over.body == ''
	assert (over.trailers.get_custom('grpc-status') or { '' }) == '8' // resource_exhausted
	// every message within the limit is served
	ok := s.handle(grpc_request_multi('/echo.Echo/Ok', ['a'.bytes(), 'bb'.bytes()]))
	assert (ok.trailers.get_custom('grpc-status') or { '' }) == '0'
}
