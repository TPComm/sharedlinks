# iOS app

SwiftUI for iOS 18+, built with Xcode 27.2 (CI pins `/Applications/Xcode_27.2.app`; point
`DEVELOPER_DIR` at your Xcode 27 if `xcodebuild -version` shows an older one).

- `Links/`: the app (`AppModel.swift`, `Views/`, `Intents/`)
- `LinksShare/`: the Share Extension; `LinksWidgets/`: Home and Lock Screen widgets
- `LinksKit/`: the Swift package all three use: API client, models, the session in the App Group
  keychain, the on-disk inbox cache. Put shared logic here, with tests in `LinksKit/Tests`.
- `LinksUITests/`: XCUITests against a real server (`LinksServer.swift` sets up state through the API)

```bash
(cd LinksKit && swift test)
xcodebuild build-for-testing -project Links.xcodeproj -scheme Links -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build ARCHS=arm64
LINKS_UI_TEST_ACTION=test-without-building scripts/ui-tests.sh   # add -only-testing:LinksUITests/LinksUITests/<test> for one
```

`scripts/ui-tests.sh` needs Bun on `PATH` (it adds `~/.bun/bin`): it starts `server/` with an empty
database, mints the tokens the tests use, and runs them on a dedicated "Links UI Tests" Simulator
it creates. The tests skip themselves when run any other way.

## Rules

- Settings go in `Config.xcconfig`, not the project file. Simulator builds sign ad hoc;
  `DEVELOPMENT_TEAM` is only for devices.
- The targets use file-system synchronized groups, so a new file in a target's folder is picked up
  without editing `project.pbxproj`.
- Every shipped bundle (app, Share Extension, widgets) has its own `PrivacyInfo.xcprivacy`; declare
  any new required-reason API in each bundle that uses it, or App Store Connect rejects the build.
- The UI tests set `LINKS_UI_TESTS=1`, which skips the welcome tour, tips and the badge prompt.
- Build and test on a Mac before pushing: CI's macOS minutes are limited (see the root `AGENTS.md`).
