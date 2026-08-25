# grpcio for wasix. Built like a pip sdist install, with abseil, boringssl, c-ares,
# re2 and zlib vendored into the extension; the patch ports their platform probes.
{
  exposeExtendedPackage,
  package,
  lib,
  dropInputsByNameInfix,
  linkInputs,
}: let
  # before 1.75 the sdist is setup.py only, so nixpkgs' cython-unpin substitution
  # has no file to patch.
  noPyproject = lib.versionOlder package.version "1.75";
in
  exposeExtendedPackage (
    {
      patches = [./patches/grpcio-wasix.patch];
      env = {
        GRPC_PYTHON_BUILD_SYSTEM_OPENSSL = "false";
        GRPC_PYTHON_BUILD_SYSTEM_ZLIB = "false";
        GRPC_PYTHON_BUILD_SYSTEM_CARES = "false";
        # default linux CFLAGS add -fno-exceptions, which wasixcc rejects
        GRPC_PYTHON_CFLAGS = "-std=c++17 -fvisibility=hidden -fno-wrapv";
        # default linux LDFLAGS add -lpthread -static-libgcc; setuptools links with
        # the C driver, so the C++ runtime needs naming
        GRPC_PYTHON_LDFLAGS = "-lc++ -lc++abi -lunwind";
      };
    }
    # protobuf is only an extras dep; keeps the wheel closure protobuf-free
    // linkInputs (dropInputsByNameInfix ["c-ares" "openssl" "zlib" "protobuf"])
    // lib.optionalAttrs noPyproject {postPatch = _: "";}
  )
