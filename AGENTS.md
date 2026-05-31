# AI Development Guidelines for UnaMentis iOS

## CRITICAL: Git Commit Policy

**AI AGENTS MUST NEVER COMMIT OR PUSH TO GIT.** This is the highest priority mandate.

- **ONLY stage changes** using `git add`
- **NEVER run** `git commit`, `git push`, or any command that creates commits
- The human developer will handle all commits to ensure proper contributor attribution

## Development Model

This project is developed with **100% AI assistance**. All code, tests, documentation, and architecture decisions are made collaboratively between human direction and AI implementation.

## MANDATORY: MCP Server Integration

**All AI agents working on this project MUST use the configured MCP servers for first-class Xcode and Simulator integration.**

### Required MCP Servers

| Server | Purpose | Installation |
|--------|---------|--------------|
| **XcodeBuildMCP** | Xcode builds, tests, log capture, app lifecycle | `claude mcp add XcodeBuildMCP -- npx xcodebuildmcp@latest` |
| **ios-simulator** | Simulator control, screenshots, UI automation | `claude mcp add ios-simulator -- npx -y ios-simulator-mcp` |

### When to Use MCP Tools

**Always prefer MCP tools over raw CLI commands:**

| Task | Use This | NOT This |
|------|----------|----------|
| Build iOS app | `mcp__XcodeBuildMCP__build_sim` | `xcodebuild` CLI |
| Capture app logs | `mcp__XcodeBuildMCP__start_sim_log_cap` / `stop_sim_log_cap` | Manual log fetching |
| Install app | `mcp__XcodeBuildMCP__install_app_sim` | `xcrun simctl install` |
| Launch app | `mcp__XcodeBuildMCP__launch_app_sim` | `xcrun simctl launch` |
| Take screenshot | `mcp__ios-simulator__screenshot` | Manual screenshot |
| Tap UI element | `mcp__ios-simulator__ui_tap` | N/A |

### Round-Trip Development Workflow

1. **Build** using XcodeBuildMCP
2. **Install** using XcodeBuildMCP
3. **Launch** using XcodeBuildMCP
4. **Capture logs** using XcodeBuildMCP
5. **Screenshot** using ios-simulator MCP
6. **Interact** using ios-simulator MCP (tap, swipe, type)
7. **Analyze logs** and iterate

## Project Architecture

### Core Patterns
- **Swift 6.0 strict concurrency**: All services are actors
- **Protocol-first design**: Services defined by protocols, swappable implementations
- **TDD methodology**: Tests written before implementation
- **Real implementations in tests**: Only mock truly external dependencies

### Key Directories
```
UnaMentis/
├── Core/           # Core business logic
│   ├── Audio/      # Audio pipeline, VAD integration
│   ├── Curriculum/ # Curriculum management, progress tracking
│   └── Telemetry/  # Metrics, cost tracking, observability
├── Services/       # External service integrations (STT, TTS, LLM)
├── UI/             # SwiftUI views
└── Persistence/    # Core Data stack

UnaMentisTests/
├── Unit/           # Unit tests (run frequently)
├── Integration/    # Integration tests
└── Helpers/        # Test utilities, mock services
```

### Build & Test Commands
```bash
# Build for simulator
xcodebuild -project UnaMentis.xcodeproj -scheme UnaMentis \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Testing
./scripts/test-quick.sh          # Unit tests only (fast)
./scripts/test-all.sh            # All tests + 80% coverage enforcement
./scripts/test-integration.sh    # Integration tests only
./scripts/test-ci.sh             # Direct runner with env var config
```

## Working with This Codebase

### Before Implementation
1. **Read the iOS Style Guide**: `docs/ios/IOS_STYLE_GUIDE.md` (MANDATORY)
2. Read relevant tests first, they document expected behavior
3. Check existing patterns in similar components

### During Implementation
1. Write tests first (TDD)
2. Ensure Swift 6 concurrency compliance (@MainActor, Sendable, actors)
3. Run build frequently to catch issues early
4. **Follow iOS Style Guide requirements for accessibility and i18n**

### CRITICAL: Definition of Done

**YOU MUST RUN TESTS BEFORE DECLARING WORK COMPLETE.**

Work is NOT complete until you have:
1. Run `./scripts/lint.sh` and verified 0 violations
2. Run `./scripts/test-quick.sh` and verified ALL tests pass
3. Actually observed the test output yourself

### Quality Gates
- All tests pass (you must verify by running them)
- Build succeeds for iOS Simulator
- No force unwraps (!)
- Public APIs documented with /// comments
- Code follows existing patterns in the codebase
- **Accessibility labels on all interactive elements**
- **Localizable strings for all user-facing text**
- **iPad adaptive layouts using size class detection**

## MANDATORY: Tool Trust Doctrine

**All findings from established security and quality tools are presumed legitimate until proven otherwise through rigorous analysis.**

| Tool | Domain | Trust Level |
|------|--------|-------------|
| CodeQL | Security vulnerabilities | HIGH |
| SwiftLint | Swift code quality | HIGH |

When a tool flags an issue:
1. Assume it's legitimate (DEFAULT)
2. Deep investigation (not cursory review)
3. Fix the code, or prove false positive with full data flow trace and documentation

## Technical Specifications

### Performance Targets
- E2E turn latency: <500ms (median), <1000ms (P99)
- 90-minute session stability without crashes
- Memory growth: <50MB over 90 minutes

## Writing Style Guidelines

### Punctuation Rules

**Never use em dashes or en dashes as sentence interrupters.**

- Wrong: "The feature — which was added last week — improves performance"
- Correct: "The feature, which was added last week, improves performance"

Use commas for parenthetical phrases. Use periods to break up long sentences.

## Testing Philosophy: Real Over Mock

**Mock testing is unacceptable for most scenarios.** Tests should exercise real code paths to provide genuine confidence in behavior.

### When Mocking is VALID

Mocks are only acceptable for:
1. **Paid third-party APIs** (LLM, Embeddings, TTS, STT), these cost money per request
2. **APIs requiring credentials we don't have**, interim during development
3. **Unreliable external services**, only if local alternatives don't exist

### When Mocking is NOT ACCEPTABLE

Do NOT mock:
1. **Internal services** (TelemetryEngine, PersistenceController, etc.), use real with in-memory stores
2. **File system operations**, use temp directories
3. **Core Data**, use `PersistenceController(inMemory: true)`
4. **Free external APIs**, test against the real thing
5. **Local computations**, cosine similarity, chunking, etc.

### Mock Requirements (When Necessary)

When you must mock, the mock must be **faithful and realistic**:
1. Reproduce real API behavior (exact format, realistic timing)
2. Simulate all error conditions the real API produces
3. Validate inputs like the real API
4. Match realistic performance characteristics

### Current Mock Inventory

**Valid mocks (external paid APIs):**
- `MockLLMService` (in `UnaMentisTests/Helpers/MockServices.swift`)
- `MockEmbeddingService` (in `UnaMentisTests/Helpers/MockServices.swift`)

**Test Spies (for behavior verification):**
- `MockVADService` in `UnaMentisTests/Unit/AudioEngineTests.swift` (controllable VAD results for testing AudioEngine integration)

**Should NOT be mocked:**
- `TelemetryEngine`, `PersistenceController`, file operations, local computations

### Test Data Helpers

`TestDataFactory` (in `UnaMentisTests/Helpers/MockServices.swift`) creates real Core Data entities in an in-memory store:
- `createCurriculum(in:name:topicCount:)`
- `createTopic(in:title:orderIndex:mastery:)`
- `createDocument(in:title:type:content:summary:)`
- `createProgress(in:for:timeSpent:quizScores:)`

## Cross-Repository Access

| Repo | Path | Purpose |
|------|------|---------|
| unamentis | /Users/ramerman/dev/unamentis | Server, docs, curriculum |
| unamentis-android | /Users/ramerman/dev/unamentis-android | Android client |
| unamentis-models | /Users/ramerman/dev/unamentis-models | Shared ML models |

## MANDATORY: Clean Up Test Data

When testing produces persistent artifacts, clean them up before finishing. Prefix test data with `test-` or `claude-test-` for easy identification.
