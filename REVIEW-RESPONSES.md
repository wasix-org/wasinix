# PR #82 review responses

Current ledger for all 109 inline review threads on PR #82. Threads are grouped
only where they ask the same question. The `r…` labels are GitHub discussion IDs.

Status: **FIXED** means the current branch contains the change. **ANSWERED** means
no code change is warranted. **BLOCKED** means the requested feature needs an
unavailable platform capability or an unported dependency.

## Toolchain and wiring

- **FIXED** [r3673289319](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673289319), [r3673290714](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673290714), [r3704081060](https://github.com/wasix-org/wasinix/pull/82#discussion_r3704081060): flang-rt and OpenMP tests are per profile, so the redundant `flangRtByProfile` and `openmpByProfile` buildable re-exports were removed. The Fortran smoke test now uses each profile's `wasixflang`, including PIC. Wasmer runs every encoding except legacy EH; the legacy OpenMP case remains link-only because Wasmer cannot execute the legacy `try` opcode.
- **FIXED** [r3673303919](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673303919): library tests are exposed through `passthru.tests` and collected through the same path as shipped-package and toolchain tests.
- **FIXED** [r3673297999](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673297999): exact matching is `dropInputsByName`; substring matching is the explicitly named `dropInputsByNameInfix`.

## DuckDB

- **FIXED** [r3672571867](https://github.com/wasix-org/wasinix/pull/82#discussion_r3672571867), [r3684875067](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684875067), [r3684877777](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684877777): `tzname` and the other libc gaps were fixed, ICU is enabled, and the comments no longer claim ICU is unavailable.
- **FIXED** [r3673340055](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673340055), [r3673340976](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673340976): `mlock`, `madvise`, `sched_getcpu`, `sched_getaffinity`, and the required declarations are supplied by the vendored wasix-libc patch; the package guards were removed.
- **FIXED** [r3673350797](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673350797): the dangling “These” comment was removed.
- **FIXED** [r3673325902](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673325902): the stale no-dlopen patch was removed. PIC is required for DuckDB's exceptions and dynamic-loading headers, not because WASIX lacks dynamic linking.
- **ANSWERED** [r3673384613](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673384613): `DUCKDB_EXPLICIT_PLATFORM` avoids executing a just-built wasm probe on the build host. DuckDB query parallelism uses threads and remains enabled; process support is unrelated.
- **FIXED** [r3684898722](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684898722): cross-interpreter headers are exposed as `python.crossIncludeDir` and NumPy's `passthru.crossInclude`.

## HDF5 and date

- **FIXED / BLOCKED** [r3673421485](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673421485): HDF5 C++ and szip/libaec support are enabled. MPI remains blocked on an MPI runtime, process launch, and networking support.
- **FIXED / BLOCKED** [r3673450986](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673450986): the file-locking constants are exposed by wasix-libc, so the HDF5 source patch was removed. Lock operations return `ENOSYS` instead of falsely succeeding: WASIX supports multiple processes, while Wasmer has no shared record-lock operation yet. The h5py test explicitly disables HDF5 locking; real locking requires an upstream Wasmer ABI and filesystem implementation.
- **FIXED** [r3703679749](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703679749): the redundant HDF5 option was removed; nixpkgs' override already enables the feature.
- **ANSWERED** [r3673462913](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673462913): date uses `USE_SYSTEM_TZ_DB` and runtime zoneinfo; its timezone library is not disabled. The removed nixpkgs patch only embedded a cross-unbuildable tzdata store path.
- **FIXED** [r3673474575](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673474575): the reviewer was right that the last CMake definition wins; the filter of the earlier `BUILD_SHARED_LIBS` definition was removed.
- **FIXED** [r3703808719](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703808719): the zoneinfo patch is removed through `dropPatchesByNameInfix`.

## Fortran and LAPACK

- **FIXED** [r3673513575](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673513575), [r3673532209](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673532209), [r3673541741](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673541741), [r3673554101](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673554101): `wasixflang` owns the target/profile flags, link driver, sysroot, and flang-rt linkage. LAPACK consumes that compiler normally and propagates flang-rt for downstream static links.
- **FIXED** [r3703688889](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703688889), [r3703692844](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703692844), [r3703695100](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703695100), [r3703697477](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703697477), [r3703701641](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703701641), [r3703716345](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703716345): the per-consumer profile lookup, flag lists, probe variables, vacuous comments, and manual link machinery were removed in favor of `wasixflang`.
- **FIXED** [r3673560586](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673560586), [r3703700361](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703700361): CBLAS and LAPACKE use nixpkgs' enabled defaults. Only shared libraries and cross-unrunnable upstream tests are disabled.
- **ANSWERED** [r3673596254](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673596254): `FortranCInterface_VERIFY` makes CMake link the mixed probe with the C driver, which omits flang-rt. Normal compiler detection now succeeds through `wasixflang`; only that broken verification call is omitted.
- **FIXED** [r3673619387](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673619387): support is described in terms of the PIC relocations flang emits, not a tautological EH explanation.
- **ANSWERED** [r3673651453](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673651453): the smoke test uses `$PKG_CONFIG`, which is nixpkgs' target-prefixed pkg-config wrapper in a cross build; bare `pkg-config` would query build-platform paths.
- **FIXED** [r3703711122](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703711122): the patch-time comment insertion was removed.

## Image and media libraries

- **FIXED** [r3673670168](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673670168): libjxl builds JPEG transcode, OpenEXR support, tools, benchmarks, examples, devtools, sjpeg, manpages, and API docs. JNI and tcmalloc remain off for concrete platform/dependency reasons.
- **FIXED** [r3673681294](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673681294), [r3690802316](https://github.com/wasix-org/wasinix/pull/82#discussion_r3690802316): libjxl input/output filtering uses the shared drop helpers.
- **FIXED** [r3673704204](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673704204): libsndfile builds FLAC, Ogg/Vorbis, Opus, LAME, and mpg123. ALSA remains unavailable because WASIX has no Linux sound device.
- **FIXED** [r3703814864](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703814864): libhwy contrib is enabled; its wasm/Emscripten conflation is patched instead of disabling contrib.
- **FIXED** [r3675302750](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675302750): OpenCV's affinity workaround was removed after implementing `sched_getaffinity`/`sched_getcpu` in wasix-libc.
- **FIXED** [r3675356408](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675356408): OpenCV uses the array-valued drop helper.
- **FIXED** [r3675496272](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675496272), [r3675505346](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675505346): `opencv4.pc` is copied unconditionally from CMake's known `unix-install/opencv4.pc`; there is no guard, search, or empty fallback.
- **FIXED / ANSWERED** [r3675538343](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675538343): BLAS/LAPACK, contrib, Eigen, Python bindings, and the viable codecs are enabled. LTO remains off because bitcode archives lose the `target_features` data required by the profile ABI check. Hardware/windowing integrations retain their platform blockers.
- **FIXED** [r3703764152](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703764152): OpenCV OpenEXR support is enabled.
- **FIXED** [r3683920360](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683920360): the cv2-only cross Python/NumPy include override remains in the Python binding layer, with the build-host-vs-target-header reason stated.
- **ANSWERED** [r3683718387](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683718387): soundfile creates `_soundfile_data/__init__.py` because its loader reads the package's `__file__`; a namespace package has none. The comment now states that constraint directly.
- **FIXED / BLOCKED** [r3704011898](https://github.com/wasix-org/wasinix/pull/82#discussion_r3704011898): Pillow now includes lcms2 and libraqm. libavif is blocked by its glib chain, libimagequant by cargo-c's unsupported wasi-p1 target, and libxcb by its Meson platform checks. Function replacements use the repository's `_:` convention.

## ONNX and ONNX Runtime

- **FIXED / ANSWERED** [r3673837794](https://github.com/wasix-org/wasinix/pull/82#discussion_r3673837794): standalone training APIs are enabled in the C++ build. The Python-binding build uses ONNX Runtime's mutually exclusive full-training route; distributed training still requires unavailable MPI/NCCL.
- **ANSWERED** [r3675269789](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675269789): wasix dyld defines `dlopen`, `dlsym`, and `dlclose`, but not `dladdr`. The static single-provider build needs no sibling provider path, so `GetRuntimePath` uses its existing fallback. The missing dyld API is tracked as the upstream fix.
- **FIXED** [r3675275161](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675275161): this never disabled threading. The patch now only changes the Emscripten preprocessor test and lets WASIX use libc's `sched_getcpu` generic branch.
- **ANSWERED** [r3675280182](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675280182): shared provider libraries conflict with the static Python-module link; cpuinfo has no wasm backend; LTO loses the object feature metadata checked by `abiCheck`.
- **ANSWERED** [r3675295225](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675295225): CUDA/NCCL/ROCm/CoreML/OpenVINO are hardware or host-OS execution providers. Full protobuf is broken upstream by duplicate `onnx-ml.proto`; Python support is layered per interpreter because ONNX Runtime's pybind module is not abi3.
- **FIXED** [r3703745202](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703745202): `postPatch` is now a function because it appends to the upstream phase; it is no longer a function that merely replaces the old value.
- **ANSWERED** [r3683986737](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683986737): NumPy headers belong to the per-interpreter Python binding build, not the Python-free C++ package.
- **FIXED** [r3684016029](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684016029): the ONNX comment now explains that native nixpkgs can execute its selected Python build frontend while the cross set needs build-host PyPA tools.
- **FIXED** [r3684673626](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684673626): ONNX uses `libTweaks`, shared input helpers, and the central build-host PyPA helper.
- **ANSWERED** [r3703731390](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703731390): ONNX's setup.py shlex-splits the inherited leading-space linker value. Its normalized `NIX_CFLAGS_LINK` is package-specific; changing the global toolchain value would alter every link.
- **FIXED** [r3703729196](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703729196), [r3703733310](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703733310): ONNX uses the shared PyPA and cross-include helpers.
- **ANSWERED** [r3703980015](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703980015): upstream ONNX sets `Py_LIMITED_API=0x030C0000`, marks the extension limited-API, and emits a `cp312-abi3` wheel. Reusing one artifact across py313/py314 is the ABI contract; rebuilding per interpreter could publish differing bytes under the same filename. Both interpreter import tests exercise it.

## Protobuf, SentencePiece, and ZeroMQ

- **ANSWERED** [r3675561869](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675561869): WASIX fork is available through asyncify in `off`; protobuf is PIC/EH because it links into extension modules, where protoc's exception-using plugin runner cannot use that route. Native protoc remains the correct cross tool.
- **ANSWERED** [r3675570373](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675570373): `$build_protobuf` is selected in the build shell and is not an evaluation-time Nix path, so `WITH_PROTOC` is appended in `preConfigure`.
- **ANSWERED** [r3675609782](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675609782): SentencePiece vendors protobuf-lite into its own static archive; there is no external protobuf-lite pkg-config dependency to provide.
- **FIXED** [r3683776765](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683776765): setup.py is patched to honor `$PKG_CONFIG`; the former staging-directory workaround was removed.
- **FIXED** [r3703908841](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703908841): the redundant explicit SentencePiece build input was removed; propagation already supplies it.
- **FIXED** [r3675675883](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675675883): `nice()` and the scheduler calls are supplied by the wasix-libc patch; ZeroMQ's source workaround was removed.

## Python cross helpers and mechanical cleanup

- **FIXED** [r3675843924](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675843924): NumPy's target include path is `numpy.passthru.crossInclude`; the interpreter header path is `python.crossIncludeDir`.
- **ANSWERED** [r3675860103](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675860103): nixpkgs' cross Python set puts target pip/wheel/setuptools into `nativeBuildInputs`; the central `buildHostPypaTools`/`buildHostPypaBuild` helpers correct that splice.
- **FIXED** [r3703803051](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703803051): the non-package-specific Python helpers moved from the wheel overlay into `pkgs/lib/python.nix`.
- **FIXED** [r3683848067](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683848067): the WASIX compiler is declared as Clang in the cross stdenv.
- **FIXED** [r3683878821](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683878821): psycopg2 uses `libTweaks`; replacing upstream `postPatch` is explicit because both implementations rewrite the same assignment.
- **FIXED** [r3684678005](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684678005), [r3684681988](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684681988), [r3683885310](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683885310), [r3683703950](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683703950), [r3684900899](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684900899): vacuous “the patch will fail on an update” comments were removed from NumPy, murmurhash, preshed, srsly, and cymem.
- **FIXED** [r3684688237](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684688237), [r3704015286](https://github.com/wasix-org/wasinix/pull/82#discussion_r3704015286), [r3704015983](https://github.com/wasix-org/wasinix/pull/82#discussion_r3704015983), [r3704019630](https://github.com/wasix-org/wasinix/pull/82#discussion_r3704019630): Hugging Face Hub, psycopg2, and pyopenssl use the shared document/output helpers.
- **FIXED** [r3684698811](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684698811): typer is no longer dropped; shellingham is packaged and the comment was shortened to its constraint.
- **FIXED** [r3684851509](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684851509): hf-xet's repeated sed blocks became one uniform browser-vs-WASI cfg rewrite and the comments were shortened.
- **FIXED** [r3684871845](https://github.com/wasix-org/wasinix/pull/82#discussion_r3684871845): debugpy uses the function form only where it deliberately replaces the upstream phase.
- **FIXED** [r3703970457](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703970457): NumPy's self-reference is expressed as an explicit `lib.fix`; the output path in `passthru.crossInclude` genuinely requires the fixpoint.

## Python package-specific answers

- **FIXED** [r3675748546](https://github.com/wasix-org/wasinix/pull/82#discussion_r3675748546): h5py's comment now says the build-host probe cannot load a static wasm HDF5 archive; it no longer claims WASIX lacks dlopen.
- **FIXED** [r3676175646](https://github.com/wasix-org/wasinix/pull/82#discussion_r3676175646): the h5py header comment was shortened.
- **ANSWERED** [r3676070564](https://github.com/wasix-org/wasinix/pull/82#discussion_r3676070564): WASIX has signals, but Rust's `signal_hook` selects only `cfg(unix)` and the target is not `cfg(unix)`. CPython owns SIGINT for this extension; Wasmer's in-flight syscall cancellation limitation is tracked.
- **ANSWERED** [r3676148680](https://github.com/wasix-org/wasinix/pull/82#discussion_r3676148680): Rust std's `read_exact_at` is `cfg(unix)` and the WASI equivalent is unstable; `libc::pread` is the stable positional-read implementation.
- **ANSWERED** [r3683854732](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683854732): the old WASIX-only gate was needed while overrides leaked into the build interpreter; the Python-set wiring now isolates them and the obsolete helper is gone.
- **FIXED** [r3683862050](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683862050): wheel helpers are threaded through package call arguments; package files no longer import the helper module manually.
- **ANSWERED** [r3683872280](https://github.com/wasix-org/wasinix/pull/82#discussion_r3683872280): target `pg_config` is wasm and cannot execute on the builder; native `pg_config` reports native paths. The native wrapper reports target include/lib paths and delegates non-path queries.

## hf-xet lockfile

- **FIXED** [r3703819914](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703819914): the redundant regenerated lock and custom vendor override were removed. The shared Rust vendor patching applies the `mio` WASIX patch, injects its `wasix` dependency into the vendor, and amends the source lock consistently.

## PyArrow

- **FIXED** [r3703842886](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703842886), [r3703852027](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703852027): input replacement uses the shared exact/infix drop helpers.
- **FIXED / BLOCKED** [r3703855002](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703855002), [r3703857661](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703857661): Arrow compute, filesystem, CSV, JSON, Acero, Dataset, Parquet encryption, and the available zlib/zstd/lz4/snappy codecs are enabled. HDFS needs a JVM/libhdfs, Flight needs the unported C++ gRPC stack, Gandiva needs LLVM JIT, ORC needs the unported ORC C++ library, and S3/GCS/Azure need their unported C++ SDKs. CUDA is a hardware backend. Substrait remains off with its additional protobuf surface until it has a consumer.

## scikit-learn and SciPy

- **FIXED** [r3703866198](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703866198), [r3703880858](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703880858): OpenMP selection and flags are supplied by the profile toolchain; the per-consumer compiler/profile machinery and Meson substitution were removed.
- **FIXED** [r3703867319](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703867319), [r3703867807](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703867807): scikit-learn input filtering uses shared helpers.
- **FIXED** [r3703874180](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703874180): the manual update-verification note was removed; patch application and behavioural CI tests are the checks.
- **FIXED** [r3703886267](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703886267), [r3703887034](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703887034): SciPy flag/input filtering uses shared helpers; the obsolete gfortran removal disappeared with the toolchain fix.
- **FIXED** [r3703893771](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703893771), [r3703896858](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703896858), [r3703898609](https://github.com/wasix-org/wasinix/pull/82#discussion_r3703898609): manual patch-drift notes were removed. The patches fail if stale and the CI runtime cases verify the ABI behavior.

## Validation

- All changed derivations evaluate: PIC flang-rt smoke, OpenCV, ONNX Runtime,
  py314 PyArrow, and the PyArrow Dataset runtime test.
- The py314 hf-xet wheel builds successfully with the shared vendor patching and
  upstream lock; its frozen source/vendor lock consistency check passes.
- The expanded Arrow C++ build completed remotely. The combined OpenCV, ONNX
  Runtime, PyArrow, and flang check was stopped during an uncached LLVM rebuild;
  the session log is `/tmp/review-fixes-build.log`.
