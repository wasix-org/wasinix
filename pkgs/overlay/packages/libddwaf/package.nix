# libddwaf for wasix: DataDog's WAF engine, dlopened (ctypes) from inside the
# ddtrace wheel when appsec is enabled, so it ships as a shared lib. Version
# tracks ddtrace's LIBDDWAF_VERSION (setup.py). C/C++ deps are vendored
# in-tree; rapidjson is the one ExternalProject download the library target
# needs, fed from the store (gtest/yaml-cpp hang off test targets, off here).
{
  final,
  helpers,
  ...
}: let
  rapidjson = final.buildPackages.rapidjson.src;
in
  final.stdenv.mkDerivation (finalAttrs: {
    pname = "libddwaf";
    version = "2.0.0";

    src = final.fetchFromGitHub {
      owner = "DataDog";
      repo = "libddwaf";
      tag = finalAttrs.version;
      hash = "sha256-CTWyFp41Ddo26U1xE8XLPyQW44krwg7ahJPbx0+ZwZs=";
    };

    patches = [./size_t-not-in-all_types-variant.patch];

    postPatch = ''
      substituteInPlace third_party/CMakeLists.txt \
        --replace-fail 'https://github.com/Tencent/rapidjson/archive/''${RAPIDJSON_COMMIT}.tar.gz' '${rapidjson}'
      # test-data git clone (excluded from all); its mere declaration makes
      # configure demand git.
      sed -i '/ExternalProject_Add(proj_event_rules/,/set_target_properties(proj_event_rules/d' \
        third_party/CMakeLists.txt
      # BUILD_ID comes from `git rev-parse HEAD`; no .git in a nix source.
      substituteInPlace cmake/shared.cmake \
        --replace-fail 'COMMAND git rev-parse HEAD' \
                       'COMMAND echo 0000000000000000000000000000000000000000'
    '';

    nativeBuildInputs = [final.buildPackages.cmake];

    cmakeFlags = [
      "-DLIBDDWAF_BUILD_STATIC=OFF"
      "-DLIBDDWAF_TESTING=OFF"
    ];

    # a dylib: PIC profiles only, like zbar.
    # Derived pin, deliberately no updateScript: the version must equal the
    # LIBDDWAF_VERSION ddtrace's setup.py expects, since ddtrace bundles this
    # .so. ddtrace's update.py re-derives it, so bumping it here on its own
    # would only desync the pair until the next ddtrace bump.
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
  })
