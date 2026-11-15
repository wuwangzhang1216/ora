# App Review notes — Ora 0.10.1 (15)

Draft for App Store Connect. No account or payment is required to test local processing. The local package is now App Store distribution-signed and its signatures/profile have been verified. Xcode has uploaded it and Apple has processed build 15 (Ready to Submit). It has now been formally submitted for App Review with explicit owner authorization (Waiting for Review). It has not been publicly released.

## Where to find the app

Ora is a menu-bar app (no Dock icon). After opening it, click the circular Ora icon in the top menu bar. Choose Preferences to configure it, Start Listening to capture audio, and Show Caption Window if the floating captions are hidden. The configurable keyboard shortcut also starts and stops listening. The listening state is visible in the menu and caption window.

## Test the default local path

1. On an Apple Silicon Mac running macOS 15 or later, open Preferences → General. Choose Local (Qwen ASR), MLX Swift, and Standard quality. Select a target language different from the spoken language.
2. Allow the initial model download to finish. This downloads model assets from Hugging Face; it does not upload speech. The default recognition model is approximately 2.3 GB and the Standard translator approximately 1.7 GB; storage and download requirements vary by model revision.
3. For microphone input, choose Microphone and allow the macOS microphone request, then speak. A MacBook must be open when using its built-in microphone; an external microphone can be used in clamshell mode.
4. For system audio, choose System Audio, start listening, and allow Screen & System Audio Recording permission if requested. Quit and reopen Ora after changing permission if needed. Play an English spoken video or audio sample in another app and observe the original text and translated captions. Ora consumes the audio samples and does not display or store screen frames.
5. Stop listening. Open Transcript History from the Ora menu, select the session, and export it to a location you choose. History contains text, not raw audio. Privacy and Help & Support links are available in the menu and in Preferences → Privacy.

The microphone, system-audio, and Meeting choices are audio sources. There is no always-on recording. Start Listening initiates capture and Stop Listening ends it. The app requires the user to grant the relevant macOS permission.

## Other features

- High and Extra High choose larger on-device translation models and need additional memory, storage, and initial downloads. They are optional. No executable update or plugin is downloaded by the app. The bundled Swift/Metal runtime is signed with the app; downloaded files are model assets.
- Nemotron and Apple streaming recognition are labeled experimental, currently configured for English. Apple recognition requires macOS 26 or later and installs system-managed language assets.
- Rapid-MLX is an optional connection to a separately running server. RealRouter is an optional external API integration requiring the user's own key. Neither is required for the core local feature set. The app contains no external purchase or subscription flow.
- Before each session using either external backend, a confirmation identifies the actual loaded server and the audio/text it receives. Cancel leaves capture stopped. Stop Listening ends session permission. API keys are stored in macOS Keychain. Save & Test APIs separately confirms sending only a synthetic speech/text sample, not microphone audio or history.
- Generated recognition and translations may be inaccurate. The app does not promise professional interpretation accuracy or a fixed end-to-end latency.

## Developer verification and remaining gates

Verified on one Apple Silicon Mac running macOS 26.5: enforced App Sandbox, local Standard/High recognition and translation, real ScreenCaptureKit system-audio capture, local history, save-panel export, and offline cached model startup. The previous full model suite covered 16 scene/tier combinations; text and semantic failures are documented separately and were not counted as accuracy passes.

Physical microphone and Meeting speech acceptance remain **hardware-limited, pending retest**: the test MacBook is in clamshell mode with the built-in microphone selected. Entering Listening without an error is not a microphone pass. macOS 15, other hardware, and Extra High/experimental recognizers have not been validated as part of this store preparation.

Build 15 is uploaded and processed; owner-provided contact details, free pricing, encryption and age-rating answers are saved. Content rights and privacy declarations have been owner-confirmed and saved/published. The owner authorized final Submit for Review and accepted the disclosed validation gaps. Apple confirmed 1 Item Submitted; version 0.10.1 (15) is Waiting for Review. Before public release: confirm availability/territories and app-level EU trader status, and close or explicitly accept outstanding validation gaps. Do not paste private benchmark transcripts or API keys into review notes.
