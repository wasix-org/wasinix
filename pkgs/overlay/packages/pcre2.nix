# pcre2grep's callout-fork feature uses fork() (absent on WASIX); disable just
# that — libpcre2 and the rest of pcre2grep build fine. Consumed by grep (-P) and
# less for PCRE regex.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  configureFlags = ["--disable-pcre2grep-callout-fork"];
}
prev.pcre2
