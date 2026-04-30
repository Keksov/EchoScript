---
applyTo: "orchestrator/**/*.ts"
description: "TypeScript best practices for the orchestrator, including Bun patterns, strict typing, async streams, and naming conventions."
---

# TypeScript Best Practices (Bun)

## Strict TypeScript

- Enable `strict: true` in tsconfig.json
- Never use `any` — use `unknown` and narrow with type guards
- Prefer `interface` for object shapes, `type` for unions/intersections
- Use `readonly` for data that should not be mutated
- Use `as const` for literal constants

## Types & Inference

- Let TypeScript infer return types for simple functions; annotate explicitly for public API functions
- Use discriminated unions for event types: `{ event: "hr_notification"; hr: number; rr: number[] }`
- Prefer `unknown` over `any` for external data (JSONL parsing, WebSocket messages)
- Validate external input at system boundaries with runtime checks before casting

## Functions & Modules

- Prefer named exports over default exports
- Keep functions small and pure where possible
- Use `const` arrow functions for callbacks; named `function` declarations for top-level
- Avoid classes unless managing stateful resources (e.g., process lifecycle, WebSocket connections)

## Error Handling

- Use try/catch only at boundaries (HTTP handlers, process spawn, WebSocket open)
- Prefer returning `Result`-style objects (`{ ok: true; data } | { ok: false; error }`) for expected failures
- Never swallow errors silently — always log or propagate
- Use `finally` for cleanup (closing streams, killing child processes)

## Bun-Specific

- Use `Bun.serve()` for HTTP + WebSocket server
- Use `Bun.spawn()` for child processes (MindReader.exe)
- Read stdout as `ReadableStream` — avoid buffering entire output
- Use `Bun.file()` for file I/O instead of `fs`
- Prefer Bun's built-in test runner (`bun test`) over external frameworks

## Async Patterns

- Prefer `async/await` over raw Promises
- Use `for await...of` for streaming line-by-line reads from child process stdout
- Never use `new Promise()` when an async API exists
- Handle backpressure when forwarding data to WebSocket clients

## Naming Conventions

- `camelCase` for variables, functions, parameters
- `PascalCase` for types, interfaces, classes
- `UPPER_SNAKE_CASE` for constants
- Prefix interfaces with purpose, not `I`: `HeartRateEvent`, not `IHeartRateEvent`
- File names: `kebab-case.ts`

## Code Style

- No semicolons (Bun/modern TS convention) or consistent semicolons — pick one, stick to it
- Use template literals over string concatenation
- Prefer `===` over `==`
- Destructure objects and arrays at point of use
- Avoid nested ternaries — use early returns or `if/else`
