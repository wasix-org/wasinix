# cv2 under wasmer: exercise real OpenCV ops, not just `import cv2`. This drives
# the core matrix engine, imgproc (colour convert / resize / blur) and the
# imgcodecs PNG path (imencode+imdecode -> proves libpng + zlib linked and run),
# plus the numpy <-> cv::Mat marshalling that the cross-numpy-header cmake fix
# makes correct.
#
# cv2.setNumThreads(0): OpenCV was built with parallel_framework=none, but pin
# single-threaded defensively so no parallel_for path is taken under wasmer.
{
  wheel,
  runPython,
  ...
}: {
  ops = runPython {
    name = "opencv-ops";
    inherit wheel;
    script = ''
      import numpy as np
      import cv2

      cv2.setNumThreads(0)
      print("cv2", cv2.__version__)

      # A small deterministic BGR image.
      rng = np.random.default_rng(0)
      img = rng.integers(0, 256, size=(64, 48, 3), dtype=np.uint8)

      # cvtColor BGR -> GRAY: shape drops the channel axis, dtype stays uint8.
      gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
      assert gray.shape == (64, 48), gray.shape
      assert gray.dtype == np.uint8, gray.dtype

      # resize to a new size (cv2 size is (w, h)).
      small = cv2.resize(img, (24, 32), interpolation=cv2.INTER_AREA)
      assert small.shape == (32, 24, 3), small.shape

      # GaussianBlur runs and preserves shape; a large kernel on noise must
      # actually smooth (reduce variance).
      blur = cv2.GaussianBlur(img, (7, 7), 1.5)
      assert blur.shape == img.shape, blur.shape
      assert blur.dtype == np.uint8
      assert blur.var() < img.var(), (float(blur.var()), float(img.var()))

      # PNG round-trip through the codec: encode to an in-memory PNG buffer,
      # decode it back, assert lossless. Exercises imgcodecs + libpng + zlib.
      ok, buf = cv2.imencode(".png", img)
      assert ok, "imencode failed"
      assert buf[0] == 0x89 and bytes(buf[1:4]) == b"PNG", "not a PNG stream"
      dec = cv2.imdecode(buf, cv2.IMREAD_COLOR)
      assert dec.shape == img.shape, dec.shape
      assert np.array_equal(dec, img), "PNG round-trip mismatch"

      # JPEG XL round-trip: proves the cross-built libjxl (+ highway/brotli/lcms2)
      # links and runs under wasmer. A smooth gradient is near-lossless at JXL's
      # default distance, so the decode matches closely.
      grad = cv2.cvtColor(
          np.tile(np.linspace(0, 255, 48, dtype=np.uint8), (64, 1)),
          cv2.COLOR_GRAY2BGR,
      )
      ok, jbuf = cv2.imencode(".jxl", grad)
      assert ok and len(jbuf) > 0, "jxl imencode failed"
      jdec = cv2.imdecode(jbuf, cv2.IMREAD_COLOR)
      assert jdec is not None and jdec.shape == grad.shape, (
          "jxl decode", None if jdec is None else jdec.shape)
      mad = float(np.mean(np.abs(jdec.astype(int) - grad.astype(int))))
      assert mad < 4.0, mad

      print("opencv ops ok: cvtColor/resize/GaussianBlur + PNG and JPEG XL "
            "imencode/imdecode round-trips")
    '';
  };
}
