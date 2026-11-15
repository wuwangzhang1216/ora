# Mac App Store preparation

Target: **Ora 0.10.1 (15)**, `com.wangzhangwu.ora`, Apple Silicon, macOS 15+.

This directory contains local signing, Apple upload/processing receipts, and submission drafts. Apple has processed **0.10.1 (15)** and its TestFlight build status is **Ready to Submit**; this is not App Review approval or a public release. The website still advertises the released v0.10.0 DMG until a new public release is actually published.

## Prepared

- Production-ID sandbox app and signed `.app-store/Ora.pkg`, with audio input, outbound client networking, and user-selected file access only. Matching-team Mac App Distribution and Mac Installer Distribution certificates are installed in macOS Keychain, and the App Store macOS profile is embedded. Local signature/profile checks passed; see `distribution-build.json`.
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

Output: `.app-store/Ora.pkg`. Use Apple's Transporter for this package, or Xcode Organizer for an app archive. This submission used Xcode after Transporter installation stalled; see `apple-upload.json` for the actual exported upload package. Upload processing, TestFlight checks, and App Review remain separate. The script deliberately fails when the required profile/identities are absent, wrong-platform, expired, or for a different app. No Developer ID notarization or DMG is used for this route.

## Published website pages

- [Privacy Policy](https://main.d1cdtuylr567og.amplifyapp.com/privacy.html)
- [Help & Support](https://main.d1cdtuylr567og.amplifyapp.com/support.html)

## Unresolved before submission

Apple’s live **Add for Review** preflight currently lists **two blockers**: Content Rights Information, and publication of the App Privacy declaration. This check did not submit the app to reviewers. Build 15 and the three sandbox usage explanations are attached and confirmed after reloading.

- App Store Connect record [6834983543](https://appstoreconnect.apple.com/apps/6834983543/distribution) has been created as **Ora — Live Translation**, macOS **0.10.1**, Prepare for Submission. English and Simplified Chinese names, subtitles, descriptions, keywords, URLs, three screenshots each, reviewer instructions, and manual release mode are saved. No app sign-in is required. Apple calculated **4+** from the completed age questionnaire; the app is not designated Made for Kids.
- The owner completed SMS verification. The separate Paid Apps Agreement is **Pending User Info**, Free Apps Agreement **Active**. This no longer prevents creating the free Ora record; existing paid-contract tax/bank details were not changed.
- Xcode Organizer uploaded the signed archive successfully and Apple processed build 15. Export compliance was completed based on the current macOS implementation; Missing Compliance cleared and the build is Ready to Submit. See `apple-upload.json` for the actual Xcode-exported package hash, signing certificate/profile, and state. The original `distribution-build.json` package was repackaged by Xcode; its hash is not the upload payload hash. TestFlight installation acceptance and App Review remain outstanding.
- Owner-provided review contact details are saved privately in App Store Connect. Free pricing is saved and zero current prices verified; availability/territories and EU trader requirements still need confirmed owner information. Personal contact values are intentionally excluded from this public repository.
- Privacy/support pages were approved by the owner and published to the production website. Browser navigation and exact source-content checks passed; see `website-deployment.json`.
- Confirm third-party AI provider policies and retention before publishing privacy answers. The prepared manifest conservatively discloses optional audio and other user content for app functionality as linked to identity, since external API requests authenticate to a provider account. This is not a claim that default local processing collects speech.
- Both live encryption and age-rating questionnaires are complete. `encryption-inventory.json` records why the macOS dependency uses system CryptoKit, correcting the earlier assumption that resolving swift-crypto meant BoringSSL encryption was bundled. The App Privacy label remains an **unpublished draft** pending provider-policy/owner review.
- Physical microphone/Meeting input is hardware-limited, pending retest with an open notebook or external microphone. Only macOS 26.5 on one Apple Silicon Mac was exercised; minimum-version compatibility is not a real-device pass.

## Sources

- [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Privacy disclosures](https://developer.apple.com/app-store/app-privacy-details/)
- [Mac screenshot sizes](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)

Keep local recordings, transcripts, signing credentials, provisioning profiles, and private diagnostics out of this directory and out of git.

Re-render the screenshot set with `swift app-store/render-screenshots.swift` from the repository root. Raw captures are kept for provenance; they do not prove real-time model accuracy or latency.

The two signing private keys were imported into macOS Keychain. Temporary PEM private-key files were removed after the app and installer were both successfully signed. Certificates and provisioning files remain outside git.
