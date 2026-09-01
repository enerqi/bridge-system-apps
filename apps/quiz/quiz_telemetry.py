"""Tracing helpers for the quiz app.

Everything here degrades to a no-op, so the instrumentation can stay
unconditional in the app code. Two levels of that:

- opentelemetry not installed at all (the `telemetry` extra was not synced):
  the import below falls back to no-op stand-ins.
- opentelemetry installed but no SDK configured (served without
  `--setup quiz_app_telemetry_setup.py`): `trace.get_tracer` returns the API's
  proxy tracer, whose spans do nothing.

Three things this provides that plain `tracer.start_as_current_span` does not:

- `traced` works on `async def` handlers. Used as a decorator,
  `start_as_current_span` is a context manager wrapper, so on a coroutine
  function it ends the span when the *coroutine object is created* rather than
  when it is awaited — an awaited handler is then reported as taking ~0ms.
- `dwell` marks the deliberate pauses that exist so a human can read a
  notification, so read-time is separable from work-time in a trace.
- `PendingWait` covers time the app is blocked on the user: a span that stays
  open across event loop turns, armed when the UI becomes ready for input and
  ended by whichever handler the user eventually triggers.
"""

import asyncio
import functools
import inspect
import time

from contextlib import contextmanager

try:
    from opentelemetry import trace
    from opentelemetry.context import Context
except ImportError:
    # opentelemetry is optional (the `telemetry` extra). Rather than make every
    # call site conditional, stand in no-op versions of the handful of API
    # surfaces used here, so importing this module -- and therefore starting the
    # app -- never depends on opentelemetry being installed.
    from types import SimpleNamespace

    class _NoOpSpanContext:
        is_valid = False

    class _NoOpSpan:
        def set_attribute(self, key, value):
            pass

        def is_recording(self):
            return False

        def get_span_context(self):
            return _NoOpSpanContext()

        def end(self):
            pass

    class _NoOpTracer:
        @contextmanager
        def start_as_current_span(self, name, *args, **kwargs):
            yield _NoOpSpan()

        def start_span(self, name, *args, **kwargs):
            return _NoOpSpan()

    Context = dict
    trace = SimpleNamespace(
        get_tracer=lambda name: _NoOpTracer(),
        get_current_span=_NoOpSpan,
        Link=lambda *args, **kwargs: None,
    )

tracer = trace.get_tracer("quiz_app")


def _apply(span, attributes):
    for key, value in attributes.items():
        if value is not None:
            span.set_attribute(key, value)


def traced(name=None, **attributes):
    """Wrap a handler in a span, awaiting the body first if it is a coroutine."""

    def deco(fn):
        span_name = name or fn.__qualname__

        if inspect.iscoroutinefunction(fn):

            @functools.wraps(fn)
            async def async_wrapper(*args, **kwargs):
                with tracer.start_as_current_span(span_name) as span:
                    _apply(span, attributes)
                    return await fn(*args, **kwargs)

            return async_wrapper

        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            with tracer.start_as_current_span(span_name) as span:
                _apply(span, attributes)
                return fn(*args, **kwargs)

        return wrapper

    return deco


@contextmanager
def span(name, **attributes):
    """A child span for one phase within a handler."""
    with tracer.start_as_current_span(name) as sp:
        _apply(sp, attributes)
        yield sp


def annotate(**attributes):
    """Add attributes to whatever span is currently active."""
    sp = trace.get_current_span()
    if sp.is_recording():
        _apply(sp, attributes)


async def dwell(seconds: float, reason: str, **attributes):
    """`asyncio.sleep` that says why it is sleeping.

    These pauses are pacing for the human reading a notification, not work, so
    they get their own span rather than inflating the handler's own time.
    """
    with span(f"wait.dwell.{reason}", **{"wait.kind": "ui_dwell", "wait.planned_seconds": seconds, **attributes}) as sp:
        start = time.perf_counter()
        await asyncio.sleep(seconds)
        sp.set_attribute("wait.actual_seconds", round(time.perf_counter() - start, 4))


class PendingWait:
    """An open span covering time spent waiting for the user to do something.

    Armed when the UI is ready (question rendered, modal opened, filter box
    being typed into) and closed by the handler the user eventually triggers,
    so it necessarily outlives the span that armed it. That is why it starts as
    its own trace root with a *link* back to the arming span instead of being
    its child: by the time it ends, its would-be parent finished long ago.
    """

    def __init__(self, name: str):
        self._name = name
        self._span = None
        self._start = 0.0

    def arm(self, **attributes):
        """Start waiting. Any previous unanswered wait is closed as superseded."""
        self.close(outcome="superseded")
        links = []
        current = trace.get_current_span().get_span_context()
        if current.is_valid:
            links.append(trace.Link(current))
        self._span = tracer.start_span(
            self._name,
            context=Context(),  # a root: the arming span ends before this one does
            links=links,
            attributes={k: v for k, v in {"wait.kind": "user_input", **attributes}.items() if v is not None},
        )
        self._start = time.perf_counter()

    def close(self, outcome: str = "handled", **attributes) -> float | None:
        """End the wait, returning how long the user took, or None if not armed."""
        if self._span is None:
            return None
        elapsed = round(time.perf_counter() - self._start, 4)
        _apply(self._span, {"wait.outcome": outcome, "wait.seconds": elapsed, **attributes})
        self._span.end()
        self._span = None
        return elapsed

    @property
    def armed(self) -> bool:
        return self._span is not None
