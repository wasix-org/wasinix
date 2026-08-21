# GSSAPI means linking krb5, which needs a resolver: res_nsearch, res_ninit,
# dn_expand and the ns_rr parsers, none of which wasi-libc has in any form, and
# krb5 defines its DNS lookup unconditionally. Serf keeps http and https; svn
# over https loses Kerberos and SPNEGO, not basic or digest auth. The stub
# stands in for the argument nixpkgs interpolates before the flag is dropped.
# scons names shared objects .os, which wasixcc does not read as objects
# (WASIX-TODO.md).
{
  exposePackage,
  extendPackage,
  package,
  packages,
  profileSets,
}:
exposePackage (
  let
    noKerberos =
      packages.sameProfile.runCommand "krb5-unavailable" {outputs = ["out" "dev"];}
      "mkdir -p \"$out\" \"$dev\"";
  in
    extendPackage (package.override {libkrb5 = noKerberos;}) {
      patches = [./patches/wasi-shared-object-suffix.patch];
      # apr is PIC-only, and serf links it
      passthru.wasix.supportedProfiles = profileSets.pic;
      preConfigure = old:
        packages.sameProfile.lib.concatStringsSep "\n"
        (builtins.filter (l: !(packages.sameProfile.lib.hasInfix "GSSAPI=" l)) (packages.sameProfile.lib.splitString "\n" old));
    }
)
