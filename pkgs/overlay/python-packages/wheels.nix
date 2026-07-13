# Python wheels wasinix ships (nixpkgs python3.pkgs attr names); drives the
# pythonWheels build targets and import smoke-tests. Build fixes, when needed,
# live in overlay/python-packages/<attr>.nix and fold in automatically.
#
# Each entry:
#   attr      python3.pkgs.<attr> (also the build-target / CI key)
#   pyImport  module the smoke-test imports (default: attr with '-' -> '_')
#   skipTest  ship without an import test (rare; note why)
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
  {attr = "eventlet";} # needs the stdlib ssl module (greendns imports it)
  {
    attr = "psycopg-pool";
    pyImport = "psycopg_pool";
  }
  {
    attr = "protobuf";
    # the compiled upb backend: a clean import proves the .so loads (the pure
    # `google.protobuf` would silently fall back to the python impl).
    pyImport = "google._upb._message";
  }

  # ── C extensions with no external C library ────────────────────────────────────
  {attr = "cffi";} # overlay/python-packages/cffi.nix (libffi ffi_closure_alloc)
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
  {attr = "greenlet";}
  {attr = "gevent";} # overlay/python-packages/gevent.nix (embedded libev, no libuv/c-ares)
  {attr = "uvloop";} # libuv; overlay/packages/libuv/package.nix
  {
    attr = "zope-interface";
    pyImport = "zope.interface";
  }
  {attr = "caio";}
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

  # ── meson-built wheels ─────────────────────────────────────────────────────────
  {attr = "contourpy";}
  {attr = "numpy";} # overlay/python-packages/numpy.nix (BLAS-less)
  {attr = "pandas";}
  {
    attr = "matplotlib";
    pyImport = "matplotlib.pyplot";
  } # overlay/python-packages/matplotlib.nix

  # ── C extensions linking a C library already in the overlay ────────────────────
  # import targets reach the compiled module so the smoke-test exercises the .so.
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
  {attr = "pypandoc";} # spawns the pandoc CLI; overlay/python-packages/pypandoc.nix
  {attr = "apsw";} # sqlite
  {
    attr = "pynacl";
    pyImport = "nacl.bindings";
  } # libsodium; overlay/python-packages/pynacl.nix
  {attr = "psycopg";} # libpq via psycopg-c; overlay/python-packages/psycopg.nix
  {
    attr = "pyzbar";
    # loads libzbar.so via ctypes at this import, exercising the dylib.
    pyImport = "pyzbar.pyzbar";
  } # zbar (the overlay's one shared lib); overlay/python-packages/pyzbar.nix
  {attr = "shapely";} # geos; overlay/packages/geos.nix
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

  # ── rust (pyo3 / setuptools-rust) extensions ───────────────────────────────────
  {attr = "jiter";} # overlay/python-packages/jiter.nix (maturin; anthropic/openai JSON core)
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
  {attr = "orjson";} # overlay/python-packages/orjson.nix (maturin + target-lexicon dl)

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
  {attr = "langgraph";} # LangGraph (ormsgpack + uuid-utils, both now fixed)
  {attr = "langchain";} # LangChain (langgraph + langchain-core)
  {attr = "litellm";} # LiteLLM (tokenizers + tiktoken + fastuuid + openai)
]
