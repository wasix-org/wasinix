# The test suite drives a postgres server and a slapd, which nothing runs in a
# cross build. darcs and breezy cannot be built (WASIX-TODO.md), so they drop
# out of the VCS tools; the others stay.
{
  prev,
  final,
  helpers,
  preferredProfilePackages,
  ...
}: let
  coreutils = preferredProfilePackages.coreutils;
  gnutar = preferredProfilePackages.gnutar;
  openssh = preferredProfilePackages.openssh;
  runtimeTools = [coreutils gnutar openssh];

  # a Makefile.PL that runs a binary built for the target reaches it through the
  # runtime, the same way the tests do
  # a pure perl distribution decides nothing about the target in its configure
  # step, so it can run under the build perl, which has the XS modules miniperl
  # lacks
  underBuildPerl = pkg:
    pkg.overrideAttrs (o: {
      preConfigure =
        (o.preConfigure or "")
        + "\nexport PATH=${final.lib.makeBinPath [final.buildPackages.perl]}:$PATH\n";
    });

  underWasmer = substitution: pkg:
    pkg.overrideAttrs (o: {
      nativeBuildInputs = (o.nativeBuildInputs or []) ++ [final.buildPackages.wasmer];
      postPatch = (o.postPatch or "") + "\n" + substitution;
    });
in
  helpers.extendPackage (prev.hydra.override {
    perlPackages = final.perlPackages.overrideScope (_: pprev: {
      # Sub::Name carries its test-only B::C in buildInputs, and B::C builds by
      # loading the XS module B into miniperl, which has no dynamic loading.
      SubName = pprev.SubName.overrideAttrs (o: {
        propagatedBuildInputs =
          builtins.filter (x: (x.pname or "") != "B-C") (o.propagatedBuildInputs or []);
      });
      # yath, the runner hydra's test suite drives, refuses to build without true
      # fork. That suite does not run in a cross build (doCheck above).
      Test2Harness = final.emptyDirectory;
      # YAML::Tiny writes META.yml through the strict UTF-8 layer, which lives in
      # an XS module the cross build's miniperl cannot load.
      YAMLTiny = pprev.YAMLTiny.overrideAttrs (o: {
        patches = (o.patches or []) ++ [./patches/yaml-tiny-utf8-layer.patch];
      });
      # nixpkgs gives cross builds a DBI::DBD stub, since the real one loads the
      # XS DBI that miniperl cannot. Its dbd_postamble already names the arch
      # directory; drivers ask for the same path through dbd_dbi_arch_dir.
      DBI = pprev.DBI.overrideAttrs (o: {
        postInstall =
          (o.postInstall or "")
          + ''
            autodir=$(echo $out/${final.perl.libPrefix}/${final.perl.version}/*/auto/DBI)
            printf 'sub dbd_dbi_arch_dir { return "%s"; }\n1;\n' "$autodir" \
              >> $out/${final.perl.libPrefix}/cross_perl/${final.perl.version}/DBI/DBD.pm
          '';
      });
      # cmmg.pl writes pure perl sources, but MakeMaker's $(PERL) is the cross
      # build's miniperl, which cannot load the XS List::Util the generator wants.
      ClassMethodMaker = pprev.ClassMethodMaker.overrideAttrs (o: {
        makeFlags = (o.makeFlags or []) ++ ["PERL=${final.lib.getExe final.buildPackages.perl}"];
      });
      # Makefile.PL loads Text::CSV to read its version and Text::CSV_PP reaches
      # for the XS module B. Class::MethodMaker above ships XS and cannot take
      # the same route.
      TextCSV = underBuildPerl pprev.TextCSV;
      # Makefile.PL calls crypt() to check the interpreter has it. miniperl does
      # not; the perl this installs for links libxcrypt and does.
      CatalystPluginAuthentication = underBuildPerl pprev.CatalystPluginAuthentication;
      # Makefile.PL serialises the part-of-speech lexicon with Storable. nstore
      # writes network order, so the wasm perl retrieves what the build perl wrote.
      LinguaENTagger = underBuildPerl pprev.LinguaENTagger;
      # inc/Probe.pm compiles a C probe for the struct winsize layout and runs it.
      TermSizePerl =
        underWasmer ''
          substituteInPlace inc/Probe.pm \
            --replace-fail '`./$exe_file`' '`wasmer run ./$exe_file`'
        ''
        pprev.TermSizePerl;
      # Makefile.PL asks the openssl binary its version, and ours is the wasm one.
      NetSSLeay =
        underWasmer ''
          substituteInPlace Makefile.PL \
            --replace-fail 'qq{"$exec" version |}' 'qq{wasmer run "$exec" -- version |}'
        ''
        pprev.NetSSLeay;
      # GD names libxpm itself, so gd.nix dropping the xpm reader does not spare it
      # the xorgproto build.
      GD = pprev.GD.overrideAttrs (o: {
        propagatedBuildInputs =
          builtins.filter (x: (x.pname or "") != "libxpm") (o.propagatedBuildInputs or []);
        makeMakerFlags =
          builtins.filter (f: builtins.match "--lib_xpm_path=.*" f == null) (o.makeMakerFlags or []);
      });
    });
    # nixpkgs pins nix_2_34 and its component set; take the paired WASIX
    # versions from the package that builds both.
    nixVersions = final.nix.passthru.nixVersions;
    # hydra execs these rather than linking them, and coreutils builds at the off
    # profile alone (several of its programs fork).
    inherit coreutils gnutar openssh;
    darcs = final.emptyDirectory;
    breezy = final.emptyDirectory;
    # only the test suite reads OPENLDAP_ROOT, and openldap reaches bash through
    # libtool, which builds at the off profile alone
    openldap = final.emptyDirectory;
  }) {
    doCheck = false;
    nativeCheckInputs = _: [];
    # The wrapper carries PERL5LIB and HYDRA_HOME for the perl scripts, and
    # nixpkgs keeps it off compiled programs by reading their magic. Ours begins
    # "\0asm", which the ELF test misses, so every binary came out a shell
    # script instead of the wasm the runtime loads.
    postInstall = old:
      builtins.replaceStrings
      ["if [[ $chars =~ ELF ]]; then continue; fi"]
      ["if [[ $chars =~ ELF || $chars =~ asm ]]; then continue; fi"]
      old;
    # F_SETPIPE_SZ is a linux fcntl, and the calls are an unchecked buffer size
    # hint on the pipes to the remote builder.
    patches = [./patches/wasi-no-pipe-size-hint.patch];
    # The top-level project is a dev-shell stub that pulls in every subproject.
    # The linters run perlcritic and the tests run the harness, both under a
    # perl this build cannot execute; the manual and hydra itself stay.
    postPatch = ''
      substituteInPlace meson.build \
        --replace-fail "subproject('hydra-linters')" "" \
        --replace-fail "subproject('hydra-tests')" ""
    '';
    # prometheus-cpp installs cmake config and no pkg-config file, and meson
    # reads the former only when it can run cmake. meson also runs unzip on the
    # bundled bootstrap archive, so that one has to be a build-platform binary;
    # the wasix unzip stays in the runtime environment.
    nativeBuildInputs = with final.buildPackages; [cmake unzip];
    # The perl modules are XS, so they load through dlopen like perl itself, and
    # apr's DSO check wants the same dlfcn.h.
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
    passthru.wasinix.shipped = true;
    passthru.wasmer.selfMounts = runtimeTools;
    passthru.wasmer.version = v: let
      d = builtins.match ".*-unstable-([0-9]{4})-([0-9]{2})-([0-9]{2})" v;
    in
      assert final.lib.assertMsg (d != null) "hydra: version ${v} is not <ver>-unstable-YYYY-MM-DD"; "0.0.${final.lib.concatStrings d}";
    # The compiled daemons keep their plain names (the perl scripts exec them),
    # so name them rather than leaving the bin/*.wasm glob to find nothing.
    passthru.wasmer.commands = [
      {
        name = "hydra-evaluator";
        wasm = "hydra-evaluator";
        output = "hydra-evaluator.wasm";
      }
      {
        name = "hydra-queue-runner";
        wasm = "hydra-queue-runner";
        output = "hydra-queue-runner.wasm";
      }
    ];
  }
