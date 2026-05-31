# UnaMentis iOS Documentation

iOS-specific documentation for the UnaMentis voice AI learning platform.

---

## iOS Development

| Document | Description |
|----------|-------------|
| [ios/IOS_STYLE_GUIDE.md](ios/IOS_STYLE_GUIDE.md) | **Mandatory** iOS coding standards |
| [ios/IOS_BEST_PRACTICES_REVIEW.md](ios/IOS_BEST_PRACTICES_REVIEW.md) | Platform compliance audit |
| [ios/VISUAL_ASSET_SUPPORT.md](ios/VISUAL_ASSET_SUPPORT.md) | Visual content display system |
| [ios/PRONUNCIATION_GUIDE.md](ios/PRONUNCIATION_GUIDE.md) | TTS pronunciation enhancement |
| [ios/SPEAKER_MIC_BARGE_IN_DESIGN.md](ios/SPEAKER_MIC_BARGE_IN_DESIGN.md) | Voice interruption handling |
| [ios/KYUTAI_POCKET_RUST_CANDLE_PATH.md](ios/KYUTAI_POCKET_RUST_CANDLE_PATH.md) | Kyutai Pocket TTS Rust/Candle path |
| [APP_STORE_COMPLIANCE.md](APP_STORE_COMPLIANCE.md) | App Store compliance documentation |

---

## iOS Testing

| Document | Description |
|----------|-------------|
| [testing/AI_SIMULATOR_TESTING.md](testing/AI_SIMULATOR_TESTING.md) | Simulator testing with MCP |
| [testing/DEBUG_TESTING_UI.md](testing/DEBUG_TESTING_UI.md) | Built-in troubleshooting tools |
| [testing/QA_COVERAGE_AUDIT_REPORT.md](testing/QA_COVERAGE_AUDIT_REPORT.md) | QA coverage audit report |
| [testing/KNOWLEDGE_BOWL_VALIDATION_TESTING.md](testing/KNOWLEDGE_BOWL_VALIDATION_TESTING.md) | Knowledge Bowl validation testing |

---

## Watch App

| Document | Description |
|----------|-------------|
| [watch-testing/WATCH_APP_TESTING.md](watch-testing/WATCH_APP_TESTING.md) | Apple Watch app testing guide (with screenshots) |

---

## Device Setup

| Document | Description |
|----------|-------------|
| [setup/DEVICE_SETUP_GUIDE.md](setup/DEVICE_SETUP_GUIDE.md) | Physical device configuration |

---

## Shared Documentation

Cross-cutting documentation lives in the [main UnaMentis repository](https://github.com/UnaMentis/unamentis).
When working locally with Claude Code, these are accessible at `/Users/ramerman/dev/unamentis/docs/`.

| Document | Location | Description |
|----------|----------|-------------|
| Client Feature Spec | [docs/client-spec/](https://github.com/UnaMentis/unamentis/tree/main/docs/client-spec) | Canonical UI/UX specification for all clients |
| Hands-Free Design | [docs/design/HANDS_FREE_FIRST_DESIGN.md](https://github.com/UnaMentis/unamentis/blob/main/docs/design/HANDS_FREE_FIRST_DESIGN.md) | Voice-first interaction design |
| Audio Orchestrator | [docs/design/AUDIO_PLAYBACK_ORCHESTRATOR.md](https://github.com/UnaMentis/unamentis/blob/main/docs/design/AUDIO_PLAYBACK_ORCHESTRATOR.md) | Cross-platform audio pipeline |
| Module Specs | [docs/modules/](https://github.com/UnaMentis/unamentis/tree/main/docs/modules) | Knowledge Bowl, SAT, specialized modules |
| Testing Philosophy | [docs/testing/TESTING.md](https://github.com/UnaMentis/unamentis/blob/main/docs/testing/TESTING.md) | Real-over-mock testing philosophy |
| Mock Inventory | [docs/testing/MOCK_VIOLATIONS_INVENTORY.md](https://github.com/UnaMentis/unamentis/blob/main/docs/testing/MOCK_VIOLATIONS_INVENTORY.md) | Mock violation patterns and remediation |
| API Specification | [docs/api-spec/](https://github.com/UnaMentis/unamentis/tree/main/docs/api-spec) | Server REST API documentation |
| Architecture | [docs/architecture/](https://github.com/UnaMentis/unamentis/tree/main/docs/architecture) | System architecture and design decisions |
| Project Overview | [docs/architecture/PROJECT_OVERVIEW.md](https://github.com/UnaMentis/unamentis/blob/main/docs/architecture/PROJECT_OVERVIEW.md) | Authoritative project overview |
| AI/ML Docs | [docs/ai-ml/](https://github.com/UnaMentis/unamentis/tree/main/docs/ai-ml) | AI model guides (GLM-ASR, LLM tools, Apple Intelligence) |
| Feature Flags | [docs/FEATURE_FLAGS.md](https://github.com/UnaMentis/unamentis/blob/main/docs/FEATURE_FLAGS.md) | Feature flag definitions |
| Chaos Engineering | [docs/testing/CHAOS_ENGINEERING_RUNBOOK.md](https://github.com/UnaMentis/unamentis/blob/main/docs/testing/CHAOS_ENGINEERING_RUNBOOK.md) | Voice pipeline resilience testing |
