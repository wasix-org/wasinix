//! Whether outward writes happen. Every publisher and deployer takes an
//! Effects and consults it at the write itself, so a dry run traverses the
//! same code, prints the same plan, and cannot drift from the real path.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effects {
    Apply,
    DryRun,
}

impl Effects {
    pub fn from_dry_run(dry_run: bool) -> Effects {
        if dry_run {
            Effects::DryRun
        } else {
            Effects::Apply
        }
    }

    pub fn is_dry_run(self) -> bool {
        matches!(self, Effects::DryRun)
    }
}
