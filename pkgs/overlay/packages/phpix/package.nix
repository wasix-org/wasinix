# phpix — the PHP runtime/server for wasix (wasmerio/phpix): a cargo-wasix Rust program that embeds
# our static php85 libphp. Ported from the old pkgs/programs/phpix (mk-phpix-wasix + phpixPhp85).
# Built on the build host via cargo-wasix (targeting wasm32-wasmer-wasi), linking php's libphp.a +
# its phpExtraLibDirs/phpExtraLinkLibs. exnrefEh-only — must match php's profile/EH mode.
{
  final,
  prev,
  toolchain,
  ...
}: let
  lib = prev.lib;
  php = final.php;
  # build-platform rustPlatform — only for cargoSetupHook + importCargoLock (vendoring the lock);
  # the actual compile goes through cargo-wasix.
  rustPlatform = final.buildPackages.rustPlatform;
in
  final.buildPackages.stdenvNoCC.mkDerivation {
    pname = "phpix";
    version = "0.1.12803";

    # phpix is a private repo, vendored as the vendor/phpix submodule. Build with
    # `nix build '.?submodules=1#…'` so the flake tree includes it; the rev is pinned by the
    # submodule gitlink (bump via `git submodule update --remote vendor/phpix`).
    src = ../../../../vendor/phpix;

    cargoDeps = rustPlatform.importCargoLock {
      lockFile = ./phpix.Cargo.lock;
      allowBuiltinFetchGit = true;
      # wasix-abi-rust bundles wasix-witx as a git submodule pinned to a rev that isn't on witx's
      # main branch, so importCargoLock's builtin fetchGit can't resolve it. Route this one dep
      # through fetchgit (submodule-aware + ref-agnostic) by pinning its hash here.
      outputHashes = {
        "wasix-0.13.1" = "sha256-HBCqkQivakAVUmnonThNj/D0HbRDtCummXQfvLpx1xY=";
      };
    };

    nativeBuildInputs = [
      rustPlatform.cargoSetupHook
      toolchain.cargoWasix
      toolchain.wasixcc
      toolchain.wasixLlvm
      # pkgsBuildBuild (fully native x86_64), NOT buildPackages — the latter is the build->host
      # cross set, whose `gcc` is the unbuildable x86_64->wasm cross compiler. These are host-side
      # build tooling: gcc links the x86_64 proc-macro/build-script artifacts, libclang runs bindgen.
      final.pkgsBuildBuild.gcc
      final.pkgsBuildBuild.llvmPackages.libclang
    ];

    prePatch = ''
      cp ${./phpix.Cargo.lock} Cargo.lock
      patch -N -p1 --batch <<'PATCHEOF' || true
diff --git a/src/php/mod.rs b/src/php/mod.rs
index abd4f10..44ddb14 100644
--- a/src/php/mod.rs
+++ b/src/php/mod.rs
@@ -78,6 +78,22 @@ fn with_thread_mode<R>(f: impl FnOnce(&RefCell<Option<PhpThreadMode>>) -> R) ->
     r
 }

+unsafe fn configure_core_globals_for_embedded_request() {
+    #[cfg(all(target_os = "wasi", target_vendor = "wasmer"))]
+    {
+        let pg = unsafe { phpix_pg() };
+        if !pg.is_null() {
+            // PHP 8.5 deprecates setting report_memleaks=0 via INI, but request
+            // shutdown still uses this flag to decide whether tracked allocations
+            // are released immediately. Set the global directly so long-running
+            // workers reclaim request memory without invoking the deprecated INI handler.
+            unsafe {
+                (*pg).report_memleaks = false;
+            }
+        }
+    }
+}
+
 pub fn start_php(
     num_threads: u32,
     document_root: &Path,
@@ -129,24 +145,10 @@ pub fn start_php(

         sapi_startup(&raw mut sapi_mod);

-        #[cfg(all(target_os = "wasi", target_vendor = "wasmer"))]
-        // WASI PHP currently uses a custom tracked allocator path in Zend.
-        // PHP defaults report_memleaks to 1 (see php main/main.c ini defaults).
-        // With report_memleaks=1, request shutdown keeps leaked allocations for
-        // leak reporting and only clears tracking metadata, which causes memory
-        // to ratchet upward across requests in long-running workers.
-        // Disable leak reporting by default to force request-time reclamation.
-        let runtime_ini_defaults = "report_memleaks=0\n";
-        #[cfg(not(all(target_os = "wasi", target_vendor = "wasmer")))]
-        let runtime_ini_defaults = "";
-
         let ini_entries = if let Some(php_ini_path) = php_ini_path
             && let Some(user_ini) = load_ini_entries(php_ini_path)?
         {
-            let combined = format!("{}{}", runtime_ini_defaults, user_ini.to_string_lossy());
-            Some(CString::new(combined)?)
-        } else if !runtime_ini_defaults.is_empty() {
-            Some(CString::new(runtime_ini_defaults)?)
+            Some(user_ini)
         } else {
             None
         };
diff --git a/src/php/script.rs b/src/php/script.rs
index 850d140..e575ee5 100644
--- a/src/php/script.rs
+++ b/src/php/script.rs
@@ -181,6 +181,7 @@ pub fn execute_cli_script(script_path: &Path, script_args: Vec<String>) -> Resul
         // Set argc/argv in request_info so PHP core can populate $argc/$argv
         sg.request_info.argc = argc;
         sg.request_info.argv = argv_ptrs.as_ptr() as *mut *mut c_char;
+        configure_core_globals_for_embedded_request();

         if php_request_startup() != 0 {
             php_request_shutdown(ptr::null_mut());
diff --git a/src/php/worker.rs b/src/php/worker.rs
index 87b0274..ab84828 100644
--- a/src/php/worker.rs
+++ b/src/php/worker.rs
@@ -209,6 +209,7 @@ fn process_task(task: PhpTask) -> Result<()> {
         sg.server_context = std::ptr::dangling_mut();
         sg.sapi_headers.http_response_code = 200;
         update_server_globals(&mut sg.request_info);
+        configure_core_globals_for_embedded_request();

         if php_request_startup() != 0 {
             php_request_shutdown(ptr::null_mut());
PATCHEOF
    '';

    buildPhase = ''
      runHook preBuild

      export HOME="$PWD/.home"
      export CARGO_HOME="$HOME/.cargo"
      export RUSTUP_HOME="$HOME/.rustup"
      mkdir -p "$HOME" "$CARGO_HOME" "$RUSTUP_HOME"

      SYSROOT_PATH="$(wasixccenv -sWASM_EXCEPTIONS=yes print-sysroot)"
      compat_lib_dir="$PWD/.php-link-compat"
      mkdir -p "$compat_lib_dir"
      # PHP is built with LTO; some archived bitcode objects carry linker options for libraries
      # provided by the sysroot/runtime surface rather than standalone Nix archives. Provide empty
      # compat archives so wasm-ld accepts those names while libc/other archives resolve the symbols.
      for lib in charset iconv icrt icutu; do
        wasixar crs "$compat_lib_dir/lib''${lib}.a"
      done
      export WASIX_PHP_HOME="${php}"
      export WASIX_PHP_EXTRA_LIB_DIR="$compat_lib_dir:${lib.concatStringsSep ":" php.phpExtraLibDirs}:$SYSROOT_PATH/lib/wasm32-wasi"
      export WASIX_PHP_EXTRA_LIBS="${lib.concatStringsSep ":" php.phpExtraLinkLibs}"
      export LIBCLANG_PATH="${final.pkgsBuildBuild.llvmPackages.libclang.lib}/lib"
      export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="${final.pkgsBuildBuild.gcc}/bin/gcc"

      cargo-wasix wasix build --release --frozen --offline

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      cp target/wasm32-wasmer-wasi/release/phpix.wasm "$out/bin/phpix.wasm"
      runHook postInstall
    '';

    passthru.wasix.supportedProfiles = ["exnrefEh"];
    # The manifest entrypoint is what makes `wasmer run <pkg>` consult the
    # command's detected wasm features (tail calls!) when picking its engine;
    # without it the default engine rejects the module.
    passthru.wasmer.entrypoint = "phpix";

    meta = {
      description = "PHPix — PHP runtime/server for wasix, embedding static php85 libphp";
      homepage = "https://github.com/wasmerio/phpix";
      license = lib.licenses.mit;
      mainProgram = "phpix";
    };
  }
