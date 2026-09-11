# Native protocol fixtures

All fixtures are synthetic values shaped by the zod schemas verified in the
local ZCode desktop bundle on 2026-09-11 (see `docs/PROTOCOL-DELTA-20260911.md`).
They contain no credentials, device names, absolute paths, or real message text.

## verified/

| File | Service / method | Verified shape | Expected parser result |
| --- | --- | --- | --- |
| `subscribe_ack.json` | zcode-agent.subscribeConversationV4 | `{ack:{subscriptionId, mode:'snapshot'\|'resume', logEpoch}}` | subscription becomes `acked` with the given id; `subscribed` must stay false until this arrives |
| `session_snapshot_with_runtime.json` | zcode-session.readSession | `settings.model.{current,available[],lastUsed}`, `settings.thoughtLevel.{enabled,current,defaultLevel,available[]}`, `projection.{contextUsed,contextWindow,status}`, `runtime.contextUsage.{used,size}` | current = fixture-provider/fixture-model-flash; catalog = 2 models (one disabled with reason); thought current `max`, options `high`/`max`; context 39300/200000 |
| `session_snapshot_thought_current_only.json` | zcode-session.readSession | `thoughtLevel.available == []`, `projection.contextWindow == 0` | thought shows read-only `max` and "options not returned"; context shows `1.2k / —` |
| `set_thought_level_result.json` | zcode-session.setThoughtLevel / setModel | `{sessionId, appliedModelRuntimeRevision, changed}` | write accepted; repository re-reads snapshot |
| `create_receipt.json` | sendConversationCommandV4 type=createSession | receipt `status:'accepted'`, `result.type:'createSession'`, `result.sessionId` | draft adopts `sess_fixture_0003` in place |
| `send_receipt.json` | sendConversationCommandV4 type=sendText | receipt `status:'accepted'` | pending user row moves to `pendingReceipt -> streaming` |
| `stop_receipt.json` | sendConversationCommandV4 type=stop | receipt `status:'accepted'` | stopping -> idle on the next status event |
| `stop_receipt_duplicate.json` | sendConversationCommandV4 type=stop | receipt `status:'duplicate'` | treated as idempotent success, no error banner |

## failures/

| File | Injected condition | Expected behaviour |
| --- | --- | --- |
| `config_rejected.json` | receipt `status:'rejected'` with `reasonCode`/`message` | keep old model/thought; show reasonCode text; no optimistic change persists |
| `config_stale.json` | receipt `status:'stale'` (revision mismatch) | keep old values; re-read snapshot; offer retry |
| `method_not_found.json` | error body `message:'fault.method_not_found'` | capability marked unsupported; page shows "本机没有提供此能力", never opens the WebView |

Sanitisation applied: provider/model identifiers replaced with `fixture-*`,
session ids with `sess_fixture_*`, workspace path with `<workspace>`, message
text with `fixture message`, timestamps with round synthetic values.
