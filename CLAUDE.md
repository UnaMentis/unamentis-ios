# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## CRITICAL: Git Commit Policy

**Claude may commit ONLY on an explicit, real-time command from the human, and must NEVER push.**

- **Staging** (`git add`) is always allowed.
- **Committing** (`git commit`) is allowed ONLY when the human gives a direct, in-the-moment instruction to commit (for example, "commit this"). There is no standing or blanket permission: each commit needs its own explicit go-ahead, so the human keeps the final call and the commit message is right. Without that explicit command, stage the changes and tell the human they are ready.
- **Pushing** (`git push`, or anything that publishes to a remote) is NEVER done by Claude. The human handles all pushes.

This keeps the human making the final call on what lands and preserves the integrity of the contribution history.

## Project Overview

UnaMentis iOS is the Swift 6.0/SwiftUI client for the UnaMentis voice AI learning platform. It enables 60-90+ minute voice-based learning sessions with sub-500ms latency. The project is developed with 100% AI assistance.

This is a standalone mobile app. It communicates with the UnaMentis server via HTTP REST APIs (port 8766) but has zero source-level dependencies on server code.

## MANDATORY: MCP Server Integration

**You MUST use the configured MCP servers for all Xcode and Simulator operations.**

### Required MCP Servers

Verify servers are connected:
```bash
claude mcp list
# Should show:
# ios-simulator: Connected
# XcodeBuildMCP: Connected
```

### MCP Tools to Use

| Task | MCP Tool |
|------|----------|
| Set session defaults | `mcp__XcodeBuildMCP__session-set-defaults` |
| Build for simulator | `mcp__XcodeBuildMCP__build_sim` |
| Build and run | `mcp__XcodeBuildMCP__build_run_sim` |
| Install app | `mcp__XcodeBuildMCP__install_app_sim` |
| Launch app | `mcp__XcodeBuildMCP__launch_app_sim` |
| Capture logs | `mcp__XcodeBuildMCP__start_sim_log_cap` / `stop_sim_log_cap` |
| Take screenshot | `mcp__XcodeBuildMCP__screenshot` or `mcp__ios-simulator__screenshot` |
| Describe UI | `mcp__XcodeBuildMCP__describe_ui` |
| Tap UI | `mcp__XcodeBuildMCP__tap` or `mcp__ios-simulator__ui_tap` |
| Type text | `mcp__XcodeBuildMCP__type_text` or `mcp__ios-simulator__ui_type` |
| Swipe | `mcp__XcodeBuildMCP__swipe` or `mcp__ios-simulator__ui_swipe` |
| Gestures | `mcp__XcodeBuildMCP__gesture` |

**Important**: Before building, set session defaults:
```
mcp__XcodeBuildMCP__session-set-defaults({
  projectPath: "/Users/ramerman/dev/unamentis-ios/UnaMentis.xcodeproj",
  scheme: "UnaMentis",
  simulatorName: "iPhone 17 Pro"
})
```

### Round-Trip Debugging Workflow

When debugging UI issues:
1. Build with XcodeBuildMCP
2. Install and launch with XcodeBuildMCP
3. Capture logs with XcodeBuildMCP
4. Screenshot with ios-simulator MCP
5. Interact with ios-simulator MCP
6. Analyze and iterate

## Xcode Project Generation

The Xcode project is generated from `project.yml` using XcodeGen. The `project.pbxproj` file is NOT committed to git.

**First-time setup after cloning:**
```bash
./scripts/setup-models.sh    # Create models symlink
xcodegen generate             # Generate Xcode project
```

**After modifying project.yml:**
```bash
xcodegen generate
```

## Models Setup

Models are stored in a shared folder at `/Users/ramerman/dev/unamentis-models/` (or `$UNAMENTIS_MODELS_PATH`). The iOS repo accesses them via a `models` symlink.

```bash
./scripts/setup-models.sh    # Creates models -> /dev/unamentis-models symlink
```

CI creates placeholder model files instead of using real models (see `.github/workflows/ios.yml`).

## Quick Commands

```bash
# iOS build
xcodebuild -project UnaMentis.xcodeproj -scheme UnaMentis \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Testing (use the unified test runner for CI parity)
./scripts/test-quick.sh          # Unit tests only (fast)
./scripts/test-all.sh            # All tests + 80% coverage enforcement
./scripts/test-integration.sh    # Integration tests only
./scripts/test-ci.sh             # Direct runner with env var config

# Lint and format
./scripts/lint.sh
./scripts/format.sh

# Health check (lint + quick tests)
./scripts/health-check.sh

# Hook audit (check for bypasses)
./scripts/hook-audit.sh
```

### Unified Test Runner

The `test-ci.sh` script is the single source of truth for test execution.

```bash
# Environment variables for test-ci.sh:
TEST_TYPE=unit|integration|all  # Default: unit
SIMULATOR="iPhone 17 Pro"       # Default: iPhone 17 Pro (with fallback)
COVERAGE_THRESHOLD=80           # Default: 80%
ENABLE_COVERAGE=true|false      # Default: true
ENFORCE_COVERAGE=true|false     # Default: true in CI, false locally
```

## MANDATORY: Graceful Application Termination

**Always use graceful quit commands to stop applications. Never use kill as a first resort.**

```bash
# CORRECT: Graceful quit via AppleScript
osascript -e 'tell application "AppName" to quit'

# CORRECT: Graceful termination signal
pkill -TERM ProcessName

# LAST RESORT ONLY: Forceful kill
kill -9 PID
```

## MANDATORY: Definition of Done

**NO IMPLEMENTATION IS COMPLETE UNTIL `/validate` PASSES.**

Before marking any work "complete", run:
```
/validate           # Lint + quick tests
/validate --full    # For significant changes
```

**WRONG:** Write code, see it compiles, tell user "implementation is complete"
**RIGHT:** Write code, run `/validate`, verify PASS, THEN tell user "implementation is complete"

## Pre-Commit Hook: Quality Enforcement

The pre-commit hook enforces code quality for Swift:

### Mock Test Detection

| Forbidden Patterns | Allowed Exceptions |
|-------------------|-------------------|
| `class/actor/struct Mock*` outside `MockServices.swift` | `// ALLOWED: <reason>` comment |

**Swift exception:** Mocks for paid external APIs (LLM, STT, TTS, Embeddings) are allowed in `UnaMentisTests/Helpers/MockServices.swift`.

## MANDATORY: Tool Trust Doctrine

**All findings from security and quality tools are presumed legitimate until proven otherwise through rigorous analysis.**

When SwiftLint or any established tool flags an issue:
1. **Assume it's real** (not "might be real", assume it IS real)
2. **Investigate deeply** (full data flow analysis)
3. **Fix the code** (the default outcome)
4. **Adapt patterns** (if tools don't understand our code, our code should change)

## Key Technical Requirements

**Hands-Free First Design:**
- Voice-centric activities must support 100% hands-free operation
- Voice-first is automatic when entering activities
- All voice work must follow accessibility standards (VoiceOver compatible)
- See `HANDS_FREE_FIRST_DESIGN.md` in the main repo (`/Users/ramerman/dev/unamentis/docs/design/`), the canonical cross-platform spec

**Testing Philosophy (Real Over Mock):**
- Only mock paid external APIs (LLM, STT, TTS, Embeddings)
- Use real implementations for all internal services

**Performance Targets:**
- E2E turn latency: <500ms (median), <1000ms (P99)
- Memory growth: <50MB over 90 minutes
- Session stability: 90+ minutes without crashes

## Cross-Repository Access

This project has read access to all UnaMentis ecosystem repositories via global additionalDirectories.

### Available External Repos

| Repo | Path | Purpose |
|------|------|---------|
| unamentis | /Users/ramerman/dev/unamentis | Server infrastructure, documentation, curriculum |
| unamentis-android | /Users/ramerman/dev/unamentis-android | Android client |
| unamentis-models | /Users/ramerman/dev/unamentis-models | Shared ML models |

### How to Use

Access is always active. Use absolute paths with Read, Grep, and Glob:

```bash
# Server docs
Read: /Users/ramerman/dev/unamentis/docs/architecture/PROJECT_OVERVIEW.md

# Android patterns
Glob: /Users/ramerman/dev/unamentis-android/**/*.kt

# Shared models
Read: /Users/ramerman/dev/unamentis-models/CLAUDE.md
```

## Commit Convention

Follow Conventional Commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `perf:`, `ci:`, `chore:`

**BEFORE EVERY COMMIT:** Run `/validate` and ensure it passes.

## Accumulative Commit Message Tracking

Claude automatically tracks work completed, building commit message notes tied to the current uncommitted changes.

### Viewing and Clearing
- Use `/commit-message` to view the accumulated notes formatted for commit
- Use `/commit-message clear` to manually reset if needed
- The draft is **automatically cleared** by the post-commit hook after successful commits

## Key Documentation

**In this repo:**
- `UnaMentis/CLAUDE.md` - iOS app-specific guidance (architecture, style, patterns)
- `docs/ios/IOS_STYLE_GUIDE.md` - Mandatory iOS coding standards
- `docs/APP_STORE_COMPLIANCE.md` - App Store submission requirements

**In the main repo** (accessible via cross-repo access at `/Users/ramerman/dev/unamentis/docs/`):
- `docs/client-spec/` - Canonical client UI/UX specification
- `docs/design/HANDS_FREE_FIRST_DESIGN.md` - Hands-free design specification
- `docs/modules/` - Knowledge Bowl, SAT, and other module specs
- `docs/testing/TESTING.md` - Testing philosophy (Real Over Mock)
- `docs/architecture/PROJECT_OVERVIEW.md` - Authoritative project overview
- `docs/api-spec/` - Server REST API documentation
