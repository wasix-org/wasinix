# Perl for wasix. The patches carry perl-cross past its ELF-only type probes,
# add wasi as a target it knows, supply the process and extension entry points
# perl expects a platform to have, and fill in the perl-cross stubs that
# miniperl runs Makefile.PL against.
{
  final,
  prev,
  helpers,
  preferredProfilePackages,
  ...
}: let
  perl =
    helpers.wasmRename {
      wasmName = "perl";
      # scripts and build tooling reach bin/perl by that name
      posixAlias = true;
    } (helpers.extendPackage (prev.perl5.override {
        # ${coreutils}/bin/pwd is a runtime path baked into Cwd, and coreutils
        # builds at the off profile only.
        coreutils = preferredProfilePackages.coreutils;
        # the module set is built against `self`, so without this every perl module
        # compiles against an interpreter carrying none of the above
        self = perl;
      }) {
        patches = [
          ./patches/perl-cross-non-elf-probes.patch
          ./patches/wasi-spawn-without-fork.patch
          ./patches/wasi-posix-unavailable-calls.patch
          ./patches/wasi-errno-cpp-file-argument.patch
          ./patches/cross-perl-stubs.patch
        ];
        postPatch = ''
          ${final.lib.getExe final.buildPackages.perl} -Icnf/stub -MList::Util=pairs,reduce -e '
            my ($pair) = pairs(key => "value");
            my $reduced = reduce { (defined $a ? $a : "x") . $b } undef, "y";
            die "List::Util stub mismatch\n"
              unless $reduced eq "xy"
                && ref($pair) eq "List::Util::_Pair"
                && $pair->key eq "key"
                && $pair->value eq "value";
          '
        '';
        # XS modules are dlopened side modules, which the PIC sysroots alone provide.
        passthru.wasix.supportedProfiles = helpers.profiles.pic;
        # @INC and the XS .so paths are baked into the interpreter, so a webc has to
        # carry them.
        passthru.wasmer.autoSelfMount = true;
        # nixpkgs disables dynamic loading for every static host, which would link
        # each extension into perl itself; the re extension then redefines the regcomp
        # symbols already in libperl.
        configureFlags = old:
          (builtins.filter (f: f != "-Uusedl") old)
          ++ [
            "-Dusedl"
            "-Ddlsrc=dl_dlopen.xs"
            "-Dcccdlflags=-fPIC"
            "-Dlddlflags=-shared"
            # wasi-libc calls main(argc, argv), and a wasm function's arity is part
            # of its type, so perl's three-argument form does not resolve.
            "-Accflags=-DNO_ENV_ARRAY_IN_MAIN"
          ];
      });
in
  perl
