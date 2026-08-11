# Python wheels wasinix ships (nixpkgs python3.pkgs attr names); drives the
# pythonWheels targets and import smoke-tests. Entry: {attr, pyImport ? nixpkgs'
# pythonImportsCheck, skipTest, noarch = build once for packages shipping no
# python code, publishOnce = publish the default interpreter's ABI3 artifact,
# variants = the interpreters to build on, default all}.
# Fixes in <attr>.nix, tests in <attr>/tests/, docs/packaging.md.
[
  # ── pure-python (no C extension) ───────────────────────────────────────────────
  {attr = "six";}
  {attr = "idna";}
  {attr = "certifi";}
  {attr = "urllib3";}
  {attr = "packaging";}
  {attr = "pyparsing";}
  {
    attr = "attrs";
    pyImport = "attr";
  }
  {attr = "sniffio";}
  {
    attr = "typing-extensions";
    pyImport = "typing_extensions";
  }
  {
    attr = "typing-inspection";
    pyImport = "typing_inspection";
  }
  {attr = "pycparser";}
  {
    attr = "annotated-types";
    pyImport = "annotated_types";
  }
  {attr = "pytz";}
  {attr = "tzdata";}
  {
    attr = "python-dateutil";
    pyImport = "dateutil";
  }
  {attr = "cycler";}
  {attr = "outcome";}
  {
    attr = "dnspython";
    pyImport = "dns";
  }
  {
    attr = "zope-event";
    pyImport = "zope.event";
  }
  {
    attr = "async-timeout";
    pyImport = "async_timeout";
  }
  {attr = "aiohappyeyeballs";}
  {attr = "qrcode";}
  {attr = "sqlalchemy";}
  {attr = "requests";}
  {attr = "aiojobs";}
  {attr = "aioresponses";}
  {attr = "bytecode";}
  {attr = "pydantic";}
  {
    attr = "pyopenssl";
    pyImport = "OpenSSL";
  }
  {
    attr = "pypng";
    pyImport = "png";
  }
  {attr = "greenback";}
  {attr = "chardet";}
  {attr = "chardet_5";}
  {attr = "tomli";}
  {attr = "pytokens";}
  {attr = "black";} # mypyc speedups optional; ships a pure fallback
  {attr = "thrift";} # fastbinary C accelerator optional; pure fallback
  {attr = "envier";} # overlay/python-packages/envier.nix (not in nixpkgs; ddtrace's config lib)
  {attr = "eventlet";} # needs the stdlib ssl module (greendns imports it)
  {
    attr = "psycopg-pool";
    pyImport = "psycopg_pool";
  }
  {
    attr = "watchdog";
    # pure on non-macOS; wasix has no inotify, the polling observer is the
    # usable path, so the smoke-test imports it directly.
    pyImport = "watchdog.observers.polling";
  }
  {
    attr = "protobuf";
    # the compiled upb backend: a clean import proves the .so loads (the pure
    # `google.protobuf` would silently fall back to the python impl).
    pyImport = "google._upb._message";
  }
  {
    attr = "protobuf6";
    # for consumers whose lockfile caps protobuf<7. nixpkgs carries the major
    # as its own attr, so this is a family attr, not a history.json entry.
    pyImport = "google._upb._message";
  }
  {
    attr = "protobuf5";
    pyImport = "google._upb._message";
  }
  {
    attr = "protobuf4";
    # 4.x builds the C++ extension rather than upb, and that extension does not
    # link (WASIX-TODO.md), so this is nixpkgs' own check that
    # --cpp_implementation took effect, one step short of loading it.
    pyImport = "google.protobuf.internal._api_implementation";
  }

  {attr = "boto3";}
  {attr = "botocore";}
  {attr = "jmespath";}
  {attr = "s3transfer";}
  {attr = "pytest";}
  {attr = "pytest_9_0";}
  {attr = "pytest_8_3";}
  {attr = "pytest_7";}
  {attr = "pluggy";}
  {attr = "iniconfig";}
  {attr = "beautifulsoup4";} # imports bs4 (nixpkgs pythonImportsCheck)
  {
    attr = "soupsieve";
    # imports bs4 at top level, absent from its own closure; the beautifulsoup4
    # test above already exercises this cross build (bs4 pulls soupsieve).
    skipTest = true;
  }
  {attr = "more-itertools";}
  {attr = "tomlkit";}
  {attr = "exceptiongroup";}
  {attr = "cachetools";}
  {attr = "pyasn1";}
  {attr = "pyasn1-modules";}
  {attr = "oauthlib";}
  {attr = "requests-oauthlib";}
  {attr = "h11";}
  {attr = "httpcore";}
  {attr = "httpx";}
  {attr = "anyio";}
  {attr = "starlette";}
  {attr = "fastapi";}
  {attr = "click";}
  {attr = "pygments";}
  {attr = "mdurl";}
  {attr = "markdown-it-py";} # imports markdown_it
  {attr = "rich";}
  {attr = "colorama";}
  {attr = "wcwidth";}
  {attr = "decorator";}
  {attr = "sortedcontainers";}
  {attr = "docutils";}
  {
    attr = "websocket-client";
    pyImport = "websocket";
  }
  {attr = "openpyxl";}
  {attr = "et-xmlfile";}
  {attr = "networkx";}
  {attr = "werkzeug";}
  {attr = "redis";}
  {attr = "prompt-toolkit";}
  {attr = "pytest-asyncio";}
  {attr = "pytest-asyncio_0";}
  {attr = "rsa";}
  {attr = "textual";}

  # ── C extensions with no external C library ────────────────────────────────────
  {attr = "cffi";} # overlay/python-packages/cffi.nix (libffi ffi_closure_alloc)
  {attr = "argon2-cffi-bindings";} # cffi + vendored argon2 C; imports _argon2_cffi_bindings
  {
    attr = "ruamel-yaml-clib";
    # the _ruamel_yaml module init imports the ruamel.yaml companion, absent from
    # a standalone closure; ruamel.yaml consumers exercise the load.
    skipTest = true;
  }
  {attr = "debugpy";}
  {attr = "markupsafe";}
  {attr = "msgpack";}
  {attr = "regex";}
  {attr = "kiwisolver";}
  {attr = "multidict";}
  {attr = "yarl";}
  {attr = "propcache";}
  {attr = "frozenlist";}
  {attr = "aiosignal";}
  {attr = "xxhash";}
  {
    attr = "pycryptodome";
    pyImport = "Crypto";
  }
  {
    attr = "pycryptodomex";
    pyImport = "Cryptodome";
  }
  {
    attr = "charset-normalizer";
    pyImport = "charset_normalizer";
  }
  {attr = "tornado";} # tornado/speedups.c (websocket xor masking); overlay/python-packages/tornado.nix (no abi3, per-interpreter)
  {attr = "greenlet";}
  {attr = "gevent";} # overlay/python-packages/gevent.nix (embedded libev, no libuv/c-ares)
  {attr = "uvloop";} # libuv; overlay/packages/libuv/package.nix
  {
    attr = "zope-interface";
    pyImport = "zope.interface";
  }
  {attr = "caio";}
  {attr = "psutil";} # overlay/python-packages/psutil (the linux backend minus what wasix lacks)
  {attr = "peewee";}
  {attr = "fastavro";}
  {attr = "zstandard";}
  {attr = "brotlicffi";}
  {
    attr = "cython";
    pyImport = "Cython";
  }
  {
    attr = "clickhouse-connect";
    pyImport = "clickhouse_connect";
  }
  {attr = "mmh3";}
  {attr = "msgspec";}
  {attr = "pybase64";}
  {attr = "setproctitle";} # no prctl and no argv to rewrite; falls back to its no-op pure module
  {attr = "ijson";} # the pure default backend; the C one needs yajl
  {attr = "tree-sitter";} # vendored tree-sitter core
  # grammars: a generated parser.c per language, no dep beyond the core above.
  {attr = "tree-sitter-bash";}
  {attr = "tree-sitter-c-sharp";}
  {attr = "tree-sitter-embedded-template";}
  {attr = "tree-sitter-html";}
  {attr = "tree-sitter-javascript";}
  {attr = "tree-sitter-json";}
  {attr = "tree-sitter-markdown";}
  {attr = "tree-sitter-python";}
  {attr = "tree-sitter-rust";}
  {attr = "tree-sitter-sql";}
  {attr = "tree-sitter-yaml";}
  # overlay/python-packages/tree-sitter-grammars (the ones nixpkgs lacks)
  {attr = "tree-sitter-c";}
  {attr = "tree-sitter-cpp";}
  {attr = "tree-sitter-css";}
  {attr = "tree-sitter-elixir";}
  {attr = "tree-sitter-fortran";}
  {attr = "tree-sitter-go";}
  {attr = "tree-sitter-groovy";}
  {attr = "tree-sitter-java";}
  {attr = "tree-sitter-julia";}
  {attr = "tree-sitter-kotlin";}
  {attr = "tree-sitter-lua";}
  {attr = "tree-sitter-objc";}
  {attr = "tree-sitter-php";}
  {attr = "tree-sitter-powershell";}
  {attr = "tree-sitter-regex";}
  {attr = "tree-sitter-scala";}
  {attr = "tree-sitter-swift";}
  {attr = "tree-sitter-toml";}
  {attr = "tree-sitter-typescript";}
  {attr = "tree-sitter-verilog";}
  {attr = "tree-sitter-xml";}
  {attr = "tree-sitter-zig";}
  {attr = "ujson";} # vendored double-conversion; -lstdc++ mapped by wasixcc
  {attr = "bitarray";}
  {attr = "ciso8601";}
  {attr = "crc32c";}
  {attr = "crcmod";}
  {attr = "cytoolz";} # cython over toolz
  {attr = "hiredis";}
  {attr = "maxminddb";}
  {attr = "optree";} # pybind11; keras' pytree backend
  {attr = "pyroaring";}
  {attr = "time-machine";}
  {attr = "zopfli";}
  {attr = "asyncpg";}
  {attr = "bitstruct";}
  {attr = "cwcwidth";}
  {attr = "editdistance";}
  {attr = "forbiddenfruit";}
  {attr = "geoarrow-c";}
  {attr = "json-stream-rs-tokenizer";}
  {attr = "pyahocorasick";}
  {attr = "pyclipper";}
  {attr = "pyiceberg";}
  {attr = "pyinstrument";}
  {attr = "pyjson5";}
  {attr = "python-crfsuite";}
  {attr = "traits";}
  {attr = "yappi";}
  {attr = "zope-proxy";}
  {attr = "google-re2";} # re2 + abseil; overlay/python-packages/google-re2.nix
  {attr = "onigurumacffi";}
  {attr = "pycocotools";}
  {attr = "bottleneck";}
  {
    attr = "python-rapidjson";
    pyImport = "rapidjson";
  } # overlay/packages/rapidjson.nix
  {attr = "aiokafka";}
  {attr = "backports-datetime-fromisoformat";}
  {attr = "biopython";}
  {attr = "cftime";}
  {attr = "dependency-injector";}
  {attr = "ephem";}
  {attr = "immutables";}
  {attr = "lmdb";}
  {attr = "lru-dict";}
  {attr = "marisa-trie";}
  {attr = "mutf8";}
  {attr = "mwparserfromhell";}
  {attr = "pystemmer";}
  {attr = "zlib-ng";}
  {attr = "pymongo";} # optional bson C speedups, vendored
  # spaCy's cython C++ support libs; each drops a hand-added host include (cymem.nix).
  {attr = "cymem";}
  {attr = "murmurhash";}
  {attr = "preshed";}
  {attr = "srsly";}
  # both ship a pure fallback upstream, so target the compiled module.
  {
    attr = "simplejson";
    pyImport = "simplejson._speedups";
  }
  {
    attr = "coverage";
    pyImport = "coverage.tracer";
  }
  {
    attr = "cbor2";
    # the Rust accelerator is the submodule cbor2._cbor2, not a top-level _cbor2.
    pyImport = "cbor2";
  }
  {attr = "lazy-object-proxy";}
  {
    attr = "rapidfuzz";
    pyImport = "rapidfuzz.fuzz";
  } # scikit-build-core + C++20; overlay/python-packages/rapidfuzz.nix

  # ── meson-built wheels ─────────────────────────────────────────────────────────
  {attr = "contourpy";}
  {attr = "numpy";} # overlay/python-packages/numpy.nix (BLAS-less)
  {attr = "pandas";}
  {
    attr = "matplotlib";
    pyImport = "matplotlib.pyplot";
  } # overlay/python-packages/matplotlib.nix
  {
    attr = "scipy";
    # scipy.linalg loads _fblas/_flapack, exercising the reference BLAS link.
    pyImport = "scipy.linalg";
  } # lapack-reference + flang-rt; overlay/python-packages/scipy.nix
  {
    attr = "scikit-learn";
    # sklearn.cluster loads the OpenMP-parallel KMeans extension.
    pyImport = "sklearn.cluster";
  } # libomp; overlay/python-packages/scikit-learn
  {
    attr = "statsmodels";
    # statsmodels.api pulls the compiled extensions, which cimport
    # scipy.linalg.cython_blas/cython_lapack.
    pyImport = "statsmodels.api";
  }

  # ── C extensions linking a C library already in the overlay ────────────────────
  # import targets reach the compiled module so the smoke-test exercises the .so.
  {
    attr = "pyyaml";
    # only yaml._yaml proves libyaml linked; plain `yaml` has a pure fallback.
    pyImport = "yaml._yaml";
  } # libyaml
  {
    attr = "pillow";
    pyImport = "PIL.Image";
  } # overlay/python-packages/pillow.nix
  {
    attr = "lxml";
    pyImport = "lxml.etree";
  } # libxml2 + libxslt
  {
    attr = "lz4";
    pyImport = "lz4.frame";
  } # lz4
  {attr = "pycurl";} # curl; overlay/python-packages/pycurl.nix
  {attr = "jq";} # jq + oniguruma
  {attr = "jqpy";} # spawns the jq CLI; overlay/python-packages/jqpy.nix
  {attr = "pypandoc";} # spawns the wasm pandoc CLI; overlay/python-packages/pypandoc.nix
  {
    attr = "pypandoc-binary";
    # dist is pypandoc_binary but the module stays pypandoc (as upstream).
    pyImport = "pypandoc";
  } # pypandoc + bundled wasm pandoc; overlay/python-packages/pypandoc-binary.nix
  {attr = "apsw";} # sqlite
  {
    attr = "pynacl";
    pyImport = "nacl.bindings";
  } # libsodium; overlay/python-packages/pynacl.nix
  {
    attr = "psycopg";
    # nixpkgs' check also imports psycopg_c/psycopg_pool, absent from this closure.
    pyImport = "psycopg";
  } # libpq via psycopg-c; overlay/python-packages/psycopg.nix
  {
    attr = "psycopg-binary";
    # upstream guards psycopg_binary against being imported before psycopg;
    # the explicit .pq import then exercises the compiled module.
    pyImport = "psycopg, psycopg_binary.pq";
  } # renamed psycopg-c (pip's `psycopg[binary]`); overlay/python-packages/psycopg-binary.nix
  {attr = "psycopg2";} # libpq via native pg_config splice; overlay/python-packages/psycopg2.nix
  {
    attr = "psycopg2-binary";
    # renamed psycopg2, so it still imports psycopg2.
    pyImport = "psycopg2";
  } # overlay/python-packages/psycopg2-binary.nix
  {
    attr = "pyzbar";
    # loads libzbar.so via ctypes at this import, exercising the dylib.
    pyImport = "pyzbar.pyzbar";
  } # zbar (the overlay's one shared lib); overlay/python-packages/pyzbar.nix
  {attr = "shapely";} # geos; overlay/packages/geos.nix
  {attr = "soundfile";} # libsndfile bundled into the wheel; overlay/python-packages/soundfile.nix
  {attr = "sentencepiece";} # SWIG ext links overlay/packages/sentencepiece.nix (static)
  {
    attr = "pyzmq";
    pyImport = "zmq";
  } # static libzmq; overlay/packages/zeromq.nix + overlay/python-packages/pyzmq (scikit-build-core)
  {attr = "duckdb";} # scikit-build-core; overlay/python-packages/duckdb.nix (unity engine build)
  {attr = "h5py";} # cython ext links static libhdf5; overlay/packages/hdf5.nix + overlay/python-packages/h5py.nix
  {
    attr = "opencv-python";
    pyImport = "cv2";
  } # overlay/packages/opencv4 + overlay/python-packages/{opencv4.nix,opencv-python}
  {
    attr = "opencv-python-headless";
    pyImport = "cv2";
  } # overlay/python-packages/opencv-python (same cv2, headless name)
  {attr = "snowflake-connector-python";} # bundled nanoarrow C++ result-parser ext; overlay/python-packages/snowflake-connector-python.nix (dontCheckRuntimeDeps)
  {
    attr = "onnx";
    # The cp312-abi3 artifact works on both interpreters. Keep both wrappers for
    # tests and dependency closures, but publish only the default one's wheel.
    publishOnce = true;
  } # overlay/packages/{protobuf,onnx} + ml-dtypes
  {
    attr = "onnxruntime";
    # the pybind11 inference engine, built per interpreter (it is not abi3).
    pyImport = "onnxruntime";
  } # overlay/packages/onnxruntime + overlay/python-packages/onnxruntime.nix
  {
    attr = "google-crc32c";
    pyImport = "google_crc32c";
  } # crc32c; overlay/packages/crc32c.nix
  {
    attr = "mysqlclient";
    pyImport = "MySQLdb";
  } # libmysqlclient; overlay/packages/mariadb-connector-c_3_3.nix
  {
    attr = "grpcio";
    pyImport = "grpc";
  } # overlay/python-packages/grpcio.nix (vendored grpc core + abseil/boringssl/cares/re2/zlib)
  {
    attr = "pyarrow";
    pyImport = "pyarrow.parquet";
  } # arrow-cpp; overlay/python-packages/pyarrow.nix

  # ── async / cython, no external C library ──────────────────────────────────────
  {attr = "aiohttp";} # vendored llhttp; deps multidict/yarl/frozenlist/aiosignal/…
  {attr = "httptools";} # cython + vendored llhttp; overlay/python-packages/httptools.nix (llhttp __wasm__ guard)

  # ── rust (pyo3 / setuptools-rust) extensions ───────────────────────────────────
  {
    attr = "pendulum";
    # ships a pure fallback upstream, so reach the compiled module.
    pyImport = "pendulum._pendulum";
  } # maturin
  {attr = "safetensors";} # maturin (pyo3)
  {attr = "blake3";}
  {
    attr = "cramjam";
    # pyo3 gained 3.14 support in 0.26; every cramjam release constrains ^0.25,
    # so the extension's init raises "exceptions must derive from BaseException".
    variants = ["py313"];
  }
  {attr = "jellyfish";}
  {attr = "nh3";} # ammonia bindings; twine/readme-renderer's sanitizer
  {attr = "py-rust-stemmers";}
  {attr = "hypothesis";}
  {attr = "rustworkx";}
  {attr = "burner-redis";}
  {attr = "cachebox";} # maturin/pyo3 (not in nixpkgs); overlay/python-packages/cachebox.nix
  {
    attr = "dbt-extractor";
    pyImport = "dbt_extractor";
  } # maturin/pyo3 (dbt jinja parser)
  {
    attr = "dbt-core-experimental-parser";
    # ships one executable and no python module, so there is nothing to import;
    # the artifact is interpreter-independent, so publish it once.
    skipTest = true;
    publishOnce = true;
  } # overlay/packages/dbt-sa-cli + overlay/python-packages/dbt-core-experimental-parser.nix
  {attr = "libcst";} # setuptools-rust (native CST parser)
  {
    attr = "hf-xet";
    pyImport = "hf_xet";
  } # maturin; overlay/python-packages/hf-xet.nix (tokio/mio + wasm->browser cfg)
  {attr = "jiter";} # overlay/python-packages/jiter.nix (maturin; anthropic/openai JSON core)
  {attr = "watchfiles";} # overlay/python-packages/watchfiles.nix (maturin; uvicorn --reload watcher)
  {
    attr = "rpds-py";
    pyImport = "rpds";
  } # overlay/python-packages/rpds-py.nix (maturin; jsonschema core)
  {attr = "ormsgpack";} # overlay/python-packages/ormsgpack.nix (maturin; _PyLong_AsByteArray 3.13 abi fix)
  {attr = "tiktoken";} # overlay/python-packages/tiktoken.nix (setuptools-rust; openai token counting)
  {
    attr = "uuid-utils";
    pyImport = "uuid_utils";
  } # overlay/python-packages/uuid-utils.nix (maturin; getrandom 0.3/0.4 wasi vendor patch)
  {attr = "fastuuid";} # overlay/python-packages/fastuuid.nix (maturin; getrandom wasi vendor patch)
  {attr = "tokenizers";} # overlay/python-packages/tokenizers.nix (esaxx C++ + onig setjmp; legacy libc++ EH translated to exnref by the shared maturin hook, see WASIX-TODO.md)
  {attr = "bcrypt";} # overlay/python-packages/bcrypt.nix (getrandom/target-lexicon forks)
  {
    attr = "pydantic-core";
    pyImport = "pydantic_core";
  } # overlay/python-packages/pydantic-core.nix (maturin fork + getrandom + extension-module)
  {attr = "cryptography";} # overlay/python-packages/cryptography.nix (maturin + openssl + target-lexicon dl)
  {attr = "primp";} # overlay/python-packages/primp.nix (maturin; rquest/aws-lc-rs browser-impersonation HTTP client)
  {attr = "orjson";} # overlay/python-packages/orjson.nix (maturin + target-lexicon dl)
  {attr = "ddtrace";} # overlay/python-packages/ddtrace/package.nix (cython/C + IAST cmake + rust _native + bundled libddwaf)

  # ── LLM / agent SDKs (pure-python; transitive deps auto-build + auto-publish) ───
  # Each pulls its whole closure into the build + PEP 503 registry; the import
  # smoke-test exercises it under wasmer. huggingface-hub drops hf-xet (see its
  # override) so smolagents needs no Rust wheel.
  {attr = "mcp";} # Model Context Protocol (jsonschema -> rpds-py)
  {attr = "smolagents";} # huggingface smolagents (huggingface-hub, hf-xet dropped)
  {attr = "anthropic";} # Anthropic Claude client (jiter + httpx + pydantic)
  {attr = "openai";} # OpenAI client (jiter; sounddevice dropped, see openai.nix)
  {
    attr = "claude-agent-sdk";
    pyImport = "claude_agent_sdk";
  } # Anthropic Claude Agent SDK (mcp; no jiter)
  {
    attr = "openai-agents";
    pyImport = "agents";
  } # OpenAI Agents SDK (openai + mcp)
  {
    attr = "pydantic-ai-slim";
    pyImport = "pydantic_ai";
  } # Pydantic AI (pydantic-core; no new Rust)
  {attr = "langgraph";} # LangGraph (ormsgpack + uuid-utils)
  # already in the registry closure; named here so their history is maintainable
  # for the consumers that pin a sibling to their own release
  {
    attr = "langgraph-prebuilt";
    # langgraph.prebuilt imports langgraph.stream at top level, absent from its
    # own closure (langgraph depends on it, not the other way round); the
    # langgraph test above already exercises this cross build.
    skipTest = true;
  }
  {attr = "langgraph-sdk";}
  {attr = "pydantic-graph";}
  {attr = "langchain-core";}
  {attr = "langchain-text-splitters";}
  {attr = "langchain";} # LangChain (langgraph + langchain-core)
  {attr = "litellm";} # LiteLLM (tokenizers + tiktoken + fastuuid + openai)
  {attr = "langflow";} # Langflow core server and built web frontend
]
