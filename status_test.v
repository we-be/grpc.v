module grpc

fn test_code_from_int() {
	assert code_from_int(0)! == .ok
	assert code_from_int(12)! == .unimplemented
	assert code_from_int(16)! == .unauthenticated
	for bad in [-1, 17, 255] {
		if _ := code_from_int(bad) {
			assert false, 'code ${bad} must error'
		}
	}
}

fn test_status_ok() {
	assert Status{}.is_ok()
	assert !Status{
		code:    .internal
		message: 'boom'
	}.is_ok()
}
