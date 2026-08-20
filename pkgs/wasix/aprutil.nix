# LDAP pulls openldap and, through its SASL, krb5, which needs a resolver wasi
# does not have (see serf). Subversion uses apr-util for buckets and XML, not
# for directory lookups.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage (prev.aprutil.override {ldapSupport = false;}) {
  # apr is PIC-only, and apr-util links it
  passthru.wasix.supportedProfiles = helpers.profiles.pic;
}
