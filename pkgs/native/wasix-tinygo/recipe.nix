{
  tinygo,
  llvmPackages_20,
  wasix-llvm,
  ...
}:
(tinygo.override {
  llvmPackages_20 =
    wasix-llvm.passthru.llvm
    // {
      inherit (llvmPackages_20) compiler-rt;
    };
}).overrideAttrs (oldAttrs: {
  postConfigure =
    (oldAttrs.postConfigure or "")
    + ''
      chmod u+w vendor/tinygo.org/x/go-llvm vendor/tinygo.org/x/go-llvm/ir.go
      patch -p1 < ${./llvm-21-c-api.patch}
      patch -p1 < ${./llvm-21-nocapture.patch}
    '';
  meta =
    (oldAttrs.meta or {})
    // {
      longDescription = "The TinyGo compiler configured with the WASIX LLVM fork for producing WebAssembly programs.";
      changelog = "https://github.com/tinygo-org/tinygo/releases/tag/v${oldAttrs.version}";
      mainProgram = "tinygo";
    };
})
