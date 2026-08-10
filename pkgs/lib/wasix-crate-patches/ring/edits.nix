# ring: the wasix backend needs cfg-if, which upstream does not depend on, so the
# floor carries that manifest edit alongside the sources. Only 0.17.7 is served:
# the published 0.16.20 fork declares `mod bn_mul_mont_fallback` without shipping
# the file, so that artifact does not compile. 0.17.8+ builds stock (verified).
{...}: {
  edited = ["=0.17.7"];
  stock = ["<0.17.7" ">0.17.7"];
}
