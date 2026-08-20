# ddtrace under wasmer: prove the rust _native data-pipeline module (restored by
# the wasix port) runs in-process, offline.
{
  wheel,
  runPython,
  ...
}: {
  # DDSketch computes + serializes and the trace exporter builder constructs, all
  # without an agent or the network (the sandbox has neither).
  native = runPython {
    name = "ddtrace-native";
    inherit wheel;
    script = ''
      from ddtrace.internal.native import DDSketch, TraceExporterBuilder

      sketch = DDSketch()
      for v in (1.0, 2.0, 3.0, 100.0):
          sketch.add(v)
      proto = sketch.to_proto()
      assert isinstance(proto, (bytes, bytearray)) and len(proto) > 0, len(proto)

      TraceExporterBuilder()
    '';
  };
}
