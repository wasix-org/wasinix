# OpenCV core plus the opencv_contrib modules.
# python-packages/opencv4.nix layers the python bindings on this.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileSets,
  dropInputsByName,
  profileOf,
}:
exposeWasixPackage (
  let
    lib = packages.sameProfile.lib;
    lapack = packages.sameProfile.lapack-reference;
    # boost: Boost.Build rejects architecture=wasm (see scipy.nix). glib: no
    # wasip1 ipc_rmid_deferred_release value, so its meson cross file fails eval.
    dropInputs = [
      "boost"
      "glib"
    ];
    dropByName = dropInputsByName dropInputs;
    extraInputs = [
      lapack
      packages.native."wasix-sysroot".profiles.${profileOf packages.sameProfile.stdenv.hostPlatform}.openmp
      packages.sameProfile.freetype
      packages.sameProfile.harfbuzz
      packages.sameProfile.hdf5
    ];
  in
    extendPackage (
      package.override {
        # No wasm backend for windowing toolkits, capture hardware, or IPP's
        # prebuilt x86 binaries; vtk and ogre both need libGL and a window system.
        enableFfmpeg = false;
        enableGStreamer = false;
        enableVA = false;
        enableGtk3 = false;
        enableGPhoto2 = false;
        enableDC1394 = false;
        enableVtk = false;
        enableOvis = false;
        enableIpp = false;

        enableDocs = false;
        # tesseract pulls pango and so glib, dropped above.
        enableTesseract = false;
        enableTbb = false;
        # OPENCV_ENABLE_NONFREE flips meta.license to unfree, which fails to eval.
        enableUnfree = false;
        # LTO archives carry no target_features section, so the EH-profile
        # abiCheck reports "exception-handling feature missing".
        enableLto = false;
        enableContrib = true;
        enablePython = false;
        enableBlas = false;
        enableEigen = true;

        # Cross builds cannot run them, and linking needs unpropagated libsharpyuv.
        runAccuracyTests = false;
        runPerformanceTests = false;

        enableJPEG = true;
        enablePNG = true;
        enableTIFF = true;
        enableWebP = true;
        enableJPEG2000 = true;
        enableJpegXL = true;
        enableEXR = true;
      }
    ) {
      passthru.wasix.supportedProfiles = profileSets.pic;

      # freetype + harfbuzz drive the contrib freetype module, hdf5 the hdf one,
      # libomp the parallel backend; a cross build gets none of them from nixpkgs.
      buildInputs = old: dropByName old ++ extraInputs;
      propagatedBuildInputs = old: dropByName old ++ extraInputs;

      # opencv_contrib's hdf module skips find_package(HDF5) under CMAKE_CROSSCOMPILING.
      postPatch = old:
        old
        + ''
          substituteInPlace opencv_contrib/hdf/CMakeLists.txt \
            --replace-fail "if(NOT CMAKE_CROSSCOMPILING) # iOS build should not reuse OSX package" "if(TRUE)"
        '';

      # The unknown "Wasi" cmake system omits unix-install/opencv4.pc from install().
      postInstall = old:
        ''
          mkdir -p "$out/lib/pkgconfig"
          cp unix-install/opencv4.pc "$out/lib/pkgconfig/opencv4.pc"
        ''
        + old;

      # OPENCL_LIBRARY interpolates ocl-icd, which does not cross-build.
      cmakeFlags = old:
        builtins.filter (f: !(lib.hasInfix "OPENCL_LIBRARY" f)) old
        ++ [
          # No wasm backend: GPU, OS windowing, capture hardware, x86-only IPP/ITT.
          (lib.cmakeBool "WITH_OPENCL" false)
          (lib.cmakeBool "WITH_CUDA" false)
          (lib.cmakeBool "WITH_GTK" false)
          (lib.cmakeBool "WITH_QT" false)
          (lib.cmakeBool "WITH_WIN32UI" false)
          (lib.cmakeBool "WITH_FFMPEG" false)
          (lib.cmakeBool "WITH_GSTREAMER" false)
          (lib.cmakeBool "WITH_V4L" false)
          (lib.cmakeBool "WITH_1394" false)
          (lib.cmakeBool "WITH_GPHOTO2" false)

          # opencv's HAL BLAS at our flang-built reference archives (nixpkgs'
          # enableBlas is openblas-only).
          (lib.cmakeBool "WITH_LAPACK" true)
          (lib.cmakeFeature "LAPACK_IMPL" "Custom")
          (lib.cmakeFeature "LAPACK_LIBRARIES" "${lapack}/lib/libcblas.a;${lapack}/lib/liblapack.a;${lapack}/lib/libblas.a")
          (lib.cmakeFeature "LAPACK_CBLAS_H" "cblas.h")
          (lib.cmakeFeature "LAPACK_LAPACKE_H" "lapacke.h")
          (lib.cmakeFeature "LAPACK_INCLUDE_DIR" "${lapack}/include")
          (lib.cmakeBool "WITH_VA" false)
          (lib.cmakeBool "WITH_VA_INTEL" false)
          (lib.cmakeBool "WITH_ITT" false)
          (lib.cmakeBool "WITH_IPP" false)
          (lib.cmakeBool "WITH_TBB" false)
          (lib.cmakeBool "HIGHGUI_ENABLE_PLUGINS" false)
          (lib.cmakeBool "VIDEOIO_ENABLE_PLUGINS" false)

          (lib.cmakeBool "WITH_OPENMP" true)

          # opencv defaults WITH_EIGEN off under CMAKE_CROSSCOMPILING, so
          # nixpkgs' enableEigen input alone never reaches find_package(Eigen3).
          (lib.cmakeBool "WITH_EIGEN" true)

          # System libtiff's cmake target wants a Deflate::Deflate FindTIFF never makes.
          (lib.cmakeBool "BUILD_TIFF" true)

          (lib.cmakeBool "BUILD_opencv_gapi" true)
          (lib.cmakeBool "BUILD_opencv_world" false)
          (lib.cmakeBool "BUILD_EXAMPLES" false)
          (lib.cmakeBool "BUILD_opencv_apps" false)

          # wasm has no runtime CPU feature dispatch; -msimd128 baseline only.
          (lib.cmakeFeature "CPU_BASELINE" "")
          (lib.cmakeFeature "CPU_DISPATCH" "")
        ];
    }
)
