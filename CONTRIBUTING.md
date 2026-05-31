# Contributing to UnaMentis iOS

Thank you for your interest in contributing. This is the iOS client for the UnaMentis voice AI learning platform.

The project-wide contribution conventions (branch strategy, commit messages, PR process, code review criteria, CI/CD requirements) are maintained in the main repository and apply here:

https://github.com/UnaMentis/unamentis/blob/main/docs/CONTRIBUTING.md

This document adds the iOS-specific setup and workflow.

## Requirements

- Xcode 26 or newer (the project targets iOS 18 and watchOS 26)
- [XcodeGen](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`)
- SwiftLint and SwiftFormat (`brew install swiftlint swiftformat`)
- `xcbeautify` for readable test output (`brew install xcbeautify`)

## First-Time Setup

The Xcode project is generated from `project.yml`. The generated `UnaMentis.xcodeproj/project.pbxproj` is not committed.

```bash
./scripts/setup-models.sh    # create the models symlink to the shared models folder
xcodegen generate            # generate the Xcode project from project.yml
```

Re-run `xcodegen generate` after modifying `project.yml`.

## Build

```bash
xcodebuild -project UnaMentis.xcodeproj -scheme UnaMentis \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Test

The unified test runner mirrors CI:

```bash
./scripts/test-quick.sh          # unit tests only (fast)
./scripts/test-all.sh            # all tests + coverage enforcement
./scripts/test-integration.sh    # integration tests only
```

## Lint and Format

```bash
./scripts/format.sh
./scripts/lint.sh
./scripts/health-check.sh        # lint + quick tests
```

## Code Style

Follow `.swiftlint.yml`, `.swiftformat`, and `docs/ios/IOS_STYLE_GUIDE.md`. Key rules: 4-space indentation, 120-character lines, no force unwrapping, prefer `let` over `var`, document public APIs, accessibility labels on all interactive elements, and localized strings for user-facing text.

Swift 6 strict concurrency is required. Services are actors, view models are `@MainActor`, and types crossing actor boundaries are `Sendable`.

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `perf:`, `ci:`, `chore:`.

## Definition of Done

Run `/validate` (or `./scripts/health-check.sh`) and ensure it passes before marking any work complete.

## Code of Conduct

Participation is governed by the project [Code of Conduct](CODE_OF_CONDUCT.md).
