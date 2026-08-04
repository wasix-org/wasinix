# shellingham for wasix. nixpkgs' postPatch bakes procps' `ps` into posix/ps.py,
# but procps has no wasix build; dropping it leaves shell detection on bare `ps`.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {postPatch = _: "";}
pyprev.shellingham
