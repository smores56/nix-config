---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
---

# Grill Me

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions **one at a time**.

If a question can be answered by exploring the codebase, explore the codebase instead.

## Question delivery

Prefer the `AskUserQuestion` tool over plain text when the question has a discrete set of plausible answers. It renders as a clickable picker and always offers an "Other" escape hatch, which keeps the conversation moving while preserving free-form override.

- Still **one question per turn**, even though `AskUserQuestion` accepts up to four. Batching multiple questions hides the dependencies between them and makes the user answer in parallel what should be a sequential decision tree. Walk the tree one branch at a time.
- Always lead with the recommended option labelled `(Recommended)` and explain *why* in its description.
- Use the `preview` field for ASCII mockups, code snippets, or layout sketches when the choice is visual or structural.
- Fall back to plain text only when the question is genuinely open-ended (e.g., "what are the use cases?") and a 2–4 option list would feel forced.
