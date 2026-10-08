# Changelog

All notable changes to this gem are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the gem uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - Unreleased

First version, implementing version 1.1 of the DecisionNode SDK surface: every public call of the API.

### Added

- `DecisionNode` client with `decide`, `decide_many`, `check`, `classify`, `score`, `number`, `gate`, `systemone`, `models`, `upload`, `open_session`, `supervise`, `batches`, `run_batch` and `decide_raw`. `check`, `classify`, `score`, `number` and `gate` take `images:` and `model:` like `decide`.
- `number` questions: the builder `DecisionNode.number(instructions, min:, max:, step:)`, which leaves out a bound not given, the `number` helper, and `NumberAnswer` with `number`, `expected`, `confidence` and `probabilities` keyed by the value as the server wrote it.
- `systemone`: `POST /v1/systemone`, the model always sent, a truth question sent under the type name that path takes. An answer under that name reads as a `TruthAnswer`.
- Images by URL, path, bytes, base64 text, an IO or an upload id. URLs pass through after a local check (`https`, at most 2,048 characters) and are the recommended form. Local images go inline when a request's local images total under `DEFAULT_INLINE_THRESHOLD` (524,288 bytes; the `inline_threshold:` option), otherwise they are uploaded once (one `POST /v1/uploads`, parallel `PUT`s with exactly the returned headers) and sent by upload id. An in-memory cache by SHA-256 reuses an upload whatever the size until 5 minutes before it expires, concurrent calls with the same bytes share one upload, and an upload the API reports stale is uploaded again and the request sent once more. `upload(images)` uploads explicitly.
- Local checks before any request, raising the API's own class with no status and no request id: image format from the magic bytes, 10,485,760 bytes, 40,000,000 pixels read from the JPEG, PNG or WebP header, at most 4 images with unique ids, URL form, choice and score counts, truth and number instructions, and number grids counted in exact decimals.
- Sessions: `open_session`, `Session#connect`, `#send`, `#replies`, `#next_event`, `#end` and `#close`, with `Reply`, `FrameError` and `SessionClosed` values, `seq` counted from 1, pings answered, a silent socket treated as lost, and `supervise`, which reopens or reconnects by close code with a capped backoff. A session limit raises `SessionLimitError`, a `RateLimitError`, and is never retried.
- The Batch API: `batches.create`, `add` (split at 10 MiB), `finalize` (a 409 resolved with `get`), `get`, `list`, `results` and `cancel`, with `Batch`, `BatchPage` and `BatchResult`; create, add and finalize retried only on 429 and 529. `run_batch` runs the whole lifecycle with a poll interval of at least 10 seconds, the server's `Retry-After` when longer, and a timeout.
- `ModelInfo#sessions`, `#batch` and `#limit` for the limits `GET /v1/models` publishes.
- `gate` with fixed question wording, the same in every DecisionNode SDK.
- `decide_many` returns one `DecisionResult` per request, a `Decision` or a `DecisionNodeError` (an unexpected error is wrapped in `DecisionNodeError` with the original as its `cause`). Every request is checked before any is sent: a `concurrency` below 1 or any invalid request raises `ArgumentError` and nothing is sent.
- `check`, `classify` and `score` raise `ServerError`, with `status`, `request_id` and `reason`, when their own answer is missing or malformed; `decide` returns it as `UnknownAnswer`.
- Question builders `DecisionNode.truth`, `DecisionNode.choice` and `DecisionNode.score`, also available through `include DecisionNode::Questions`.
- Typed answers: `TruthAnswer`, `ChoiceAnswer`, `ScoreAnswer`, `NumberAnswer`, and `UnknownAnswer` for answer types this version does not know. `models` returns `ModelInfo` entries. Missing token counts and latency are `nil`.
- `DecisionNode::Image`: the media type is taken from the first bytes (JPEG, PNG or WebP). A file is read when the `Image` is made; an unreadable one raises `ArgumentError` there, and bytes in another format raise `BadRequestError` before any request.
- The safety check result as `decision.safety`.
- Retries with `retry-after-ms`, `Retry-After` in seconds or as an HTTP date (server waits capped at 60 seconds) and exponential backoff.
- A timeout that covers the whole attempt, from sending the request to the last byte of the body, with any transport.
- Argument checks when the client is made: `base_url` must use `https` (`http` only for `localhost`, `127.0.0.1` and `::1`), `timeout` must be above 0 and `max_retries` 0 or more. Bad arguments raise `ArgumentError`, never a DecisionNode class; an empty question map, an unreadable image file and a value that cannot be serialised do too.
- An answer of a known type with a missing or wrongly typed field is returned as `UnknownAnswer` with its raw fields.
- `NetHTTPTransport` keeps connections alive per host (`max_idle:`, `keep_alive_timeout:`) and takes `proxy:` and `net_http:` (Net::HTTP settings such as `ca_file`). Settings that could turn TLS or certificate checks off (`use_ssl`, `verify_mode` other than `VERIFY_PEER`, `verify_hostname: false`, `verify_callback`) are refused, and TLS with peer and hostname checks is set again after the caller's settings for an `https` URL. A transport passed as `http_client:` must answer `false` to `follow_redirects?` or it is refused, and a response from another address than the one requested is an error.
- The README documents the `x-decisionnode-safety-body` request header.
- Errors: one class per documented status, `PermissionDeniedError` for a 403 that is not a refusal, and the base `DecisionNodeError` with its status for any other status. Only 2xx is a success and redirects are never followed. An error's `message` is the server's message, an empty string when it sent none. There is no second name for the base class.
- `DecisionNode::SPEC_VERSION`, the version of the SDK surface this gem implements (`"1.1"`), and `DecisionNode::DEFAULT_INLINE_THRESHOLD`.
- Configuration through `DECISIONNODE_API_KEY`, `DECISIONNODE_BASE_URL` and `DECISIONNODE_MODEL`; an empty argument counts as not given.
- Optional debug logging that never prints state, questions or answers.
- The conformance tests fail, never skip, when `DECISIONNODE_CONFORMANCE_DIR` is not set. CI runs conformance suite 1.4 at a pinned commit, with every action pinned to a commit SHA and `persist-credentials: false` on every checkout.
