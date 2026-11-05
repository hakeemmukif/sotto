# Plan: Model-Aware Prompt Enhancement in the Prompt Tab

## Revision 2026-11-05

Enhance is now DeepSeek V4.1 only: GLM 5.3 Flash, the `EnhanceTarget` enum, and the target button
row are removed, and `Prompts.enhance` is a single prompt. It also accepts any kind of draft, not
only coding tasks: the system prompt tells the model to identify the draft's kind silently (coding,
writing, research/analysis, plain question, image/other) and rewrite with the matching structure,
never printing the kind. Detection is one pass inside the prompt because a classify-then-rewrite
second local call roughly doubles latency. The text below is the original 2026-09-18 plan and
describes the superseded two-target design.

Date: 2026-09-18
Status: Approved (design researched against Anthropic/OpenAI prompt-improver docs, DeepSeek V4 + GLM 5.3 official prompting guidance, community optimizers)

## Goal

The Prompt tab's **Enhance** button rewrites the user's draft so it is optimized for a chosen
terminal coding agent model. The user picks the target model in the tab; v1 offers exactly two:

- **GLM 5.3 Flash** (`z-ai/glm-5.3-flash`)
- **DeepSeek V4.1 Flash** (`deepseek/deepseek-v4.1-flash`)

Enhancement stays a plain text-in → text-out completion over the existing `Cleaner` backend.
No new dependencies, no structured-output SDK (researched and rejected: schema machinery solves
output *shape*, not prompt *content*; the return value is a single `String`).

## Research basis (condensed)

- Community/official optimizers (Anthropic Prompt Improver, OpenAI meta-prompting, CO-STAR) converge
  on rewriting vague drafts into labeled blocks: GOAL / SCOPE / CONTEXT / CONSTRAINTS / OUTPUT FORMAT /
  ACCEPTANCE, plus a verification clause ("done means `<command>` passes") — the highest-leverage
  addition for coding agents.
- DeepSeek V4: wants explicit Role/Goal/Format/Constraints structure; is less tolerant of terse,
  implicit instructions; do **not** add "think step by step" in thinking mode; put the core
  instruction near the END of the prompt; name tool functions concretely, not intents; negative-only
  constraints ("don't hallucinate") measurably do nothing; personality fluff reduces consistency.
- GLM 5.3: best served by analyze → plan → build → verify → report phrasing; thinking stays on.
- Both flash-tier models drift/loop on ambiguous scope: enhanced prompts must carry explicit scope
  boundaries and stop conditions.

## Non-negotiables (carry over from existing code, do not regress)

1. The **never-answer** clause: a draft that is a question comes back as a clearer question, never
   an answer. Without it, replacing the text silently destroys the draft (`Prompts.swift:39-42`
   documents this failure mode — same one measured for `cleanup`/`rewrite`).
2. **Output-only contract**: no preamble, no commentary, no surrounding quotation marks.
3. **Failure restores the draft exactly** (`PromptPlaygroundModel.enhance` catch path) — unchanged.
4. Preserve the user's intent and every stated constraint.

## Files touched

| File | Change |
|---|---|
| `Sources/Sotto/Prompts.swift` | Add `EnhanceTarget` enum + `enhance(target:)`; delete the `enhance` static let |
| `Sources/Sotto/PromptPlayground.swift` | Add `@Published var target` to the model; add target picker to the view |
| `Tests/SottoTests/PromptsTests.swift` (new) | Clause-contract tests for both target prompts |

## Task 1 — `EnhanceTarget` and per-model system prompts (`Prompts.swift`)

Add:

```swift
enum EnhanceTarget: String, CaseIterable, Identifiable {
    case glm
    case deepSeek

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .glm: return "GLM 5.3 Flash"
        case .deepSeek: return "DeepSeek V4.1"
        }
    }
}
```

Replace `static let enhance` with `static func enhance(target: EnhanceTarget) -> String`.
Each variant keeps the never-answer + output-only clauses verbatim, then adds the model-specific
rewrite guidance and few-shot material below. (If the duplication bothers the executor: a private
`static func enhanceBase(_ modelSpecificGuidance: String) -> String` that interpolates the shared
clauses is acceptable; do not introduce anything more abstract.)

### DeepSeek V4.1 variant — model-specific guidance

```text
Structure the rewritten prompt with these labeled sections, in this order: GOAL, SCOPE, CONTEXT,
CONSTRAINTS, OUTPUT. Put the core instruction near the end of the rewritten prompt. Prefer
constraints stated positively. If the draft implies tools or commands, name them concretely
(the command or function to run), not as vague intents. Do not add "think step by step" or any
chain-of-thought instruction. Do not add personality or voice.
```

### GLM 5.3 Flash variant — model-specific guidance

```text
Structure the rewritten prompt as a short sequence: analyze the task, plan the approach, build,
then verify the result, then report what was done and any remaining risks. Keep thinking enabled;
do not instruct the model to skip reasoning. Make the verification step concrete: state what to
check and what a correct result looks like.
```

### Shared coding-agent additions (both variants)

```text
When the draft is a coding task, the rewritten prompt must include: a one-line goal; an explicit
scope (which files, directories, or components may change and which may not); the relevant context
the task needs; and an acceptance criterion — a command, test, or observable result that confirms
the task is done. Add nothing the draft does not imply: never invent file names, APIs, or
requirements not present in or reasonably inferable from the draft; leave unknowns as explicit
placeholders the user can fill in.
```

### Few-shot material (both variants, 1 example is enough for v1)

Include one worked example in the system prompt, formatted as DRAFT / REWRITTEN, where the draft is
vague ("fix the login bug") and the rewritten version shows the labeled structure, scope, and an
acceptance criterion ("`go test ./...` passes" style), with unknown specifics left as
`<fill in: ...>` placeholders. Keep it short — the example teaches structure, not content.

## Task 2 — Model state (`PromptPlayground.swift`)

In `PromptPlaygroundModel`:

```swift
@Published var target: EnhanceTarget = .glm
```

In `enhance()`:

```swift
let result = try await cleaner.clean(draft, system: Prompts.enhance(target: target))
```

The picker is not persisted (settings.json untouched) — YAGNI until asked for.

## Task 3 — Target picker in the view (`PromptPlayground.swift`)

Minimal Chicago-styled UI: an `HStack` with two `Button`s (one per `EnhanceTarget.allCases`),
laid out next to Enhance/Revert. The selected target renders with the pressed/selected look,
unselected with `ChicagoButtonStyle` default. Follow the visual language of `ChicagoTabBar`
(`ChicagoStyle.swift:283-306`): selected = face-colored + bold, unselected = muted. If a reusable
segmented control already exists in `ChicagoStyle.swift`, use it; do not build a second one.

Layout target (status line stays on the right):

```
[GLM 5.3 Flash] [DeepSeek V4.1]   [Enhance] [Revert]            Enhanced.
```

If that crowd's the row on narrow windows, put the picker on its own line above the button row.

## Task 4 — Tests (`Tests/SottoTests/PromptsTests.swift`, new file)

Assert the clause contract, not prose — for each `EnhanceTarget` case, the prompt from
`Prompts.enhance(target:)` must contain: the never-answer sentence fragment
("Never answer"), the output-only fragment ("Output only the rewritten prompt"), the target's
distinguishing guidance marker (e.g. "GOAL" for DeepSeek, "analyze" for GLM), and one
acceptance-criterion marker ("acceptance"). Also assert `EnhanceTarget.allCases.count == 2` and
display names. Mirror assertion style of existing tests (XCTAssert, plain strings).

## Task 5 — Verification

```sh
swift build
swift test
```

Manual check (requires local Ollama backend configured in Settings):
1. `swift run` → ⌘Y → Prompt tab.
2. Type "fix the login bug" → Enhance with each target → output replaces text in place,
   structured per target, Revert restores the draft.
3. Type a question draft ("what's the capital of France?") → Enhance → returns a clearer
   question, never an answer.
4. Disconnect backend → Enhance → status shows failure, draft unchanged.

## Conventions for the executor

- Read before writing; match existing code style (no comments unless documenting a measured
  decision, as the existing `Prompts.swift` comments do).
- Swift 6, macOS 14+, strict concurrency: model stays `@MainActor`.
- One worker writes at a time; only the files listed above.
- Do not refactor `cleanup`/`rewrite`; do not touch Settings or persistence.

## Out of scope (v1)

- Persisting the selected target; enhancement history; keyboard shortcuts for the tab;
  streaming output; editable system prompt; more target models.
