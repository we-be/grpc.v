module grpc

// Code is a gRPC status code, carried in the grpc-status trailer as an integer.
pub enum Code {
	ok                  = 0
	cancelled           = 1
	unknown             = 2
	invalid_argument    = 3
	deadline_exceeded   = 4
	not_found           = 5
	already_exists      = 6
	permission_denied   = 7
	resource_exhausted  = 8
	failed_precondition = 9
	aborted             = 10
	out_of_range        = 11
	unimplemented       = 12
	internal            = 13
	unavailable         = 14
	data_loss           = 15
	unauthenticated     = 16
}

// code_from_int validates a grpc-status value; the spec reserves 0..16.
pub fn code_from_int(v int) !Code {
	if v < 0 || v > 16 {
		return error('grpc: invalid status code ${v}')
	}
	return unsafe { Code(v) }
}

// Status is an RPC outcome: `ok` plus an empty message means success.
pub struct Status {
pub:
	code    Code
	message string
}

pub fn (s Status) is_ok() bool {
	return s.code == .ok
}
