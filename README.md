# shario.nvim

A Neovim client for [`shario`](https://github.com/Muna-Louis-Nwugo/shario) — implements the IDE side of the
protocol described in `shario`'s own
[`info/PLUGIN_SPECIFICATIONS.md`](https://github.com/Muna-Louis-Nwugo/shario/info/PLUGIN_SPECIFICATIONS.md).
`shario-vscode/extension.js` is the reference implementation this was
ported from; when the two disagree, that's the one to trust.

## Why this needs a Node.js helper

Neovim/Lua has no Socket.IO client, and Socket.IO isn't a bare WebSocket —
it has its own handshake and packet framing on top, which there's no
pure-Lua implementation of either. Rather than hand-roll that protocol
from scratch with no reference Lua implementation to check correctness
against, this plugin spawns a tiny Node.js helper (`bridge/socket-bridge.js`)
that uses the real `socket.io-client` package (the same one
`shario`'s own `bench/trace-runner.js` already relies on) and relays
messages to and from it over stdin/stdout as newline-delimited JSON. All
the actual CRDT/docState logic still lives in Lua — the helper is a dumb
relay, nothing more.

**This means Node.js needs to be installed** to use this plugin. If that
ever becomes a real problem, the alternatives considered (and why they
weren't picked, for now) are in the design discussion this came out of:
hand-rolling WebSocket+Engine.IO+Socket.IO in pure Lua (real protocol
correctness risk, no reference to check against), or Engine.IO's HTTP
long-polling transport (less protocol surface than full WebSocket, but
still real protocol work, and higher per-message latency).

## Setup

```sh
cd shario-nvim/bridge && npm install
```

Then add `shario-nvim` to your `runtimepath` however your plugin manager
expects (it's not published anywhere yet — this is still assumed to live
as a sibling directory to `shario` and `shario-vscode`, same dev layout
both of those already use).

## Commands

- `:ShareCreate [name]` — starts a new session. Prompts for a name if
  none given (blank accepted — generates a random one so the name is
  always known up front, same reasoning as the VS Code extension).
- `:ShareParticipate [name]` — joins an existing session by name. Prompts
  if not given.
- `:ShareConnect` — attaches to a `shario` server already running on this
  machine, without launching anything.

All three track every buffer under the current working directory whose
path falls under the joined directory, forwarding edits as `ide-add`/
`remove` and mirroring confirmed/remote identities the same way the VS
Code extension does.

## Known limitations (being upfront about these, not discovered later)

- **Launches `shario` via `cargo run --`, assuming a sibling source
  checkout** (`process.lua`'s `shar_dir()`) — same as `shario-vscode`
  today. Once `shario` ships as a prebuilt binary (see its own
  `info/TODO.md`), this should launch that instead.
- **Multi-byte/Unicode column handling is simplified.** Positions
  throughout are character indices via `vim.fn.split(line, '\\zs')`
  (Unicode-codepoint-aware), which is correct for the common case, but
  hasn't been stress-tested against combining characters, emoji with
  variation selectors, or similarly exotic grapheme-cluster edge cases.
- **The buffer-diffing layer (`diff.lua`) is new code, not a direct port.**
  Neovim's `on_lines` only reports which *lines* changed, not what changed
  within them (unlike VS Code's precise `{range, text}` events), so the
  actual character-level edit is recovered by a common-prefix/common-suffix
  diff between the old and new text — verified against real Neovim buffer
  operations (character insert, character delete, splitting a line with
  Enter, merging a line back with Backspace) during development, but this
  is the one piece without a direct JS equivalent to have faithfully copied,
  so it's the most likely spot for an edge case to still be hiding.
- **No `network-add`/`network-remove` handling**, matching
  `shario-vscode`'s current scope exactly — peer-to-peer sync already
  exists server-side, but neither IDE client reacts to a remote edit yet.
