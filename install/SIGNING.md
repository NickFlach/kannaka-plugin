# Code-signing the native installers — come-back checklist

The `release-installers.yml` workflow **already has the signing steps wired in**. They're
inert until you add the cert secrets below. **You don't edit any workflow code** — just add
the GitHub secrets, then cut a new tag. `HAS_SIGN` flips to `true` automatically and the
`.msi`/`.pkg` come out signed (+ notarized on macOS).

> The `.deb` is **not** code-signed — Linux trust is repo-level GPG (apt), not per-file. Nothing to do there.

---

## Windows (.msi — Authenticode)

You need an **Authenticode code-signing certificate** (`.pfx`/`.p12`) from a CA (DigiCert,
Sectigo, SSL.com, …) or an EV token export.

```bash
# 1. base64-encode the .pfx (one line, no wrapping)
#    macOS/Linux:
base64 -i kannaka-cert.pfx | tr -d '\n' > cert.b64
#    Windows PowerShell:
#    [Convert]::ToBase64String([IO.File]::ReadAllBytes("kannaka-cert.pfx")) | Set-Content cert.b64

# 2. add the two secrets
gh secret set WINDOWS_CERT_PFX_BASE64 --repo NickFlach/kannaka-plugin < cert.b64
gh secret set WINDOWS_CERT_PASSWORD   --repo NickFlach/kannaka-plugin   # paste the .pfx password

rm cert.b64
```

## macOS (.pkg — Developer ID Installer + notarization)

You need: a **"Developer ID Installer"** certificate exported as `.p12`, and an
**app-specific password** for `notarytool` (appleid.apple.com → Sign-In and Security).

```bash
# 1. base64-encode the .p12
base64 -i developerid-installer.p12 | tr -d '\n' > cert.b64

# 2. add the secrets
gh secret set MACOS_CERT_P12_BASE64 --repo NickFlach/kannaka-plugin < cert.b64
gh secret set MACOS_CERT_PASSWORD   --repo NickFlach/kannaka-plugin   # the .p12 export password
gh secret set MACOS_SIGN_IDENTITY   --repo NickFlach/kannaka-plugin   # e.g. "Developer ID Installer: Nick Flach (TEAMID)"
gh secret set MACOS_NOTARY_APPLE_ID --repo NickFlach/kannaka-plugin   # your Apple ID email
gh secret set MACOS_NOTARY_TEAM_ID  --repo NickFlach/kannaka-plugin   # 10-char Team ID
gh secret set MACOS_NOTARY_PASSWORD --repo NickFlach/kannaka-plugin   # app-specific password

rm cert.b64
```

---

## Then: trigger a signed build

```bash
git -C kannaka-plugin tag -f v1.3.1            # any new tag works; bump versions first if you like
git -C kannaka-plugin push -f origin v1.3.1
# watch:
gh run watch --repo NickFlach/kannaka-plugin
```

The Actions log will show **"Sign .msi …"** / **"Sign + notarize .pkg …"** running (instead of
being skipped). The release assets `kannaka-setup-windows.msi` and `kannaka-setup-macos.pkg`
are then signed — no SmartScreen / Gatekeeper warnings.

## Secrets at a glance

| Secret | Platform | What it is |
|---|---|---|
| `WINDOWS_CERT_PFX_BASE64` | win | base64 of the Authenticode `.pfx` |
| `WINDOWS_CERT_PASSWORD` | win | `.pfx` password |
| `MACOS_CERT_P12_BASE64` | mac | base64 of the Developer ID Installer `.p12` |
| `MACOS_CERT_PASSWORD` | mac | `.p12` export password |
| `MACOS_SIGN_IDENTITY` | mac | "Developer ID Installer: …" identity string |
| `MACOS_NOTARY_APPLE_ID` | mac | Apple ID email |
| `MACOS_NOTARY_TEAM_ID` | mac | Team ID |
| `MACOS_NOTARY_PASSWORD` | mac | app-specific password |
