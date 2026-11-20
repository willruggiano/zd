# Local Markdown tracker

Specs and tickets under `.scratch/` are temporary work files.
Exclude `.scratch/` from version control.

Keep lasting information in code, project documentation or agent skills.
Do not keep it only in ticket history.

## Layout

- Spec: `.scratch/<feature>/spec.md`
- Tickets: `.scratch/<feature>/issues/<NN>-<slug>.md`
- Number tickets from `01`. Put blockers before tickets that depend on them.
- Write one file per ticket.

## Ticket fields

- `Status:` records a [triage label](triage-labels.md).
- `Progress:` records execution: `open`, `in-progress`, or `done`.
  A missing value means `open`.
- `Blocked by:` lists ticket numbers/titles within the feature, or `None`.

Start a ticket only when every blocker has progress `done`.

## Operations

- Publish: create the spec or ticket at its designated path.
- Fetch: read the specified file. Ask for clarification if a ticket number is unclear.
- Claim: set progress to `in-progress`.
- Comment: append under `## Comments`. Keep the discussion while the work is active.
- Complete:
  1. Make sure that the work meets the acceptance criteria.
  2. Record lasting requirements, decisions or lessons in code, project documentation or agent skills.
  3. Record verification evidence.
  4. Set progress to `done`.
- Clean up: first complete the work. Record lasting information outside the scratch directory.
  Then remove the feature's scratch directory.
