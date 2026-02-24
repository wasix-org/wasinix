{ toolchain, gzip, ... }:
((gzip.override {
  # Avoid pulling target-side bash-static via nixpkgs gzip's runtimeShellPackage.
  runtimeShellPackage = null;
}).overrideAttrs (old: {
  nativeBuildInputs = builtins.filter
    (dep:
      (dep.pname or "") != "make-shell-wrapper-hook"
      && (dep.name or "") != "make-shell-wrapper-hook")
    (old.nativeBuildInputs or [ ]);
  preConfigure = (old.preConfigure or "") + ''
    ${toolchain.commonPreConfigure}
  '';
  preFixup = ''
    sed -i '1{;/#!\/bin\/sh/aPATH="'$out'/bin:$PATH"
    }' $out/bin/*
  '';
  configureFlags = (old.configureFlags or [ ]) ++ [
    "--host=${toolchain.host}"
  ];
  hardeningDisable = [ "all" ];
  postInstall = (old.postInstall or "") + ''
    if [ -f "$out/bin/gzip" ]; then
      mv "$out/bin/gzip" "$out/bin/gzip.wasm"
    fi
    rm -f "$out/bin/gunzip" "$out/bin/zcat"
  '';
}))
