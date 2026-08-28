# LDAP

Normal web administration account:

```text
uid=webadmin,ou=Internal,ou=Users,dc=<HOSTNAME_FQDN>
```

Password: `LDAP_ADMIN_PASSWORD` from `.env`.

Use this account for phpLDAPadmin and StepCA Web. The RootDN `uid=admin,dc=<HOSTNAME_FQDN>` is reserved for bootstrap and recovery.

## Verifying the `webadmin` bind

```bash
docker exec openldap sh -c '
LDAPTLS_CACERT=/run/secrets/ldap/ca.crt \
ldapwhoami -x -H ldaps://localhost:636 \
-D "uid=webadmin,ou=Internal,ou=Users,dc=<HOSTNAME_FQDN>" \
-y /run/secrets/ldap-admin-password
'
```

A successful bind prints `dn:uid=webadmin,ou=Internal,ou=Users,dc=<HOSTNAME_FQDN>`.
