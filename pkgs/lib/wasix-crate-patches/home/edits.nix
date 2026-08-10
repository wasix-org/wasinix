# home: `home_dir_inner` is gated on unix, so wasix builds hit a missing-function
# error; the floor patches widen that gate. 0.5.12 narrowed the upstream gate
# from `any(unix, redox)` to `unix`, so each release since 0.5.11 needs its own
# floor. Below 0.5.11 is unvetted and hard-fails.
{...}: {
  edited = [">=0.5.11"];
}
