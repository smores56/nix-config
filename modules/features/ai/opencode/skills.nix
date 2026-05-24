{ ... }:
{
  xdg.configFile = {
    "opencode/skills/grill-me/SKILL.md".text = ''
      ---
      name: grill-me
      description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
      ---

      Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

      Ask the questions one at a time.

      If a question can be answered by exploring the codebase, explore the codebase instead.
    '';

    "opencode/skills/grill-with-docs/SKILL.md".text = ''
      ---
      name: grill-with-docs
      description: Grilling session that challenges your plan against existing OpenSpec specs, sharpens terminology, and updates OpenSpec artifacts (proposal, specs, design) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's documented behavior and architecture.
      ---

      <what-to-do>

      Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

      Ask the questions one at a time, waiting for feedback on each question before continuing.

      If a question can be answered by exploring the codebase, explore the codebase instead.

      </what-to-do>

      <supporting-info>

      ## OpenSpec awareness

      During codebase exploration, also look for existing OpenSpec documentation:

      ### File structure

      ```
      openspec/
      ├── specs/                          # Source of truth — current system behavior
      │   ├── auth/spec.md
      │   ├── payments/spec.md
      │   └── ui/spec.md
      └── changes/                        # Proposed modifications
          ├── add-dark-mode/
          │   ├── proposal.md             # Why + scope + high-level approach
          │   ├── design.md               # How — technical approach, architecture decisions
          │   ├── tasks.md                # Implementation checklist
          │   └── specs/                  # Delta specs (ADDED/MODIFIED/REMOVED requirements)
          │       └── ui/spec.md
          └── archive/                    # Completed changes
              └── 2025-01-24-add-2fa/
      ```

      If no `openspec/` directory exists, create it lazily when the first artifact is needed.

      ## During the session

      ### Challenge against existing specs

      When the user describes behavior that conflicts with existing specs in `openspec/specs/`, call it out immediately. "Your spec says cancellation SHALL refund within 24h, but you're describing instant refunds — which is it?"

      ### Sharpen fuzzy language

      When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things." Use RFC 2119 keywords (SHALL/MUST/SHOULD/MAY) to pin down intent.

      ### Discuss concrete scenarios

      When domain relationships are being discussed, stress-test them with Given/When/Then scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

      ### Cross-reference with code

      When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

      ### Update OpenSpec artifacts inline

      As decisions crystallise, update the relevant OpenSpec artifacts immediately — don't batch them up:

      - **proposal.md** — When the scope or motivation of the change becomes clear, write or update the proposal. Include what's in scope, what's out of scope, and the high-level approach.

      - **specs/ (delta specs)** — When a requirement is resolved, write it as a delta spec under `openspec/changes/<change-name>/specs/`. Use `## ADDED Requirements`, `## MODIFIED Requirements`, or `## REMOVED Requirements`. Each requirement uses RFC 2119 keywords and includes `#### Scenario:` blocks in Given/When/Then format. Specs describe behavior, not implementation.

      - **design.md** — When an architecture decision is resolved, add it to the `## Architecture Decisions` section of design.md. Include the decision, rationale, and any rejected alternatives worth remembering.

      Create files lazily — only when you have something to write. If no change folder exists yet, create `openspec/changes/<change-name>/` when the first artifact is needed.

      ### Offer architecture decisions sparingly

      Only record an architecture decision in design.md when all three are true:

      1. **Hard to reverse** — the cost of changing your mind later is meaningful
      2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
      3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

      If any of the three is missing, skip it. Not every decision needs recording — only the ones where the "why" would otherwise be lost.

      </supporting-info>
    '';
  };
}
