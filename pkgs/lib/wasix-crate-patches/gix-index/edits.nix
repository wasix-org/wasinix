# gix-index: WASIX libc exposes stat timestamps as timespec fields. The 0.40
# floor is the same cfg widening against the older tree; versions between the
# two floors are unvetted rather than stock.
{...}: {
  edited = ["=0.40.1" ">=0.49.0"];
}
