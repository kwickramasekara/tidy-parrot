# kstack config
Written by /kstack:setup-kstack. Re-run it to update.

## Tracker
- Kind: github
- Key: #N · kwickramasekara/tidy-parrot
- Read: `gh issue view <N> --comments`. Criteria: the issue's acceptance list, such as "Done when"
- Start: `gh issue edit <N> --add-assignee @me`
- Finish: `gh issue close <N> --comment "<what shipped>"`

## Checks
- `make lint test`
- Also `make integration WAV=clip.wav` when the helper, the protocol or the engine changed (AGENTS.md "Commands")

## Verify
- Skill: none. Fallback: `make run`, then a human dictates into a text field. Agents can't drive the hotkey, mic or paste (AGENTS.md "Gotchas")

## Commit
- Branch: main · Format: sentence-case imperative subject with no prefix, as in the git log (AGENTS.md has no Git section)

## Decisions
- Extra sizes: none
- References: none
- Log: none

## Why sources
- none

## Review
- opencode: `-m openai/gpt-6.1-sol --variant xhigh`
- Extra smells: AGENTS.md "Conventions"
