# GhostGPT iOS wrapper

This repository packages the hosted GhostGPT chat in a Capacitor iOS shell. The upstream [GHOST-GPT/GhostGPT repository](https://github.com/GHOST-GPT/GhostGPT) documents the service endpoints; it does not contain the hosted web app source. This wrapper opens the documented chat at <https://ghostgpt.live/chat/>.

The app needs an internet connection and loads the hosted service, so sign-in and chat data are handled by that service. No API keys, certificates, provisioning profiles, or GitHub secrets are used by this project.

## Build an unsigned IPA

The **Build unsigned iOS IPA** workflow runs on pushes to `main` and can also be started from the Actions tab. It builds with code signing disabled and uploads `GhostGPT-unsigned.ipa` as a workflow artifact.

The IPA is unsigned and is not ready for App Store distribution or direct installation on a standard iPhone. It is a build artifact for later signing or inspection.
