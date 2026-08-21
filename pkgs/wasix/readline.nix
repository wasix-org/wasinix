# ncurses auto-threads. In the off-EH profile, <setjmp.h> gates sigsetjmp out
# (readline shares bash's BASH_FUNC_POSIX_SETJMP cache var), so pick plain setjmp.
{
  exposeExtendedPackage,
  packages,
}: let
  offMode = (packages.sameProfile.stdenv.hostPlatform.wasmExceptions or "yes") == "no";
in
  exposeExtendedPackage {
    configureFlags = packages.sameProfile.lib.optionals offMode ["bash_cv_func_sigsetjmp=missing"];
  }
