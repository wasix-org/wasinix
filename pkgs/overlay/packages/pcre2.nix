# pcre2grep's callout-fork feature uses fork() (absent on WASIX); disable just
# that, the rest builds fine. Consumed by grep (-P) and less for PCRE regex.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.pcre2 {
  configureFlags = ["--disable-pcre2grep-callout-fork"];
}
