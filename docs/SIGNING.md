# Signing & keychain approvals

You don't need any of this to use Claude Island. A fresh clone builds ad-hoc
signed and works immediately. This page is for people who rebuild often and
want macOS to stop re-asking for the keychain approval.

## Why approvals reset

The Official API source reads the `Claude Code-credentials` keychain item —
only after you press **Connect Claude account…** (launching the app never
touches the keychain). macOS binds that approval to the app's code signature.
Ad-hoc signatures change on every rebuild, so every rebuild looks like a new
app and the approval resets: you press Connect once per build and macOS asks
for your login password.

A *stable* signing identity keeps the signature constant, so one
"Always Allow" survives rebuilds.

## Option 1 — a local self-signed identity

Create a certificate named `Claude Island Signing`; the Makefile detects that
exact name and uses it automatically:

```sh
cat > /tmp/ci-signing.conf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Claude Island Signing
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF
openssl req -x509 -newkey rsa:2048 -keyout /tmp/ci-key.pem -out /tmp/ci-cert.pem \
  -days 3650 -nodes -config /tmp/ci-signing.conf -extensions ext
openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -out /tmp/ci-identity.p12 -inkey /tmp/ci-key.pem -in /tmp/ci-cert.pem -passout pass:temp
security import /tmp/ci-identity.p12 -k ~/Library/Keychains/login.keychain-db \
  -P temp -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/ci-cert.pem
# let codesign use the key without a per-build prompt (asks your login password once):
security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db
rm /tmp/ci-*.pem /tmp/ci-identity.p12 /tmp/ci-signing.conf
```

The identity lives only in your login keychain — nothing is committed, and
builds from other machines are unaffected. Remove it anytime:

```sh
security delete-identity -c "Claude Island Signing"
```

## Option 2 — an Apple Development certificate

If you have Xcode signed into an Apple ID, you already have one (they're free).
Point the build at it explicitly:

```sh
make SIGN_ID="Apple Development: Your Name (TEAMID)" install
```

## The prompts, explained

- **"codesign wants to sign using key 'Claude Island Signing'"** — the keychain
  guarding the new key. The `set-key-partition-list` line above prevents it; if
  you skipped that line, click **Always Allow** once.
- **"Terminal would like permission to update or delete other applications"** —
  App Management, raised when `make install` replaces an existing copy inside
  /Applications. Approve your terminal once under System Settings → Privacy &
  Security → App Management.
- **"ClaudeIsland wants to use your confidential information stored in
  'Claude Code-credentials'"** — the actual credential read after you press
  Connect. **Always Allow** makes it permanent for the current signature —
  which is forever, once you're on a stable identity.
