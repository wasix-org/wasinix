# grpcio for wasix. Built like a pip sdist install: grpc core plus vendored
# abseil, boringssl, c-ares, re2 and zlib all compiled into the extension
# (the overlay has no cross grpc/c-ares/re2, and grpcio's TLS wants boringssl).
# grpcio-wasix.patch ports the platform probes (port_platform.h, iomgr/port.h,
# event_engine/port.h, abseil mmap), from the wasix build-scripts grpc patches.
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
in
  wheels.onlyOnWasix pyprev.grpcio (
    helpers.libTweaks (
      {
        patches = [./patches/grpcio-wasix.patch];
        env = {
          # vendor openssl/zlib/cares instead of nixpkgs' system builds
          GRPC_PYTHON_BUILD_SYSTEM_OPENSSL = "false";
          GRPC_PYTHON_BUILD_SYSTEM_ZLIB = "false";
          GRPC_PYTHON_BUILD_SYSTEM_CARES = "false";
          # default linux CFLAGS add -fno-exceptions, which wasixcc rejects
          GRPC_PYTHON_CFLAGS = "-std=c++17 -fvisibility=hidden -fno-wrapv";
          # default linux LDFLAGS add -lpthread -static-libgcc; C++ runtime
          # must be linked explicitly (setuptools links with the C driver)
          GRPC_PYTHON_LDFLAGS = "-lc++ -lc++abi -lunwind";
        };
      }
      # protobuf is only an extras dep; keeps the wheel closure protobuf-free
      // wheels.dropInputsByName ["c-ares" "openssl" "zlib" "protobuf"]
    )
    pyprev.grpcio
  )
