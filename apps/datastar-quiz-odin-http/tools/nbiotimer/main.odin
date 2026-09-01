package nbiotimer

// Does a chained core:nbio timeout keep its interval?
//
//   plain      : timeout -> callback -> timeout, nothing else on the loop
//   with_date  : the same, plus a 1-second repeating timer (what odin-http's date header uses)
//   after_send : the same, but each tick sends a few bytes to itself first and re-arms the timer
//                from the SEND COMPLETION, which is the shape the SSE choreography actually has

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"

INTERVAL :: 100 * time.Millisecond
TICKS :: 12

State :: struct {
	last:   time.Time,
	count:  int,
	gaps:   [TICKS]f64,
	socket: net.TCP_Socket,
	peer:   net.TCP_Socket,
	buffer: [64]u8,
	mode:   string,
}

main :: proc() {
	mode := len(os.args) > 1 ? os.args[1] : "plain"

	err := nbio.acquire_thread_event_loop()
	fmt.assertf(err == nil, "acquire: %v", err)

	state := new(State)
	state.mode = mode
	state.last = time.now()

	if mode == "with_date" || mode == "after_send" {
		nbio.timeout_poly(time.Second, state, on_second)
	}
	if mode == "after_send" {
		listener, listen_error := nbio.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 47654})
		fmt.assertf(listen_error == nil, "listen: %v", listen_error)
		nbio.accept_poly(listener, state, proc(op: ^nbio.Operation, s: ^State) {
			s.peer = op.accept.client
			nbio.recv_poly(s.peer, {s.buffer[:]}, s, proc(_: ^nbio.Operation, s: ^State) {})
		})
		client, dial_error := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = 47654})
		fmt.assertf(dial_error == nil, "dial: %v", dial_error)
		state.socket = client
	}

	nbio.timeout_poly(INTERVAL, state, on_tick)
	nbio.run()

	fmt.printf("%s gaps (ms):", mode)
	for index in 0 ..< state.count {
		fmt.printf(" %.0f", state.gaps[index])
	}
	fmt.println()
}

on_second :: proc(_: ^nbio.Operation, state: ^State) {
	if state.count >= TICKS {
		return
	}
	nbio.timeout_poly(time.Second, state, on_second)
}

on_tick :: proc(_: ^nbio.Operation, state: ^State) {
	now := time.now()
	if state.count < TICKS {
		state.gaps[state.count] = time.duration_milliseconds(time.diff(state.last, now))
		state.count += 1
	}
	state.last = now
	if state.count >= TICKS {
		if state.mode == "after_send" {
			net.close(state.socket)
			net.close(state.peer)
		}
		return
	}

	if state.mode == "after_send" {
		payload := []u8{'x', 'y', 'z'}
		nbio.send_poly(
			state.socket,
			{payload},
			state,
			proc(_: ^nbio.Operation, s: ^State) {
				// The re-arm happens in the SEND completion, exactly as the SSE stream does it.
				nbio.timeout_poly(INTERVAL, s, on_tick)
			},
		)
		return
	}
	nbio.timeout_poly(INTERVAL, state, on_tick)
}
