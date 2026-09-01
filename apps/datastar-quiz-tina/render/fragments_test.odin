// The fragment writers, where a returned empty string is a CONTRACT rather than an accident.
package render

import "../engine"
import "core:testing"

// `web/stream.odin` drops an empty payload rather than pushing it, because Tina's Datastar SDK
// refuses one and the handler closes on the error -- which truncates the stream silently. The
// trailing beat of a correct answer's script is exactly this shape (`Toast{text = "", pause = 1.0}`,
// the pause the python's panel handler took before moving on), so a change here that made an empty
// toast render an EMPTY WRAPPER would put the bug back: the div would be pushed, the pause honoured,
// and the player would read a blank notification.
@(test)
test_a_toast_with_no_text_renders_nothing :: proc(t: ^testing.T) {
	beat := engine.Toast {
		kind  = "info",
		text  = "",
		pause = 1.0,
	}
	testing.expect_value(t, toast(beat, context.temp_allocator), "")

	spoken := engine.Toast {
		kind = "success",
		text = "Correct!",
	}
	testing.expect(t, toast(spoken, context.temp_allocator) != "", "a toast with text must render")
}

// The floater has the same contract, and `routes.odin` has always guarded it -- pin it so the two
// stay the same shape.
@(test)
test_a_floater_with_no_number_renders_nothing :: proc(t: ^testing.T) {
	testing.expect_value(t, floater(engine.Toast{kind = "info", text = "Correct!"}, false, context.temp_allocator), "")
	testing.expect(
		t,
		floater(engine.Toast{kind = "info", text = "+4!"}, false, context.temp_allocator) != "",
		"a toast naming points must float them",
	)
}
