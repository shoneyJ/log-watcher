# Cron job agent

## Status

Raw intent, moved here from `doc/features.md` (which holds as-built facts
only) on 2026-07-31. Nothing is designed or built; the open questions below
must be settled before this becomes an implementable plan.

## Objective

An agentic tool that answers natural-language questions about the machine's
cron activity, backed by a configurable LLM.

## Original notes (verbatim)

> - an agentic tool that can be configured with LLM models to retrieve cron details.
>
> -- get_running_crons
> 'Which cron jobs are running right now?'
> -- tail_log
> 'Tail the postgress db logs'
> -- test with llama local db model for local development.
> -- llm can be configured.

## Requirements captured

- Two tool calls sketched:
  - `get_running_crons` — answers "Which cron jobs are running right now?"
  - `tail_log` — e.g. "Tail the postgres db logs"
- The LLM is configurable (model/provider not hard-coded).
- Local development runs against a local llama model.

## Open questions

- **Scope**: CLAUDE.md declares the project detection-only with alerting out
  of scope. An interactive agent is new scope — confirm it belongs in this
  binary at all, or is a separate tool beside it.
- **"Running right now"**: the supervisor already knows schedules
  (`nextFire`), active watch windows, and flock lock state — is that the
  answer, or does the tool inspect the live process list?
- **`tail_log` overlap**: `LogTail` already reads tail chunks; does the tool
  reuse it or shell out to `tail`?
- **LLM interface**: which API shape (e.g. OpenAI-compatible endpoint as
  served by llama.cpp/ollama), and where the configuration lives.
- **Typo assumed**: "llama local db model" is read as "local llama model".
