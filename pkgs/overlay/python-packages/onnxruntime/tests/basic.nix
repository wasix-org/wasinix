# onnxruntime under wasmer: build a tiny ONNX graph in-process and run real
# inference, not just `import onnxruntime`. A 1-node MatMul (X[1x3] @ W[3x2],
# W = [[1,2],[3,4],[5,6]]) drives the CPU execution provider and the MLAS gemm
# kernel (the wasm-SIMD path on wasi), plus the numpy <-> OrtValue marshalling
# that the cross-numpy-header cmake fix makes correct.
#
# The model is an embedded serialized ONNX protobuf (base64), not built via the
# `onnx` python package: runPython gives the wheel only its own dependency
# closure, and onnxruntime does not depend on onnx, so `import onnx` is
# unavailable in the sandbox. The bytes were produced once with onnx.helper
# (MatMul, opset 17, ir_version 9).
#
# intra/inter_op_num_threads = 1: onnxruntime's threadpool over pthreads is
# pinned single-threaded so no worker-thread path is taken under wasmer.
{
  wheel,
  runPython,
  ...
}: {
  inference = runPython {
    name = "onnxruntime-inference";
    inherit wheel;
    script = ''
      import base64
      import numpy as np
      import onnxruntime as ort

      print("onnxruntime", ort.__version__)
      print("providers", ort.get_available_providers())

      # MatMul(X[1,3], W[3,2]=[[1,2],[3,4],[5,6]]) -> Y[1,2]
      MODEL_B64 = (
          "CAk6agoRCgFYCgFXEgFZIgZNYXRNdWwSBm1hdG11bCojCAMIAhABQgFXShgAAIA/"
          "AAAAQAAAQEAAAIBAAACgQAAAwEBaEwoBWBIOCgwIARIICgIIAQoCCANiEwoBWRIO"
          "CgwIARIICgIIAQoCCAJCBAoAEBE="
      )
      model_bytes = base64.b64decode(MODEL_B64)

      so = ort.SessionOptions()
      so.intra_op_num_threads = 1
      so.inter_op_num_threads = 1

      sess = ort.InferenceSession(
          model_bytes, so, providers=["CPUExecutionProvider"]
      )
      x = np.array([[1.0, 1.0, 1.0]], dtype=np.float32)
      (out,) = sess.run(None, {"X": x})

      expected = np.array([[9.0, 12.0]], dtype=np.float32)
      assert out.shape == (1, 2), out.shape
      assert np.allclose(out, expected), (out, expected)

      print("onnxruntime inference ok: MatMul ->", out.tolist())
    '';
  };
}
