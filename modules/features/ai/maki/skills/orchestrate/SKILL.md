---
name: orchestrate
description: "Automatic task decomposition and subagent orchestration. Use for every complex task — decompose into parallel subtasks, delegate to subagents with appropriate model tiers, collect and synthesize results."
---

# Orchestrate

You are an orchestrator. For every task with more than one distinct concern or file, decompose it into subtasks and delegate them to subagents by default. Your default workflow is orchestration, not direct execution.

## When to Use

- Any task touching 2+ files or 2+ concerns
- Research or exploration before implementation
- Refactors, migrations, feature work
- Parallelizable work (separate files, independent logic)
- Tasks where different steps need different model tiers

**Do NOT use for:** Single-file edits, trivial lookups, simple questions answered in one turn.

## Core Workflow

### 1. Analyze — is this a multi-step task?

Before acting, check: does this task have multiple distinct steps, files, or concerns? If yes → decompose.

### 2. Decompose — break it into isolated subtasks

Each subtask should be:
- **Minimal** — one file, one concern, one output
- **Independent** — no shared mutable state with other subtasks
- **Verifiable** — clear done criteria

### 3. Dispatch — use `batch` + `task` for parallel work

```lua
-- pattern: parallel research + parallel implementation
local research_results = await batch({
  task("research", "Explore auth patterns in src/auth/"),
  task("research", "Explore middleware in src/middleware/"),
})

-- then dispatch implementation based on findings
local impl_results = await batch({
  task("general", "Implement auth middleware based on research"),
  task("general", "Update routes in src/routes/"),
})
```

### 4. Synthesize — collect and combine results

After all subagents complete, read their outputs and produce the final integrated result. Synthesize yourself — don't delegate the synthesis.

## Model Tier Selection

| Tier | When to use | Examples |
|------|-------------|---------|
| `weak` | Cheap work: search, summarize, grep, name things, simple edits, boilerplate | `grep` for patterns, read a file, write a test stub |
| `medium` | Standard work: refactors, features, multi-file changes, most subagents | Most implementation tasks, moderate refactors |
| `strong` | Deep reasoning: complex architecture, subtle bugs, critical sections | Architecture decisions, security-critical code, complex bug diagnosis |

**Default to `weak` or `medium` for subagents.** Reserve `strong` for the orchestrator's own reasoning and for critical subtasks.

## Subagent Types

| Type | Tools | When to use |
|------|-------|-------------|
| `research` (default) | Read-only | Codebase exploration, grep, reading files, understanding code before changes |
| `general` | Full access | Implementation, edits, running builds/tests |

**Always research before implementing.** Launch research subagents first, then use their findings to inform implementation.

## Parallel Patterns

### Parallel research (most common)
```
batch of task(research) → synthesize findings → batch of task(general) → final synthesis
```

### Parallel implementation (independent modules)
```
plan → batch of task(general, one per module) → integrate → verify
```

### Sequential with handoff (dependent steps)
```
task(research, phase 1) → task(general, phase 2 using phase 1 output) → task(research, verify)
```

When steps have true dependencies, run them sequentially. Only parallelize truly independent work.

## Common Anti-Patterns

| Anti-pattern | Why it's wrong | What to do instead |
|--------------|----------------|--------------------|
| Doing everything yourself | Context bloat, slower, can't parallelize | Decompose and delegate via `task` |
| Using `strong` for all subagents | 5x cost of `medium` with no benefit for simple tasks | Use `weak`/`medium` for most subagents, `strong` only for critical reasoning |
| Research + implement in one subagent | Subagent context gets polluted with both concerns | Separate research (read-only) from implementation (full tools) |
| Sequential when parallel is safe | Slower, wastes tokens on waiting | Use `batch` for independent work |
| Delegating without `batch` | Sequential subagents waste time | Always use `batch` for parallel dispatch |
| Over-decomposing (1-line changes) | Overhead of spawning subagents exceeds any benefit | Only decompose when task has 2+ distinct concerns or files |
