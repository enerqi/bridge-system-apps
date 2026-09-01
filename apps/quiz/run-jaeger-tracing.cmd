rem support OTLP, ports 4317 + 4318
rem pip install opentelemetry-exporter-otlp-proto-http
rem pip install opentelemetry-exporter-otlp-proto-grpc

docker run --name jaeger ^
  -e COLLECTOR_ZIPKIN_HTTP_PORT=9411 ^
  -p 4317:4317 ^
  -p 4318:4318 ^
  -p 16686:16686 ^
  -p 9411:9411 ^
  jaegertracing/all-in-one:1.74.0
