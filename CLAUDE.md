# Keymail: rules for every change

## Bulletproof flows (must never break)
1. Sending and receiving email (Gmail, Outlook, iCloud, Yahoo).
2. Navigating by keyboard or mouse: every keyboard command and every row/menu action works.

These are guarded by `Tests/EmailTests/CoreFlowsTests.swift`.
- Run `./build.sh` (it runs every test first) before saying a change is done, and never push with a failing test.
  The `.githooks/pre-push` hook blocks pushes when tests fail (enable once per clone: `git config core.hooksPath .githooks`).
- Adding a keyboard command, palette command or row action? Add it to CoreFlowsTests in the same change.
- Changing send, sync or parsing code? Add or update a test that shows mail still sends and arrives.
- Never weaken or delete a CoreFlowsTests assertion to make a change pass. Fix the change instead.
- Tests run against an isolated store (`AppFlavor.isTesting`): temp folder, throwaway key, separate Keychain name.
