# AGENTS.md

Behavioral guidelines for developing VPSChecker, a small terminal utility for
quickly checking VPS IP addresses.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- Prefer a direct script or a small set of focused modules. Extract an abstraction
  only when it improves readability, enables testing, or has proven reuse.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Preserve Naming, Stack, and CLI Contract

**Respect existing names, technologies, and user-facing behavior unless explicitly approved.**

- Do not rename files, commands, flags, functions, modules, or domain concepts unless the user explicitly asks or there is a justified necessity.
- Keep the existing language, libraries, package manager, and build tools unchanged unless the user requests a change.
- If a technology or approach change becomes genuinely necessary, explain the reason and get human approval before making the change.
- Treat command-line arguments, exit codes, and machine-readable output as public interfaces. Do not change them unintentionally.
- Do not add a dependency when the standard library or an existing dependency solves the task clearly and reliably.

## 5. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Validate IP input" → "Write tests for invalid IPv4/IPv6 input, then make them pass"
- "Fix the check command" → "Write a test that reproduces the failure, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 6. Test Scope

**Run the smallest relevant test scope by default.**

- Run tests for the modules directly affected by the change.
- Do not run the full test suite after every step.
- Run the full test suite only when the change affects broadly shared/core behavior, at an explicit integration milestone, or when the human requests it.
- If broader regression risk remains after targeted tests, explain it instead of silently expanding the test scope.
