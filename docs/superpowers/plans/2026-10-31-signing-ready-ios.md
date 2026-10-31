# Signing-ready iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an authorized, opt-in Apple signing workflow without changing the unsigned build path.

**Architecture:** The current unsigned workflow continues to compile and package the native app. A distinct manual GitHub Actions workflow creates a temporary keychain, imports credential secrets, validates that the installed provisioning profile is for `io.corelo.ghostgpt`, and exports a signed IPA.

**Tech Stack:** GitHub Actions, macOS runner, Xcode, Capacitor.

**Spec:** `docs/superpowers/specs/2026-10-31-signing-ready-ios-design.md`

## Global Constraints

- Never commit certificates, profiles, passwords, Apple IDs, or signing keys.
- The unsigned workflow remains unchanged and available without secrets.
- The signing workflow runs only with `workflow_dispatch`.

## Review Focus

- Missing signing secrets fail before a device IPA is emitted.
- A profile for a different bundle ID fails validation.
- A failed signed build never overwrites or labels an unsigned IPA as signed.
- The temporary keychain is removed even after a failed build.
- The signed artifact name is distinct from the unsigned artifact name.

---

### Task 1: Add signing workflow

**Files:**
- Create: `.github/workflows/build-signed-ipa.yml`
- Test: workflow shell validation in the same file

**Interfaces:**
- Consumes: repository secrets `IOS_SIGNING_CERTIFICATE_BASE64`, `IOS_SIGNING_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, and `IOS_TEAM_ID`.
- Produces: `GhostGPT-signed-iOS-IPA` workflow artifact.

- [ ] **Step 1: Write preflight checks**

Validate every required secret is present; decode to a temporary directory; decode the profile with `security cms`; require application identifier suffix `io.corelo.ghostgpt` and the supplied team identifier.

- [ ] **Step 2: Verify preflight rejects the wrong profile**

Run: workflow with a profile whose `application-identifier` does not end in `io.corelo.ghostgpt`.
Expected: FAIL before `xcodebuild`.

- [ ] **Step 3: Implement the isolated signed build**

Generate the existing Capacitor project, install the native source files as the unsigned workflow does, import the supplied `.p12` into a temporary keychain, and run `xcodebuild` with `CODE_SIGN_STYLE=Manual`, `DEVELOPMENT_TEAM`, and the resolved profile UUID.

- [ ] **Step 4: Package and verify the signed app**

Require `codesign --verify --deep --strict` to succeed before packaging `Payload/App.app` and uploading `GhostGPT-signed.ipa`.

- [ ] **Step 5: Clean up secrets**

Use an `always()` cleanup step to delete the temporary keychain, temporary provisioning directory, and all decoded signing files.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build-signed-ipa.yml docs/superpowers
git commit -m "ci: add opt-in signed iOS build"
```
