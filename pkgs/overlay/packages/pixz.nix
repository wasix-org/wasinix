# nixpkgs puts libtool and the man page toolchain in buildInputs, so a cross
# build resolves them for the target; the override keeps them native, and
# nativeBuildInputs is what puts a2x on PATH. The configure flags answer probes
# autoconf refuses to run when cross compiling.
{
  prev,
  final,
  helpers,
  ...
}:
helpers.extendPackage (prev.pixz.override {
  inherit
    (final.buildPackages)
    libtool
    asciidoc
    libxslt
    libxml2
    docbook_xml_dtd_45
    docbook_xsl
    ;
}) {
  passthru.wasix.smokeTest = false;
  configureFlags = [
    "ac_cv_file_src_pixz_1=no"
    "ac_cv_func_malloc_0_nonnull=yes"
    "ac_cv_func_realloc_0_nonnull=yes"
  ];
  nativeBuildInputs = with final.buildPackages; [
    asciidoc
    libxslt
    libxml2
    docbook_xml_dtd_45
    docbook_xsl
  ];
}
