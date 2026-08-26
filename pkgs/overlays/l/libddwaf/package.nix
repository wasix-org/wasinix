{
  exposePackage,
  packageSet,
  profileSets,
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

      postPatch = ''
        substituteInPlace third_party/CMakeLists.txt \
          --replace-fail 'https://github.com/Tencent/rapidjson/archive/''${RAPIDJSON_COMMIT}.tar.gz' '${rapidjson}'
        sed -i '/ExternalProject_Add(proj_event_rules/,/set_target_properties(proj_event_rules/d' \
          third_party/CMakeLists.txt
        substituteInPlace cmake/shared.cmake \
          --replace-fail 'COMMAND git rev-parse HEAD' \
                         'COMMAND echo 0000000000000000000000000000000000000000'
      '';

      nativeBuildInputs = [packageSet.buildPackages.cmake];
      cmakeFlags = [
        "-DLIBDDWAF_BUILD_STATIC=ON"
        "-DLIBDDWAF_TESTING=OFF"
      ];

      passthru.wasix.supportedProfiles = profileSets.pic;
    })
)
