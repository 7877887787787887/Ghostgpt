# Signing-ready iOS build

## Intent

Make the existing native GhostGPT build ready to create a properly signed device IPA when an authorized Apple signing identity is supplied. The default build must remain unsigned and must never require, print, or commit credentials.

## Goals

- Keep the existing unsigned artifact path unchanged.
- Add an opt-in signing workflow for an authorized Apple Developer team.
- Require repository secrets for the certificate, certificate password, and matching provisioning profile.
- Fail before packaging if the profile bundle identifier does not match `io.corelo.ghostgpt`.

## Non-goals

- Creating, collecting, or storing Apple credentials.
- Using shared, enterprise, or third-party signing certificates.
- Making an iPhone-only installation service.

## Approach

Add a separate manually-dispatched workflow. It decodes supplied secrets only on the GitHub-hosted macOS runner, installs the profile, imports the certificate into a temporary keychain, builds the existing Capacitor-generated native project with signing enabled, and uploads a signed IPA artifact. The existing unsigned workflow remains the test/build default.
