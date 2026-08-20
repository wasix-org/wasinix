# ncurses auto-threads. In the off-EH profile, <setjmp.h> gates sigsetjmp out
# (readline shares bash's BASH_FUNC_POSIX_SETJMP cache var), so pick plain setjmp.
{
  final,
  prev,
  helpers,
  ...
}: let
  offMode = (final.stdenv.hostPlatform.wasmExceptions or "yes") == "no";
in
  helpers.extendPackage prev.readline {
    configureFlags = final.lib.optionals offMode ["bash_cv_func_sigsetjmp=missing"];
  }
