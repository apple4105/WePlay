# weplay

In-vehicle display app for iOS — renders the phone UI on the car screen over a local wireless link.

## Requirements

- iOS 16.0+
- Xcode 15+ locally, or GitHub Actions (free for public repos)
- A free Apple ID is enough (sideload with AltStore)

## Build locally

```bash
brew install xcodegen
xcodegen generate
open weplay.xcodeproj
```

## Build in CI

Every push/tag triggers Actions, which produces an unsigned IPA artifact and runs the protocol self-tests.

## Install

1. Download the IPA artifact from the Actions run
2. Open it in AltStore → sign with your Apple ID → install
3. Free certificates expire after 7 days; AltStore refreshes them automatically

## Layout

```
weplay/            sources
  App/             entry point
  Link/         link + session handling
  Output/          display output
  UI/              status screen
Tools/             protocol self-tests (python3 -I Tools/<name>_selftest.py)
project.yml        XcodeGen project description
```

## Notes

- Identity credentials are not stored in this repository; supply them out of band when needed.
- The network to join is shown in the app; iOS remembers it after the first manual join.
