# Cron agent — implementation phases

> **Superseded by `mcp-server.md` (2026-07-31), nothing here was built.**
> The embedded agent loop — the binary calling an LLM itself via curl
> (`Main agent`, `src/Llm.hx`, Phases 2–4) — is replaced by an MCP server
> (`Main mcp`): the binary exposes its tools over authenticated HTTP and
> the LLM lives in an external MCP client. Phase 1's tool layer
> (`src/Pgrep.hx`, `LogTail.lastLines`, get_running_crons, tail_log)
> survives as MCP tools and is specified there, extended with `list_logs`
> and `search_log`.

One-shot LLM agent in the same binary: `Main agent <cron.d-dir> <config.json>
"<question>"` — parses the cron.d dir, lets an OpenAI-compatible LLM answer a
natural-language question about cron activity via two tools, prints the
answer, exits. Read-only with respect to the system: it parses cron.d,
probes locks (`flock -n`), probes processes (`pgrep -f`), and reads log
tails — it never executes or writes anything a cron entry owns.

## Status

- [ ] Phase 1 — Tool layer (no LLM)
- [ ] Phase 2 — LLM protocol module
- [ ] Phase 3 — Agent loop & CLI
- [ ] Phase 4 — curl transport, live ollama verification, docs

## Original notes (verbatim)

> - an agentic tool that can be configured with LLM models to retrieve cron details.
>
> -- get_running_crons
> 'Which cron jobs are running right now?'
> -- tail_log
> 'Tail the postgress db logs'
> -- test with llama local db model for local development.
> -- llm can be configured.

## Resolved questions

The open questions from the raw-intent version of this doc, settled
2026-07-31:

- **Scope**: the agent lives in this binary as a new subcommand. The
  watcher's detection-only rule is about *alerting*; the agent is a
  read-only Q&A tool and changes nothing about detection.
- **"Running right now"**: not the supervisor's watch state — the agent is
  a separate one-shot process. It parses cron.d itself (`Cron.parseDir`)
  and probes: flocked entry → `Flock.held(lockPath)`; un-flocked →
  `pgrep -f` on the command's script path. Schedules give `nextFire` for
  context.
- **`tail_log` overlap**: reuses `LogTail`'s 64 KiB tail-chunk discipline
  via a new `LogTail.lastLines(path, n)` — `poll` returns counts, not line
  content, and stays untouched.
- **LLM interface**: OpenAI-compatible chat completions with tool calling
  (served by ollama/llama.cpp locally and remote providers alike),
  transported by shelling out to curl — hxcpp has no TLS, and `Flock.hx`
  set the shell-out precedent. Config lives under an `llm` key in the same
  config.json the supervisor uses.
- **Typo confirmed**: "llama local db model" = local llama model
  (ollama/llama.cpp) for development.

## Ground rules (in addition to plan/04's — zero deps, two-target verification, docs move with code)

- **No live LLM in the test suite.** The agent loop takes an injected
  transport (`typedef Transport = String -> String`: request body JSON in,
  response body JSON out, throws on failure) — the same seam pattern as
  injected `now`. Tests feed canned OpenAI-style bodies through scripted
  transports; the real curl transport is exercised only in Phase 4's manual
  verification. The only network-ish test allowed is a loopback
  connection-refused probe (deterministic, offline).
- **JSON assertions parse back, never string-compare** — `haxe.Json` field
  order for anonymous objects is not guaranteed identical between the
  interpreter and hxcpp.
- **Canned LLM responses are built with `haxe.Json.stringify` in the
  test**, not hand-written string literals — sidesteps string-escaping
  pain and exercises the "arguments is a JSON-encoded string inside JSON"
  quirk from the producing side too.

## Decisions locked

- **CLI**: `Main agent <cron.d-dir> <config.json> "<question>"` — config
  required (no defaultable model name; keeps arg positions unambiguous).
- **Config**: same config.json file as `run`, new `llm` key:
  `{"llm": {"baseUrl": "http://localhost:11434/v1", "model": "llama3.1",
  "apiKey": "..."}}` — `baseUrl` + `model` required, `apiKey` optional
  (omitted for local ollama). Endpoint = `baseUrl + "/chat/completions"`.
  Nothing else is configurable: the tool-call budget and curl timeout are
  compile-time constants (KISS; nobody asked for knobs).
- **New files**: `src/Agent.hx` (tools + loop), `src/Llm.hx` (protocol +
  transport), `src/Pgrep.hx` (process probe, mirroring `src/Flock.hx`).
- **"Running right now"** per entry: flocked entry → `Flock.held(lockPath)`;
  un-flocked → `Pgrep.alive(needle)` where the needle is the command's
  first token starting with `/` (the script path — distinctive, no
  shell-quoting or regex-escaping games; falls back to the first token).
  Ambiguous probe outcomes report *not running*, the same safe-direction
  degrade as `Flock.held`.
- **`tail_log` is restricted to log paths from the current `parseDir`
  result** — the intended flow is "pick a log from the get_running_crons
  listing", and this doubles as a guardrail against shipping arbitrary
  local files to a remote LLM. Unknown path → recoverable error string the
  model can react to.
- **Failure taxonomy**: unknown tool name and malformed tool arguments are
  *recoverable* (error strings fed back to the model); curl failure,
  malformed/choices-less response body, and the `MAX_STEPS = 8` budget are
  *fatal* (message + exit 1).
- **Model quality is out of scope**: the loop requires a tools-capable
  model (e.g. llama3.1, qwen2.5, mistral-nemo); flaky tool use from a weak
  local model is not a code defect — the protocol layer is what the suite
  tests.

## Phase 1 — Tool layer (no LLM)

Both tools work as plain functions against fixture dirs, LLM nowhere in
sight.

**Files**: `src/Pgrep.hx`, `src/LogTail.hx` (add `lastLines`),
`src/Agent.hx` (tool functions only), `test/TestMain.hx`

**Deliverable**:

- `Pgrep.alive(needle:String):Bool` — `pgrep -f -- <needle>`, exit 0 =
  running, 1 = not, anything else (127 no pgrep, …) = unknown → false.
  Mirrors `Flock.hx` in size and spirit.
- `LogTail.lastLines(path:String, n:Int):Null<Array<String>>` — stat, read
  at most CHUNK bytes back from EOF, split at newlines, drop a torn final
  line, return the last ≤ n complete lines (a torn *first* line is
  acceptable, same as first-sight `poll`). Null when the file is missing.
  `poll` is untouched.
- `Agent.getRunningCrons(dir:String, now:Date):String` — for each
  `Cron.parseDir` entry emits `{schedule, command, logPath, nextFire,
  running}` (nextFire as string or null), JSON-stringified.
- `Agent.tailLog(dir:String, path:String, n:Int):String` — n defaulted to
  20 and capped at 200; path must match an entry's logPath, else an error
  string (never a throw).

**Done when**:

- `Pgrep.alive` is deterministically tested with the holder pattern from
  the flock tests (a `bash -c "echo ready; cat # <marker>"` process:
  `readLine` brackets the start, closing stdin ends it — no sleeps):
  true while alive, false after. **And**: `Pgrep.alive` on a nonsense
  needle returns false — this check specifically guards the footgun where
  the probe's own wrapping shell's command line contains the needle and
  matches itself; if it fails, switch the probe from `Sys.command` to
  `sys.io.Process` (argv exec, no shell).
- `lastLines` tests: last-n selection, torn final line excluded, missing
  file, and ≤ CHUNK bytes touched on the sparse ~2 GB fixture.
- `getRunningCrons` against a `test/tmp` cron dir (the supervisor-test
  pattern): fields and injected-now `nextFire` correct; a flocked entry
  flips running true/false around a real flock holder; an un-flocked entry
  flips around a marker process whose cmdline contains the entry's script
  path.
- `tailLog` rejects a path not in the listing; returns real lines for one
  that is. Interp and native suites green.

## Phase 2 — LLM protocol module

Everything about the wire format, nothing about looping or curl.

**Files**: `src/Llm.hx`, `test/TestMain.hx`

**Deliverable**:

- `typedef LlmConfig = {baseUrl:String, model:String, ?apiKey:String}` and
  `Llm.loadConfig(path)` reading the `llm` key (missing key or fields →
  clear failure, not a crash).
- `typedef Transport = String -> String`.
- `Llm.buildRequest(model, messages:Array<Dynamic>, tools):String` —
  compact `haxe.Json.stringify`, `tool_choice` left to the provider
  default. The two tool schemas live here as constants
  (`get_running_crons`: empty-object parameters — some servers reject a
  missing `parameters`; `tail_log`: `{path: string, lines?: integer}`).
- `Llm.parseResponse(body:String)` → `{message:Dynamic,
  content:Null<String>, toolCalls:Array<{id:String, name:String,
  args:Dynamic}>}`. Navigates `choices[0].message`;
  `tool_calls[].function.arguments` is a **JSON-encoded string inside
  JSON** — decoded with a second `Json.parse`, per-call, where a bad
  arguments string yields a per-call error (recoverable) rather than a
  parse failure. Missing `choices` / unparseable body / `{"error": …}`
  body → failure carrying a ~200-char body snippet for diagnosis. The raw
  parsed `message` is returned so the loop can echo it back verbatim into
  the next request's messages (the OpenAI protocol requires replaying the
  assistant tool_calls message).

**Done when**: parse-back tests on `buildRequest` (model, message count,
both tool names present); `parseResponse` tests on canned bodies built
with `stringify`: plain final answer; one tool call; **parallel tool
calls** (the spec allows several per message); nested-string arguments
decoded; malformed body, choices-less body, and error-shaped body all
produce the failure path with a snippet. Config tests: full key, missing
key, apiKey optional. Interp and native green.

## Phase 3 — Agent loop & CLI

The conversation loop over an injected transport, wired into `Main`.

**Files**: `src/Agent.hx`, `src/Main.hx`, `test/TestMain.hx`

**Deliverable**:

- `Agent.ask(cronDir:String, question:String, model:String,
  transport:Transport, now:Date):String` — messages start with a short
  fixed system prompt ("you answer questions about this machine's cron
  jobs; use the tools") plus the user question. Loop, at most
  `MAX_STEPS = 8` LLM round-trips: build request → transport → parse →
  if tool calls, execute each (unknown tool name and malformed arguments
  become error-string tool results fed back — the model can recover) and
  append the echoed assistant message plus one `{role:"tool",
  tool_call_id, content}` per call; if final content, return it. Budget
  exhausted or transport/parse failure → throw; `Main` prints the reason
  and exits 1.
- `Main` gains the subcommand and usage line:
  `Main agent <cron.d-dir> <config.json> "<question>"   one-shot LLM Q&A
  about cron activity`. Prints the answer via `Util.say`, exits 0.

**Done when** (all via scripted transports asserting on each request they
receive):

- Happy path: response 1 requests `get_running_crons`; the transport's
  second invocation asserts the body contains the echoed assistant
  message and a `tool` message with the matching `tool_call_id` whose
  content lists the tmp fixture's entry; response 2 is a final answer,
  returned verbatim.
- `tail_log` path: arguments decoded, `lines` defaulting applied, tool
  result contains the actual tmp log lines.
- Unknown tool → error content fed back → scripted recovery to a final
  answer.
- Runaway: a transport that always returns tool calls stops after exactly
  `MAX_STEPS` invocations and fails cleanly.
- Malformed transport body → clean failure, non-zero exit path.
- `./bin/Main` with no/bad args shows the new usage line and exits 1.
  Interp and native green.

## Phase 4 — curl transport, live ollama verification, docs

The only phase that touches a real LLM — manually.

**Files**: `src/Llm.hx` (curlTransport), `test/agent-config.json`,
`README.md`, `CLAUDE.md`, `doc/features.md`, `doc/file-tree.md`,
`doc/diagrams.md`, this file (tick the Status boxes, record the manual
runs)

**Deliverable**: `Llm.curlTransport(cfg:LlmConfig):Transport` — spawns
`sys.io.Process("curl", ["-sS", "--max-time", "300", url, "-H",
"Content-Type: application/json", (plus "-H", "Authorization: Bearer
<key>" when apiKey is set), "--data-binary", "@-"])`, writes the body to
curl's stdin, closes it, reads stdout, waits on exitCode. argv exec means
no shell and no quoting; stdin streaming means no temp file (and `-d
@file` would strip newlines anyway). Non-zero curl exit → transport
failure including exit code and a stderr snippet; HTTP-level error bodies
pass through and surface via Phase 2's parse failure with body snippet.
Committed `test/agent-config.json` pointing at local ollama
(`http://localhost:11434/v1`, a tools-capable model such as `llama3.1`).

**Done when**:

- Automated: `curlTransport` aimed at a loopback port nobody listens on
  fails fast with the curl exit code in the message (connection refused —
  deterministic, offline, no hang thanks to `--max-time`).
- Manual, against real ollama serving a tools-capable model
  (`ollama pull llama3.1`), recorded in this doc:
  - `./bin/Main agent test/fixtures/cron.d test/agent-config.json "Which
    cron jobs are running right now?"` answers from the
    `get_running_crons` result; with the fixture installed live
    (`sudo cp` per its header) and asked during a minute window while
    `produce-log.sh` runs (~22 s of every minute), the healthy entry
    reports running.
  - `"Tail the failing log"` returns real lines from
    `test/live/failing.log` via `tail_log`.
- Docs updated in the same change: `doc/features.md` gains the agent
  section (tools, probes, transport, failure modes), `doc/file-tree.md`
  the three new files, README quickstart the command, CLAUDE.md the run
  command; the Status checkboxes above ticked; native suite green.
