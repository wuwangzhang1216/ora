# Mac App Store preparation

## Current release — 0.10.2 (16), A3 icon

**Apple confirmed 1 Item Submitted; 0.10.2 (16) is Waiting for Review.** The owner requested the A3 update and App Store release. The previous 0.10.1 submission was cancelled, its draft updated, and build 16 selected. Apple processed the new build and the existing system-encryption declaration was saved. Release is now **automatic after approval**, with all 175 countries or regions saved as **Available on App Release**. The existing free price schedule is retained. No App Review approval or live App Store release is claimed. See `apple-upload-0.10.2.json` and `apple-review-submission-0.10.2.json`.

The public [GitHub release](https://github.com/wuwangzhang1216/ora/releases/tag/v0.10.2) and [website](https://main.d1cdtuylr567og.amplifyapp.com/) serve the notarized v0.10.2 DMG. Safari download, checksum, mounted version and A3 icon checks passed. See `../release-notes/v0.10.2-publication.json`.

## A3 icon confirmation

The actual Xcode upload payload for build 16 was recovered and expanded. Its icon resources match A3. Apple also extracted A3 correctly: the build-specific CDN image shows A3, while the app-level header/list references a different, older ring image. No rebuild or resubmission was needed. See [the audit and Apple image comparison](icon-verification-0.10.2/README.md). The public storefront appearance remains pending review/release.

## Earlier submission — 0.10.1 (15)

The notes below record the earlier preparation and submission as observed on November 14; its review submission was superseded by 0.10.2.

Target: **Ora 0.10.1 (15)**, `com.wangzhangwu.ora`, Apple Silicon, macOS 15+.

This directory contains local signing, Apple upload/processing receipts, and submission drafts. Apple has processed **0.10.1 (15)** and the owner-authorized review submission is now **Waiting for Review**; this is not App Review approval or a public release. The website still advertises the released v0.10.0 DMG until a new public release is actually published.

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

## Submission status and release decisions

Apple’s live **Add for Review** check now passes. The owner explicitly confirmed third-party content rights and external-service policy consistency, and authorized publishing the prepared App Privacy declaration. Both are saved/published. The owner subsequently authorized final **Submit for Review**, accepting the disclosed validation gaps. Apple confirmed **1 Item Submitted**, and version **0.10.1 (15)** is **Waiting for Review**. See `apple-review-submission.json` for the submission ID and URL. Release remains manual after approval. Build 15 and the three sandbox usage explanations are attached and confirmed after reloading.

- App Store Connect record [6834983543](https://appstoreconnect.apple.com/apps/6834983543/distribution) has been created as **Ora — Live Translation**, macOS **0.10.1**, Waiting for Review. English and Simplified Chinese names, subtitles, descriptions, keywords, URLs, three screenshots each, reviewer instructions, and manual release mode are saved. No app sign-in is required. Apple calculated **4+** from the completed age questionnaire; the app is not designated Made for Kids.
- The owner completed SMS verification. The separate Paid Apps Agreement is **Pending User Info**, Free Apps Agreement **Active**. This no longer prevents creating the free Ora record; existing paid-contract tax/bank details were not changed.
- Xcode Organizer uploaded the signed archive successfully and Apple processed build 15. Export compliance was completed based on the current macOS implementation; Missing Compliance cleared and the build is Ready to Submit. See `apple-upload.json` for the actual Xcode-exported package hash, signing certificate/profile, and state. The original `distribution-build.json` package was repackaged by Xcode; its hash is not the upload payload hash. TestFlight installation acceptance was not performed; the owner accepted this gap before review submission. App Review approval remains outstanding.
- Owner-provided review contact details are saved privately in App Store Connect. Free pricing is saved and zero current prices verified; availability/territories and EU trader requirements still need confirmed owner information. Personal contact values are intentionally excluded from this public repository.
- Privacy/support pages were approved by the owner and published to the production website. Browser navigation and exact source-content checks passed; see `website-deployment.json`.
- The owner explicitly confirmed supported external-service policies match the prepared privacy declaration. App Privacy now discloses optional audio and other user content for App Functionality, linked to identity, no tracking. This is not a claim that default local processing uploads speech. Update the declaration if backend practices change.
- Both live encryption and age-rating questionnaires are complete. `encryption-inventory.json` records why the macOS dependency uses system CryptoKit, correcting the earlier assumption that resolving swift-crypto meant BoringSSL encryption was bundled. The App Privacy label is **published**, with explicit owner authorization.
- Physical microphone/Meeting input is hardware-limited, pending retest with an open notebook or external microphone. Only macOS 26.5 on one Apple Silicon Mac was exercised; minimum-version compatibility is not a real-device pass.

## Sources

- [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Privacy disclosures](https://developer.apple.com/app-store/app-privacy-details/)
- [Mac screenshot sizes](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)

Keep local recordings, transcripts, signing credentials, provisioning profiles, and private diagnostics out of this directory and out of git.

Re-render the screenshot set with `swift app-store/render-screenshots.swift` from the repository root. Raw captures are kept for provenance; they do not prove real-time model accuracy or latency.

The two signing private keys were imported into macOS Keychain. Temporary PEM private-key files were removed after the app and installer were both successfully signed. Certificates and provisioning files remain outside git.
