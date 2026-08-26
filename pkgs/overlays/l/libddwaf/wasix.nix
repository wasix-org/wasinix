# libddwaf for wasix. ddtrace dlopens the shared library when appsec is enabled;
# the static archive remains available to other consumers. Version tracks
# ddtrace's LIBDDWAF_VERSION. Dependencies are vendored, with rapidjson's
# ExternalProject source supplied from the store.
{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {patches = [./size_t-not-in-all_types-variant.patch];}
