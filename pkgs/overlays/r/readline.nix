# ncurses auto-threads. In the off-EH profile, <setjmp.h> gates sigsetjmp out
# (readline shares bash's BASH_FUNC_POSIX_SETJMP cache var), so pick plain setjmp.
{
  exposeWasixExtendedPackage,
  packages,
}: let
  offMode = (packages.sameProfile.stdenv.hostPlatform.wasmExceptions or "yes") == "no";
in
  exposeWasixExtendedPackage {
    configureFlags = packages.sameProfile.lib.optionals offMode ["bash_cv_func_sigsetjmp=missing"];
  }
