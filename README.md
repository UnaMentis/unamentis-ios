# UnaMentis iOS

Swift 6.0/SwiftUI voice AI learning platform for iOS. Enables 60-90+ minute voice-based learning sessions with sub-500ms latency.

## Quick Start

```bash
# 1. Set up models (symlink to shared models folder)
./scripts/setup-models.sh

# 2. Generate Xcode project from project.yml
xcodegen generate

# 3. Build
xcodebuild -project UnaMentis.xcodeproj -scheme UnaMentis \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Requirements

- Xcode 26 or newer
- iOS 18.0+ deployment target
- XcodeGen (`brew install xcodegen`)
- Shared models folder at `/Users/ramerman/dev/unamentis-models/` (or set `UNAMENTIS_MODELS_PATH`)

## Testing

```bash
./scripts/test-quick.sh          # Unit tests only (fast)
./scripts/test-all.sh            # All tests + 80% coverage enforcement
./scripts/test-integration.sh    # Integration tests only
```

## Architecture

```
UnaMentis/
├── Core/           # Business logic (actors)
│   ├── Audio/      # Audio pipeline, VAD integration
│   ├── Curriculum/ # Curriculum management, progress tracking
│   ├── Persistence/# Core Data stack
│   ├── Session/    # Session management
│   └── Telemetry/  # Metrics, cost tracking
├── Services/       # Provider integrations
│   ├── STT/        # Speech-to-text (7 providers)
│   ├── TTS/        # Text-to-speech (9 providers)
│   ├── LLM/        # Language models (4 providers)
│   └── Protocols/  # Service protocol definitions
├── Intents/        # Siri & App Intents
└── UI/             # SwiftUI views
```

## Shared Documentation

Cross-cutting documentation (client specs, module designs, testing philosophy) lives in the [main UnaMentis repository](https://github.com/UnaMentis/unamentis). See [docs/README.md](docs/README.md) for the full index with links.

## Related Repositories

| Repo | Purpose |
|------|---------|
| [unamentis](https://github.com/UnaMentis/unamentis) | Server infrastructure, documentation, curriculum |
| [unamentis-android](https://github.com/UnaMentis/unamentis-android) | Android client |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). These cover the iOS-specific workflow and link to the project-wide conventions in the [main UnaMentis repository](https://github.com/UnaMentis/unamentis).

To report a security issue, see [SECURITY.md](SECURITY.md).

## License

UnaMentis iOS is released under the MIT License. See [LICENSE](LICENSE) for details.
