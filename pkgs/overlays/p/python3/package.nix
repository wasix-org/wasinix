{exposePackagesWithWasix}: let
  compatibility = {
    supportedProfiles = ["ehpic" "exnrefEhpic"];
    preferredProfile = "exnrefEhpic";
  };
in
  exposePackagesWithWasix {
    python313 = compatibility;
    python314 = compatibility;
    python3 = compatibility;
  }
