# Changelog

All notable changes to this gem are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the gem uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - Unreleased

First version, implementing version 1.0 of the DecisionNode SDK surface.

### Added

- `DecisionNode` client with `decide`, `decide_many`, `check`, `classify`, `score`, `gate`, `models` and `decide_raw`. `check`, `classify`, `score` and `gate` take `images:` and `model:` like `decide`.
- `gate` with fixed question wording, the same in every DecisionNode SDK.
- `decide_many` returns one `DecisionResult` per request, a `Decision` or a `DecisionNodeError` (an unexpected error is wrapped in `DecisionNodeError` with the original as its `cause`). Every request is checked before any is sent: a `concurrency` below 1 or any invalid request raises `ArgumentError` and nothing is sent.
- `check`, `classify` and `score` raise `ServerError`, with `status`, `request_id` and `reason`, when their own answer is missing or malformed; `decide` returns it as `UnknownAnswer`.
- Question builders `DecisionNode.truth`, `DecisionNode.choice` and `DecisionNode.score`, also available through `include DecisionNode::Questions`.
- Typed answers: `TruthAnswer`, `ChoiceAnswer`, `ScoreAnswer`, and `UnknownAnswer` for answer types this version does not know. `models` returns `ModelInfo` entries. Missing token counts and latency are `nil`.
- `DecisionNode::Image` from a file path, raw bytes or an `https` URL. The media type of a file, or of bytes given without `media_type:`, is taken from the first bytes (JPEG, PNG or WebP). A file is read when the `Image` is made.
- The safety check result as `decision.safety`.
- Retries with `retry-after-ms`, `Retry-After` in seconds or as an HTTP date (server waits capped at 60 seconds) and exponential backoff.
- A timeout that covers the whole attempt, from sending the request to the last byte of the body, with any transport.
- Argument checks when the client is made: `base_url` must use `https` (`http` only for `localhost`, `127.0.0.1` and `::1`), `timeout` must be above 0 and `max_retries` 0 or more. Bad arguments raise `ArgumentError`, never a DecisionNode class; an empty question map, an unreadable image file, an image in an unknown format and a value that cannot be serialised do too.
- An answer of a known type with a missing or wrongly typed field is returned as `UnknownAnswer` with its raw fields.
- `NetHTTPTransport` takes `proxy:` and `net_http:` (Net::HTTP settings such as `ca_file`). Settings that could turn TLS or certificate checks off (`use_ssl`, `verify_mode` other than `VERIFY_PEER`, `verify_hostname: false`, `verify_callback`) are refused, and TLS with peer and hostname checks is set again after the caller's settings for an `https` URL. A transport passed as `http_client:` must answer `false` to `follow_redirects?` or it is refused, and a response from another address than the one requested is an error.
- The README documents the `x-decisionnode-safety-body` request header.
- Errors: one class per documented status, `PermissionDeniedError` for a 403 that is not a refusal, and the base `DecisionNodeError` with its status for any other status. Only 2xx is a success and redirects are never followed. An error's `message` is the server's message, an empty string when it sent none. There is no second name for the base class.
- `DecisionNode::SPEC_VERSION`, the version of the SDK surface this gem implements (`"1.0"`).
- Configuration through `DECISIONNODE_API_KEY`, `DECISIONNODE_BASE_URL` and `DECISIONNODE_MODEL`; an empty argument counts as not given.
- Optional debug logging that never prints state, questions or answers.
- The conformance tests fail, never skip, when `DECISIONNODE_CONFORMANCE_DIR` is not set. CI runs conformance suite 1.3 at a pinned commit, with every action pinned to a commit SHA and `persist-credentials: false` on every checkout.
