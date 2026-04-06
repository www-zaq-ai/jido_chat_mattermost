# AGENTS.md — jido_chat_mattermost

Canonical standards for AI agents and human contributors.
This adapter implements [`Jido.Chat.Adapter`](https://github.com/agentjido/jido_chat)
for the Mattermost platform.

---

## Reference docs

| Doc | What's in it |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Module map, ingress/egress data flow, transport swapping, multi-instance setup |
| [`docs/jido_chat_adapter.md`](docs/jido_chat_adapter.md) | Every `Jido.Chat.Adapter` callback: signature, return type, SDK fallback, and normalization rules |

Read both docs before adding or changing adapter behaviour.

---

## Module namespace

- Root: `Jido.Chat.Mattermost`
- All public modules under `Jido.Chat.Mattermost.*`
- Sub-namespaces by layer: `Transport.*`, `WebSocket.*`
- No extra public modules for one-off logic — use private functions

---

## Quality gate

```sh
mix quality   # shorthand: mix q
# format --check-formatted  →  compile --warnings-as-errors  →  credo --strict  →  test
```

Run before every commit.

---

## Testing rules

- `use ExUnit.Case, async: true` for all unit tests
- Inject transport test doubles via opts (`transport: FakeTransport`) — never mock HTTP
- Integration tests: tag `@moduletag :integration`, read creds from env vars
- Every adapter test suite must include:

```elixir
test "capability matrix is coherent" do
  assert :ok = Jido.Chat.Adapter.validate_capabilities(Jido.Chat.Mattermost.Adapter)
end
```

---

## Hard rules

1. **`WebSocket.Client` is a raw dispatcher only** — no payload transformation inside it
2. **Never hardcode credentials** — resolve from opts, then `Application.get_env`
3. **No public modules for single-use logic** — private functions
4. **Never couple to a specific runtime** — accept Oban workers, supervisors, etc. as opaque opts
5. **Every `:native` capability must have an exported callback** — `validate_capabilities/1` enforces this
6. **Never log tokens, passwords, or secret material**
