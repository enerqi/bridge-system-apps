"""quiz_app_telemetry_setup

Optional script to setup opentelemetry at application startup time. Do not want to rerun this within the main script,
but can import as a side module or use the one time panel setup option, e.g:

> panel serve --setup quiz_app_telemetry_setup.py ...

Currently this uses manual OTEL instrumentation instead of the opentelemetry-instrument binary (which has awkward
zombie process like issues on Windows at least).

The opentelemetry-distro package includes `opentelemetry-bootstrap` hints at what could be auto instrumented.

Reminder OTEL can use environment variables to setup many parameters.

The TornadoIntrumenter captures normal http requests to Tornado.
Any websocket traffic is invisible, no official python instrumentors, must be manual.
Most http requests are for static resource like requests for html/css/js
However, can add manual `tracer.start_as_current_span` spans for specific event handlers and view generators

Do we have a transaction context?
Seems YES, but...the web socket session seems to be a single transaction, so can get very long traces:
    e.g. 6 minutes, 570 spans
    /blahapp/ws endpoint transaction, or perhaps loses the /ws start, maybe  shows the /ws when transaction closed out

Possible that not all backends are good at streaming in progress traces.
"""


from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.asyncio import AsyncioInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.instrumentation.tornado import TornadoInstrumentor
from opentelemetry.instrumentation.threading import ThreadingInstrumentor
from opentelemetry.instrumentation.urllib3 import URLLib3Instrumentor
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter


resource = Resource.create(attributes={
    SERVICE_NAME: "py-panel-app-test"
})

trace.set_tracer_provider(TracerProvider(resource=resource))
trace.get_tracer_provider().add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
trace.get_tracer_provider().add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))

AsyncioInstrumentor().instrument()
RequestsInstrumentor().instrument()
TornadoInstrumentor().instrument()
ThreadingInstrumentor().instrument()
URLLib3Instrumentor().instrument()


# what about clean shutdown of telemetry? or just streaming on best efforts
