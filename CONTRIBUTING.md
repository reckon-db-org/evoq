# Contributing to evoq

Thanks for your interest. evoq is the CQRS/event-sourcing framework every
event-sourced service we run sits on, so the bar for a change is a regression
test and a clear reason, not volume.

## Reporting a bug

Open an issue on the canonical repository:
<https://github.com/reckon-db-org/evoq/issues>.

Please include:

- the evoq version (`{vsn, ...}` in `src/evoq.app.src`, or the hex version),
- the Erlang/OTP version (`erl -version`),
- a minimal reproduction — an EUnit test that fails is worth more than a
  description of one,
- the stack trace, if it is a crash.

## Proposing a change

For anything non-trivial, open an issue first so the approach can be agreed
before you spend time on it. Small fixes are welcome as a pull request directly.

### What a pull request must carry

- **A test that fails before the fix.** A bug fix comes with a test that is red
  against the unfixed code and green after it; new behaviour comes with a test
  that pins it. Say in the pull request how you measured the red.
- **No new Dialyzer findings.** `bash scripts/check_ratchet.sh` ratchets against
  `.dialyzer_baseline`; pre-existing findings are not yours to fix in an
  unrelated change, and not yours to add.
- **No new ex_doc warnings.** `rebar3 ex_doc` must build. The reference
  warnings already in the tree are pre-existing; do not add one.
- **The full local gate**: `rebar3 compile`, `rebar3 lint`, `rebar3 eunit`,
  `rebar3 ct`, `rebar3 proper`, `rebar3 ex_doc`.

### How the code is shaped

- **Vertical slices, named by intent.** A capability lives in a directory that
  says what it does. No `services/`, `repositories/`, `utils/`, `helpers/`.
- **Events use business verbs.** `user_registered`, never `user_created`; no
  CRUD names anywhere on the wire or in the store.
- **Call Erlang directly.** No Elixir wrappers around an Erlang module; call
  `:module.function/arity`.
- **A comment says why.** A non-obvious decision, a race, a defect that would
  come back — those earn a comment. Restating what the code says does not.
- **No stubs, no "fix later".** If something cannot be implemented, say so in
  the issue rather than leaving a hole in the code.

### Commit messages

A subject line that names the module and the change, then prose explaining why
the change exists and what it replaces. `evoq_command_router: a passivated
aggregate is dispatched again (evoq#57)` is the shape. Reference the issue in
the subject; do not close it from a commit.

## Security

Please do not open a public issue for a vulnerability. Mail the maintainer at
<raf.lefever@erlef.org> and give us a chance to answer before it is public.
