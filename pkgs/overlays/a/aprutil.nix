# LDAP pulls openldap and, through its SASL, krb5, which needs a resolver wasi
# does not have (see serf). Subversion uses apr-util for buckets and XML, not
# for directory lookups.
{
  exposeWasixPackage,
  extendPackage,
  package,
  profileSets,
}:
exposeWasixPackage (
  extendPackage (package.override {ldapSupport = false;}) {
    passthru.wasix.supportedProfiles = profileSets.pic;
    # apr is PIC-only, and apr-util links it
  }
)
