# qhull for wasix. The static cross stdenv builds only libqhullstatic*.a, so linking
# what qhull_r.pc asks for fails with "unable to find library -lqhull_r".
{
  exposeExtendedPackage,
  profileSets,
}:
exposeExtendedPackage {
  postInstall = ''
    ln -s libqhullstatic_r.a "$out/lib/libqhull_r.a"
    ln -s libqhullstatic.a "$out/lib/libqhull.a"
  '';
  # libqhullcpp throws, so the off profile (-fno-exceptions) can't compile it.
  passthru.wasix.supportedProfiles = profileSets.withEh;
}
