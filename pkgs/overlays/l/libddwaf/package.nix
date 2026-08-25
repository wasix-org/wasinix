# libddwaf for wasix. ddtrace dlopens the shared library when appsec is enabled;
# the static archive remains available to other consumers. Version tracks
# ddtrace's LIBDDWAF_VERSION. Dependencies are vendored, with rapidjson's
# ExternalProject source supplied from the store.
{
  exposePackage,
  packageSet,
  profileSets,
  scope,
}:
exposePackage (
  let
    rapidjson = packageSet.buildPackages.rapidjson.src;
  in
    packageSet.stdenv.mkDerivation (finalAttrs: {
      pname = "libddwaf";
      version = "2.0.0";

      src = packageSet.fetchFromGitHub {
        owner = "DataDog";
        repo = "libddwaf";
        tag = finalAttrs.version;
        hash = "sha256-CTWyFp41Ddo26U1xE8XLPyQW44krwg7ahJPbx0+ZwZs=";
      };

      patches = packageSet.lib.optional (scope == "wasix") ./size_t-not-in-all_types-variant.patch;

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

      nativeBuildInputs = [packageSet.buildPackages.cmake];

      cmakeFlags = [
        "-DLIBDDWAF_BUILD_STATIC=ON"
        "-DLIBDDWAF_TESTING=OFF"
      ];

      # a dylib: PIC profiles only, like zbar.
      # Derived pin, deliberately no updateScript: the version must equal the
      # LIBDDWAF_VERSION ddtrace's setup.py expects, since ddtrace bundles this
      # .so. ddtrace's updater re-derives it, so bumping it here on its own
      # would only desync the pair until the next ddtrace bump.
      passthru.wasix.supportedProfiles = profileSets.pic;
    })
)
