# qhull for wasix. The static cross stdenv builds only libqhullstatic*.a, so linking
# what qhull_r.pc asks for fails with "unable to find library -lqhull_r".
{
  exposeWasixExtendedPackage,
  profileSets,
}:
exposeWasixExtendedPackage {
  passthru.wasix.supportedProfiles = profileSets.withEh;
  postInstall = ''
    ln -s libqhullstatic_r.a "$out/lib/libqhull_r.a"
    ln -s libqhullstatic.a "$out/lib/libqhull.a"
  '';
}
