# Relay and intake

Part of the [configuration reference](../configuration.md).

## Machine-service intake (state/inbox)

A local service submits one JSON object on standard input to `FM_HOME=<home> bin/fm-inbox.sh service`.
This extends the existing inbox rather than creating another spool or operational prompt kind.
The object has these fields:

| Field | Required value |
| --- | --- |
| `kind` | `dispatch`, `notice`, or `blocked`. |
| `source` | Service identifier. |
| `item_id` | Work-item identifier, such as `PC-3385`. |
| `severity` | `info`, `low`, `medium`, `high`, or `critical`. |
| `evidence_path` | Absolute local path of at most 1024 printable ASCII characters, retained without reading the file. |
| `request_id` | Identifier unique across this home's machine-service requests, including different sources and kinds. |
| `key` | Optional problem key for upward relay. |
| `summary` | Optional non-secret description of at most 200 printable characters on one line, such as the finding category, rule ID, and file path, and whether the sender started work. |

Identifiers and keys contain 1-96 characters: an initial ASCII letter or digit, followed by ASCII letters, digits, `.`, `_`, or `-`.
Every value is a string; unknown fields, duplicate fields, invalid values, a summary containing newlines or control characters, and objects longer than 8192 characters are refused before saving.
Never include secret values, credentials, matched secret text, or evidence contents in any field, including the summary, a filename, or an identifier.
The submitting service is responsible for that restriction; field validation does not detect secrets.
This is a local trusted-producer interface, not an authenticated remote API or a grant of dispatch authority.

The command saves a canonical JSON body in the home's existing `state/inbox/<id>.note`, identified by `source=machine-service` and `service_schema=fm-inbox-service.v1` headers.
The existing inbox receipt, reservation, and announcement mechanisms apply; service reservations use the reserved `service:` prefix, which ordinary `note --request-id` submissions refuse.
The first saved request wins: retrying its `request_id` returns the original record without changing its body, creating another note, or repeating an announced wake, including after acknowledgment.
Use a new request ID for a different event.
Pending records remain until firstmate acknowledges them through the existing inbox drain; handled records and request reservations remain available for replay detection without automatic expiration.
The watcher repairs saved but unannounced requests and relays pending service messages before surfacing their queued check wake.
The [machine-service handling procedure](../secondmate-parent-channel.md#machine-service-handling) owns dispatch, relay, and acknowledgment duties; `bin/fm-inbox.sh --help` owns command syntax, receipts, and exit conventions.
