# The Python wheels wasinix ships (nixpkgs python3.pkgs attr-names) — the worklist driving the
# pythonWheels build targets + import smoke-tests. A wasix build fix (if any) lives in
# overlay/python-packages/<attr>.nix and folds in automatically; most need none.
#
# Each entry:
#   attr      — python3.pkgs.<attr> (also the build-target / CI key)
#   pyImport  — module the smoke-test imports (default: attr with '-' → '_')
#   skipTest  — ship without an import test (rare; note why)
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
  {
    attr = "zope-interface";
    pyImport = "zope.interface";
  }
  {attr = "caio";}
  {attr = "peewee";}
  {attr = "fastavro";}
  {attr = "zstandard";}
  {attr = "brotlicffi";}

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
  # NOTE: pycurl deferred — its setup.py links the *native* curl's libcurl.so via
  # curl-config (wrong file type for wasm-ld). Needs a curl-config-pointing override
  # like gitMinimal's.
  {attr = "jq";} # jq + oniguruma
  {attr = "apsw";} # sqlite
  {
    attr = "pynacl";
    pyImport = "nacl.bindings";
  } # libsodium; overlay/python-packages/pynacl.nix

  # ── async / cython, no external C library ──────────────────────────────────────
  {attr = "aiohttp";} # vendored llhttp; deps multidict/yarl/frozenlist/aiosignal/…

  # ── rust (pyo3 / setuptools-rust) extensions ───────────────────────────────────
  {attr = "bcrypt";} # overlay/python-packages/bcrypt.nix (getrandom/target-lexicon forks)
  {
    attr = "pydantic-core";
    pyImport = "pydantic_core";
  } # overlay/python-packages/pydantic-core.nix (maturin fork + getrandom + extension-module)
  {attr = "cryptography";} # overlay/python-packages/cryptography.nix (maturin + openssl + target-lexicon dl)
  {attr = "orjson";} # overlay/python-packages/orjson.nix (maturin + target-lexicon dl)
]
