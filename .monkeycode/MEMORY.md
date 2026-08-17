# User Instruction Memory

This file records user instructions, preferences, and teachings for reference in future interactions.

## Format

### User Instruction Entry
User instruction entries should follow this format:

[User Instruction Summary]
- Date: [YYYY-MM-DD]
- Context: [Mentioned scenario or time]
- Instructions:
  - [Content of user teaching or instruction, described line by line]

### Project Knowledge Entry
Entries discovered by the Agent during task execution should follow this format:

[Project Knowledge Summary]
- Date: [YYYY-MM-DD]
- Context: Discovered by Agent while performing [specific task description]
- Category: [Operations & Deployment|Build Methods|Testing Methods|Troubleshooting & Debugging|Workflow & Collaboration|Environment Configuration]
- Instructions:
  - [Specific knowledge points, described line by line]

## Deduplication Strategy
- Before adding a new entry, check for similar or identical instructions.
- If a duplicate is found, skip the new entry or merge it with the existing one.
- When merging, update the context or date information.
- This helps avoid redundant entries and keeps the memory file tidy.

## Entries

[iOS Build Verification Environment]
- Date: 2026-08-17 (updated)
- Context: Discovered by Agent while optimizing AIReverse parsing code
- Category: Environment Configuration
- Instructions:
  - Current workspace container does not provide `swift` or `xcodebuild` by default; Xcode build verification is unavailable here.
  - Swift typecheck is possible: download Swift 5.10+ Linux toolchain to /opt/swift, provide a stub MachO module (e.g. /tmp/opencode/mock), then run `swiftc -typecheck -I <mock-dir> <file>.swift` to catch type errors.
  - Validate full iOS builds on a Mac/Xcode environment or through the existing GitHub Actions workflow.
  - Xcode 16+ (Swift 6 compiler) rejects passing a capturing closure to a `@convention(c)` function pointer ("a C function pointer cannot be formed from a closure that captures context"), even in Swift 5 mode. Fix: keep callback state in file-level globals and use a non-capturing literal closure. Linux Swift 5.10 does NOT flag this, so it only shows up in CI/real Xcode builds.

[Confirm Before Commit And Packaging]
- Date: 2026-08-14
- Context: User instructed during IPA build workflow collaboration and corrected commit workflow
- Instructions:
  - Before every git commit, ask the user for explicit confirmation.
  - Before pushing changes that trigger IPA packaging or starting a packaging workflow, ask the user to confirm whether any further changes are needed.
