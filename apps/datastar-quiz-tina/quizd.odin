// The application entry point. `main.odin` beside it is operational setup only -- tracking
// allocator, backtraces, logger -- and hands over here.
package main

import "web"

main_program :: proc() -> (exit_code: int) {
	return web.serve(web.config_from_environment())
}
