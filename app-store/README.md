# Mac App Store preparation

Target: **Ora 0.10.1 (15)**, `com.wangzhangwu.ora`, Apple Silicon, macOS 15+.

This directory is a submission draft, not an App Store approval or upload receipt. The website still advertises the released v0.10.0 DMG until a new public release is actually published.

## Prepared

- Production-ID sandbox candidate, with audio input, outbound client networking, and user-selected file access only.
- Local cache startup fix and original sandbox validation from the preceding task.
- Per-session external AI disclosure before capture and a separate synthetic API test confirmation.
- Privacy tab, menu privacy/support links, bundled dependency licenses and a privacy manifest.
- English and Simplified Chinese listing copy in `metadata/listing.json`, with field-length validation.
- Public privacy/support page sources in `docs/`.
- Review instructions in `REVIEW-NOTES.md`.
- Three screenshots per locale in `screenshots/en-US/` and `screenshots/zh-Hans/`, all 2880 × 1800 RGB JPEGs. These compose real native captures; caption text is explicitly identified as preview content. `screenshots/overview.jpg` is for reviewing the set, not uploading.
- Final verification results in `verification.json`: 194 tests executed, 6 skipped, no failures; six profile-validation cases; a real-audio High replay with outbound network entitlement removed.

## Build

Local inspection only (ad-hoc signed; cannot upload):

```sh
cd macos/Ora
./package.sh --app-store --prepare-only
```

For distribution, use a **macOS App Store provisioning profile** for the production ID and matching-team App Store signing identities. Developer ID / iOS profiles do not substitute for these:

```sh
APP_STORE_APPLICATION_IDENTITY="Apple Distribution: Your Name (TEAMID)" \
APP_STORE_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)" \
APP_STORE_PROFILE="/absolute/path/Ora.provisionprofile" \
  ./package.sh --app-store
```

Output: `.app-store/Ora.pkg`. Use Apple's Transporter to validate and upload the signed package. Upload processing, TestFlight checks, and App Review remain separate. The script deliberately fails when the required profile/identities are absent, wrong-platform, expired, or for a different app. No Developer ID notarization or DMG is used for this route.

## Published website pages

- [Privacy Policy](https://main.d1cdtuylr567og.amplifyapp.com/privacy.html)
- [Help & Support](https://main.d1cdtuylr567og.amplifyapp.com/support.html)

## Unresolved before submission

- App Store Connect login/app record/name availability have not yet been confirmed.
- The local keychain has a Developer ID Application identity, but no App Store application/installer distribution identities. No macOS Ora App Store profile is installed.
- The owner must supply real review contact details, confirm pricing/territories, and complete any current agreements and EU trader requirements in App Store Connect.
- Privacy/support pages were approved by the owner and published to the production website. Browser navigation and exact source-content checks passed; see `website-deployment.json`.
- Confirm third-party AI provider policies and retention before publishing privacy answers. The prepared manifest conservatively discloses optional audio and other user content for app functionality as linked to identity, since external API requests authenticate to a provider account. This is not a claim that default local processing collects speech.
- Complete the live encryption and age-rating questionnaires. No exemption or age rating has been guessed in the draft.
- Physical microphone/Meeting input is hardware-limited, pending retest with an open notebook or external microphone. Only macOS 26.5 on one Apple Silicon Mac was exercised; minimum-version compatibility is not a real-device pass.

## Sources

- [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Privacy disclosures](https://developer.apple.com/app-store/app-privacy-details/)
- [Mac screenshot sizes](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)

Keep local recordings, transcripts, signing credentials, provisioning profiles, and private diagnostics out of this directory and out of git.

Re-render the screenshot set with `swift app-store/render-screenshots.swift` from the repository root. Raw captures are kept for provenance; they do not prove real-time model accuracy or latency.
