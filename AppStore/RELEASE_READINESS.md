# Paperdesk release preparation

Updated 1 November 2026. This is a release checklist for the current local app, not evidence of App Store approval or a signed distribution build. No app has been uploaded and no public support site has been published.

## Confirmed owner information

- Publisher display name: **Navneet**, supplied by the owner.
- Public support and privacy URLs: **not set up**.
- Public support contact: **kvnavneet@gmail.com**, supplied by the owner. The local HTML drafts are not published.
- Developer-account seller identity, team and production bundle ID: still unconfirmed. The supplied display name does not establish the account seller identity.

## Owner decisions required

- Confirm the app name and rights to the name/icon/content. Paperdesk remains provisional.
- Confirm copyright rights and the legal seller identity; supply the Apple Developer team and registered production bundle ID. `com.local.Paperdesk` is a local development identifier, not a production identity.
- Publish `privacy.html` and `support.html` on an owner-controlled HTTPS site; review the supplied support contact and policy before hosting; Navneet is included as the owner-supplied publisher name. Enter the final Privacy Policy URL and Support URL in App Store Connect and link the privacy page inside the app. The supplied HTML has no invented addresses or domains.
- Choose pricing, territories, age-rating answers, export-compliance answers, licensing, and platform availability. Answer the current App Store Connect questionnaires against the final signed build. Do not infer an encryption exemption from the app's lack of networking.
- Review the policy text against the publisher's actual support practices, hosting logs, and any added SDKs. No network/analytics SDK was found in the reviewed app source.

## Resources supplied

- `Paperdesk/PrivacyInfo.xcprivacy`: no tracking, no developer data collection, required reason declarations for app-only preferences and owned-file metadata.
- `Paperdesk/Paperdesk-macOS.entitlements`: sandbox and user-selected file read/write only. No network client/server, broad filesystem, cloud container, or temporary exceptions.
- `AppStore/Release.xcconfig`: optimized Release defaults attached to the app Release configuration, without a team or certificate.
- `AppStore/privacy.html`, `AppStore/support.html`: static accessible pages with local CSS, no tracking scripts or remote assets. Publisher name and support email are populated; support-data retention and final policy review remain pending before hosting.
- `AppStore/METADATA.md`: copy draft and concrete review route.

## Privacy audit and manifest integration

`@AppStorage` stores the finger-drawing and on-device-study preferences in the app's own defaults. `CA92.1` covers app-private defaults. File modification timestamps are used in the app-owned PDF/OCR/study cache fingerprints and backup consistency checks. `C617.1` covers metadata inside the app container. Those are the two categories in the supplied manifest.

Drawing save ordering now uses an in-app monotonic revision counter. No `DispatchTime` or system-uptime API remains in the app source; no system-boot-time reason is declared.

The manifest is integrated once in Copy Bundle Resources and verified inside both unsigned archives. macOS entitlements apply only to the macOS SDK; iOS has no macOS sandbox entitlement file. The empty collection array does not replace the separate App Store Connect privacy questionnaire. The publisher must confirm the final signed binary and any partner practices.

Apple primary references:

- [Required reason API categories and accepted purposes](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Adding required reason API entries](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)
- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [User-selected read/write entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)
- [Review guidelines, including policy links](https://developer.apple.com/app-store/review/guidelines/)

## Integrated release configuration

- Version 1.0.0, build 1; increment the build for each upload.
- Optimized whole-module Release compilation, dSYM symbols, testability disabled.
- macOS sandbox, user-selected file read/write and hardened runtime configured; no incoming/outgoing network entitlement.
- Privacy resource bundled on both platforms; macOS entitlements are configuration-only, not copied resources.
- iPhone/iPad device families; minimum macOS 14 and iOS 17. Real glass is available on newer systems; older systems use materials and Reduce Transparency uses opaque chrome.
- Unsigned macOS universal (Apple silicon and Intel) and iOS device archives compile successfully. Unsigned archives are local verification artifacts, not uploadable distribution builds.

The owner still must register a production bundle ID and team, create signing credentials, archive with signing enabled, validate in Organizer and test that signed build. The current `com.local.Paperdesk` is provisional. No signing identity was installed during verification.

## Local verification completed

The 1 November integrated source passed 48 Mac tests across 10 suites and a generic iOS Simulator build. Dedicated 10,000-page native-text and mixed-content fixtures passed cold and cached search checks; a 1,000-page durable OCR fixture passed resume/export/backup checks. Earlier unsigned Release archives and bundled privacy manifests passed, but those archives must be refreshed and signed after the production team and bundle ID are supplied. See TEST_REPORT.md for timings and hardware/visual-review limitations.

Back up any prototype library before moving to a signed sandboxed build or changing the bundle identifier: the production container may differ. Restore the exported backup through Library options after installing the signed build.

## Evidence to collect before submission

Run Release builds, XCTest, and the existing integration scripts on the final sources; record actual results in TEST_REPORT.md. Test on physical iPhone/iPad for Pencil pressure, double-tap/squeeze, background-save completion, and handwriting persistence. Verify the system-model unavailable state and extractive fallback, accessibility with VoiceOver, keyboard use, Dynamic Type, Reduce Transparency, light/dark appearance, and smallest supported device layouts.

Use a large PDF and a scanned PDF to verify bounded UI work, cancellation, progress, and memory. Reopen after notes, annotations, OCR, rename, removal, export, and backup restore. Test failed writes and malformed backup handling. Check that normal export preserves expected interactive PDF elements, while searchable export clearly discloses flattening. Confirm review copy contains no copyrighted user PDFs or personal notes.

In Xcode Organizer, validate each signed archive and inspect its privacy report, entitlements, asset warnings, and exported symbols. Check the macOS signed entitlements contain the sandbox/file access keys and no network grants. Test the same signed build installed through TestFlight or the selected distribution route. Then prepare real screenshots from that build, not mockups, for every required device family.

## Known boundaries to describe accurately

No automatic cloud sync or publisher account is implemented. Saving a user-exported backup to iCloud Drive is a user-controlled file transfer, not built-in sync. No server API key, login, or subscription is needed for the app's local reading/study flow. On-device AI availability depends on supported Apple hardware, OS, enabled Apple Intelligence, and a ready local model. Extractive study works without that model; answers are study aids and require checking source pages.

Removing a library document retains a local recovery copy in `Removed`; it is not permanent erasure. Current backups contain active documents and sidecars, not the Removed archive. The app needs a clear permanent-erasure/recovery product decision before promising complete in-app deletion. Backups and exports are plaintext files; users control their destination and protection.
