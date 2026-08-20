# Boost for wasix: headers plus the compiled libraries reached by Nix.
# nixpkgs' Boost derivation builds and installs Boost.URL. Boost.Context uses a
# WASIX backend outside its architecture matrix, so only that archive is added
# by hand.
{
  final,
  prev,
  helpers,
  ...
}: let
  boostBuild = final.buildPackages.boost-build.override {
    useBoost = {
      inherit (prev.boost) src version;
      boostBuildPatches = [./boost-build-wasix-features.patch];
    };
  };
  base = prev.boost.override {
    boost-build = boostBuild;
    enableIcu = false;
    enableShared = false;
    enableStatic = true;
    extraB2Args = ["--with-url"];
    patches = [./boost-context-wasm-binary-format.patch];
  };
in
  helpers.extendPackage base {
    # nixpkgs adds --without-python when Python is disabled, but b2 rejects any
    # --without-* together with the --with-url library selection.
    buildPhase = old: final.lib.replaceStrings ["--without-python"] [""] old;
    installPhase = old: final.lib.replaceStrings ["--without-python"] [""] old;

    postPatch = ''
          # WASIX has mmap but not mprotect, so it cannot provide the guard page this
          # allocator promises. Keep the API available with the unprotected allocator.
          substituteInPlace boost/context/protected_fixedsize_stack.hpp \
            --replace-fail \
              '#if defined(BOOST_WINDOWS)
      # include <boost/context/windows/protected_fixedsize_stack.hpp>
      #else
      # include <boost/context/posix/protected_fixedsize_stack.hpp>
      #endif' \
              '#if defined(__wasi__)
      # include <boost/context/fixedsize_stack.hpp>
      namespace boost { namespace context {
      using protected_fixedsize_stack = fixedsize_stack;
      }}
      #elif defined(BOOST_WINDOWS)
      # include <boost/context/windows/protected_fixedsize_stack.hpp>
      #else
      # include <boost/context/posix/protected_fixedsize_stack.hpp>
      #endif'
    '';

    postBuild = ''
      $CXX -std=c++17 -I. -O2 -c ${./context-wasix.cpp} -o context-wasix.o
      $AR rcs libboost_context.a context-wasix.o
    '';

    postInstall = ''
      install -Dm644 libboost_context.a -t "$out/lib"
    '';

    passthru.wasix.supportedProfiles = helpers.profiles.withEh;
    passthru.wasix.updateNotes = [
      {message = "recheck the Boost.Build WASIX feature patches against the new Boost release";}
    ];
  }
