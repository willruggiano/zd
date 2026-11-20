# Local Markdown tracker

Specs and tickets under `.scratch/` are ephemeral working material.
Exclude `.scratch/` from version control.

Context that needs to survive belongs in code, project documentation,
or agent skills—not in ticket history.

## Layout

- Spec: `.scratch/<feature>/spec.md`
- Tickets: `.scratch/<feature>/issues/<NN>-<slug>.md`
- Number tickets from `01`, placing blockers before dependent tickets.
- Write one file per ticket.

## Ticket fields

- `Status:` records a [triage label](triage-labels.md).
- `Progress:` records execution: `open`, `in-progress`, or `done`.
  A missing value means `open`.
- `Blocked by:` lists ticket numbers/titles within the feature, or `None`.

A ticket can start when every blocker has progress `done`.

## Operations

- Publish: create the spec or ticket at its designated path.
- Fetch: read the referenced file. Clarify ambiguous ticket numbers.
- Claim: set progress to `in-progress`.
- Comment: append under `## Comments`, preserving discussion while
  the work is active.
- Complete:
  1. Verify acceptance criteria.
  2. Capture any lasting requirements, decisions, or lessons in code,
     project documentation, or agent skills.
  3. Record verification evidence and set progress to `done`.
- Clean up: remove the feature's scratch directory once its work is
  complete and lasting context has been captured elsewhere.
