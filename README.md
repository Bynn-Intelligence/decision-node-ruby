# DecisionNode Ruby SDK

Ruby client for the [DecisionNode](https://decisionnode.com) API: ask yes-or-no, choice, score and number questions about any state and get calibrated answers back, one request at a time, over a live session, or as a batch.

Ruby 3.2 or later. One runtime dependency, `websocket-driver`, used by sessions only and loaded on the first one.

## Install

```sh
bundle add bynn-decisionnode
```

or

```sh
gem install bynn-decisionnode
```

## Set your key

```sh
export DECISIONNODE_API_KEY="dn_..."
```

## Quickstart

```ruby
require "decisionnode"

dn = DecisionNode.new # reads DECISIONNODE_API_KEY

d = dn.decide(
  state: { ticket: "I was charged twice and nobody has replied for 3 days." },
  questions: {
    route: DecisionNode.choice("Where should this go?", { billing: "money", bug: "broken", account: "login" }),
    urgency: DecisionNode.score("How urgent is this?", %w[routine today urgent critical]),
    escalate: DecisionNode.truth("Escalate to a human now?")
  }
)

d["route"].choice          # => "billing"
d["route"].probabilities   # => {"billing" => 0.87, "bug" => 0.08, "account" => 0.05}
d["urgency"].score         # => 2.31
d["escalate"].truth        # => 0.94
```

The values you read are the values the API sent: nothing is rounded, renormalised or thresholded. What 0.94 means for your application is your code's decision.

## Questions

Four builders return a question's wire form as a plain Hash:

| Builder | Asks for |
|---|---|
| `DecisionNode.truth(instructions, if_true: nil, if_false: nil)` | The probability that something is true. `if_true` and `if_false` describe each side and are optional. |
| `DecisionNode.choice(instructions, options)` | One option of a set. `options` is a Hash of name to description, or an Array of names. |
| `DecisionNode.score(instructions, levels)` | A place on an ordered scale. `levels` is an Array, listed from low to high. |
| `DecisionNode.number(instructions, min: nil, max: nil, step: nil)` | A value on a grid from `min` to `max` in steps of `step`. A bound left out is left out of the request, so the server's defaults apply: 0, 255 and 1. |

`include DecisionNode::Questions` makes them available as `truth(...)`, `choice(...)`, `score(...)` and `number(...)`.

`state`, instructions, descriptions and levels take a String or any JSON value. A question Hash copied from the API documentation works wherever a builder does:

```ruby
dn.decide(
  state: "Customer: refund me.",
  questions: { "refund" => { "type" => "truth", "instructions" => "Is this a refund request?" } }
)
```

```ruby
d = dn.decide(
  state: "Drone frame over row B4 of the north car park.",
  images: [DecisionNode::Image.new("frame", url: "https://files.example.com/frames/b4.jpg")],
  questions: { cars: DecisionNode.number("How many cars are visible in the image?", min: 0, max: 50) }
)
d["cars"].number          # => 7
d["cars"].expected        # => 7.02
d["cars"].probabilities   # => {"6" => 0.105, "7" => 0.783, "8" => 0.098}
```

## The client

```ruby
dn = DecisionNode.new(
  api_key: "dn_...",                         # else DECISIONNODE_API_KEY
  base_url: "https://api.decisionnode.com",  # else DECISIONNODE_BASE_URL
  model: "decisionnode-latest",              # else DECISIONNODE_MODEL
  timeout: 10,                               # seconds for a whole attempt
  max_retries: 2,
  headers: { "x-team" => "support-tools" },  # sent with every API request
  inline_threshold: 524_288,                 # bytes; see "Images"
  logger: nil                                # a Logger for debug lines
)
```

Every argument is optional. An explicit argument wins over the environment, which wins over the default. An empty string for `api_key`, `base_url` or `model` counts as not given, here and for `model:` on a call. A client is safe to share between threads and keeps its connections alive, so repeated calls skip the TCP and TLS handshakes.

The client checks its arguments when it is made and raises `ArgumentError` for a bad one:

- `base_url` (from the argument or `DECISIONNODE_BASE_URL`) must use `https`. Plain `http` is accepted only for `localhost`, `127.0.0.1` and `::1`, so an API key never travels unencrypted.
- `timeout` must be above 0 seconds.
- `max_retries` must be a whole number, 0 or more.
- `inline_threshold` must be a whole number of bytes, 0 or more.

| Method | Returns |
|---|---|
| `decide(state:, questions:, images: nil, model: nil)` | A `DecisionNode::Decision` |
| `decide_many(requests, concurrency: 8)` | One `DecisionNode::DecisionResult` per request, in input order: a `Decision`, or the `DecisionNodeError` that request ended with |
| `check(state:, instructions:, if_true: nil, if_false: nil, images: nil, model: nil)` | A `TruthAnswer` |
| `classify(state:, instructions:, options:, images: nil, model: nil)` | A `ChoiceAnswer` |
| `score(state:, instructions:, levels:, images: nil, model: nil)` | A `ScoreAnswer` |
| `number(state:, instructions:, min: nil, max: nil, step: nil, images: nil, model: nil)` | A `NumberAnswer` |
| `gate(action:, context: nil, images: nil, model: nil)` | A `Decision` with the answers `risk` (score), `touches_production` (truth) and `verdict` (choice of `allow`, `confirm`, `block`) |
| `systemone(state:, questions:, images: nil, model: nil)` | A `Decision` from `POST /v1/systemone`, the strict path: `truth`, `choice` and `score` questions, the model always sent |
| `models` | An Array of `DecisionNode::ModelInfo` |
| `upload(images)` | One upload id per image (see "Images") |
| `open_session(questions:, state: nil, instructions: nil, model: nil, window: nil, ttl_seconds: nil)` | A `DecisionNode::Session` (see "Sessions") |
| `supervise(body, feed, on_reply)` | The last `SessionClosed`, or nil (see "Sessions") |
| `batches` | The Batch API (see "Batches") |
| `run_batch(requests, poll_interval: 60, timeout: 93_600)` | `[batch, results]` (see "Batches") |
| `decide_raw(body)` | The response body as a Hash. Sends `body` exactly as given, for API fields this version does not know yet. |

`check`, `classify`, `score` and `number` promise a typed answer, so when their answer is missing or malformed they raise `ServerError` (with the response's `status`, `request_id`, and `reason` from `x-decisionnode-error`). `decide` returns such an answer as an `UnknownAnswer` instead.

`gate` sends the state `{"action" => action, "context" => context}` and three questions with fixed wording:

| Id | Type | Instructions | Options or levels |
|---|---|---|---|
| `risk` | score | How much harm could this action cause if it is wrong? | `none`, `low`, `moderate`, `high`, `severe` |
| `touches_production` | truth | Does this action change a production system, production data or anything customers use? | |
| `verdict` | choice | Should this action run as it is, wait for a person to confirm it, or be blocked? | `allow` "safe to run without asking", `confirm` "a person should confirm it first", `block` "should not run" |

```ruby
dn.check(state: "Customer: refund me.", instructions: "Is this a refund request?").truth
# => 0.97

dn.classify(state: ticket, instructions: "Which team?", options: %w[billing bug account]).choice
# => "billing"

results = dn.decide_many(tickets.map { |t| { state: t, questions: { route: route_question } } }, concurrency: 4)
results.each do |r|
  r.is_a?(DecisionNode::Decision) ? puts(r["route"].choice) : warn(r.message)
end
```

`decide_many` checks every request before it sends any: a `concurrency` below 1 or a request `decide` would refuse as an argument raises `ArgumentError`, and a request the API would refuse raises its `BadRequestError` or `ValidationError` (see "Checked before sending"). Either way nothing is sent.

## Answers

| Class | Fields |
|---|---|
| `Decision` | `answers` (by question id, also `decision["id"]`), `model` (the resolved version), `usage.input_tokens`, `usage.output_tokens`, `request_id`, `latency_ms`, `safety`, `raw` |
| `TruthAnswer` | `truth` |
| `ChoiceAnswer` | `choice`, `confidence`, `probabilities` (by option name, exactly as sent) |
| `ScoreAnswer` | `score`, `confidence`, `probabilities` (by level index, an Integer), `legend` (level index to the level as sent) |
| `NumberAnswer` | `number` (the most probable value of the grid), `expected` (the probability-weighted mean), `confidence` (the probability of `number`), `probabilities` (by the value exactly as the server wrote it, `"7"`, `"3.5"`) |
| `ModelInfo` | `name`, `description`, `release_date`, `limits` (every other field of the entry), and `sessions` and `batch`, the session and Batch API limits; `limit("sessions", "max_per_key")` reads one |

Answers are read by question id. An answer of a type this version does not know is returned as a `DecisionNode::UnknownAnswer` with its `type` and `raw` fields, so the rest of the decision still parses. So is an answer of a known type with a field missing or of the wrong type (a `truth` answer without a number in `truth`, for example): the decision does not fail. All answer classes derive from `DecisionNode::Answer`.

A token count or `latency_ms` the server did not send is `nil`, never 0.

## Images

Send an image by URL when you can. It is the fastest form: nothing is uploaded, the request stays small, and the API fetches the image while it reads the request.

```ruby
dn.decide(
  state: { claim: { total: "740.00" } },
  images: [
    DecisionNode::Image.new("scan", url: "https://files.example.com/claims/4411/scan.webp"), # recommended
    DecisionNode::Image.new("receipt", path: "receipt.png"),
    DecisionNode::Image.new("photo", data: jpeg_bytes),                # a String of bytes, base64 text or an IO
    DecisionNode::Image.new("again", upload_id: "upl_...")              # an earlier upload, for an hour
  ],
  questions: { matches: DecisionNode.truth("Does the receipt total equal the claim?") }
)
```

| Input | What the SDK sends |
|---|---|
| `url:` | The URL as given, after a local check: `https`, at most 2,048 characters. The SDK never fetches it. |
| `path:`, `data:`, `base64:` | The bytes, read when the `Image` is made and checked locally, then inline as base64 when all the local images of the request total under `inline_threshold` (`DecisionNode::DEFAULT_INLINE_THRESHOLD`, 524,288 bytes), otherwise uploaded once and sent by upload id. |
| Bytes uploaded before | The cached upload id, whatever their size, until 5 minutes before the upload expires. |
| `upload_id:` | The upload id as given. |

An upload is one `POST /v1/uploads` for the request's images, then one `PUT` per image, in parallel, straight to storage with exactly the headers the API returned: never your API key, never your custom headers, and no redirect followed. Concurrent calls with the same bytes (`decide_many` over one document, for example) share one upload. The cache lives in the client's memory (at most 256 entries, keyed by the SHA-256 of the bytes and the media type) and is never written to disk. If the API answers that an upload the SDK placed has expired or been used up, the SDK uploads it again and sends the request once more. `upload(images)` uploads whatever the size and returns the upload ids, for use in later requests.

Every local image is checked before any request: its format from the first bytes (JPEG, PNG or WebP; a `media_type:` you give must match them), at most 10,485,760 bytes, and at most 40,000,000 pixels, read from the image header without decoding it. A request takes at most 4 images, with unique ids. No image is ever resized or re-encoded. A file that cannot be read raises `ArgumentError` where the `Image` is made.

## Checked before sending

The SDK checks the API's fixed rules before any network call, so a request the API would refuse costs no round trip. A fault raises the class the API would answer with, with no `status` and no `request_id`:

| Fault | Error |
|---|---|
| An image that breaks a rule of "Images", more than 4 images, repeated image ids, a URL that is not `https` or is longer than 2,048 characters | `BadRequestError` (`error_type` `api_usage_error`) |
| A choice with no options or more than 255, a score with more than 10 levels, a truth question with neither instructions nor criteria, a number question without instructions | `BadRequestError` |
| A score with no levels; a number grid with `step` not above 0, `min` above `max`, a bound that is not a number, or more than 4,096 values (counted in exact decimals) | `ValidationError` |

Limits counted in tokens are the server's to judge, because they differ by model and are published by `models`. `decide_raw` sends its body unchecked.

A bad argument raises Ruby's own `ArgumentError`, never a DecisionNode class: a `base_url`, `timeout`, `max_retries` or `inline_threshold` the client refuses, a `concurrency` below 1, an empty question map, a question that is not a Hash, an image file that cannot be read, and a value that cannot be serialised as JSON. A missing API key raises `AuthenticationError`, also without a request.

## Sessions

A session holds one state and a fixed set of questions, and answers them again for every frame you send on its socket: telemetry, a camera feed, a conversation. Frames are answered as they arrive and the newest wins: a frame sent while another waits replaces it, and the reply says which frames it replaced in `dropped`.

```ruby
s = dn.open_session(
  state: { mission: "Survey the north field" },
  questions: {
    mode: DecisionNode.choice("Which flight mode now?", %w[continue hold return land]),
    abort: DecisionNode.truth("Should the mission be aborted now?")
  }
)
s.connect
s.send(frame: { battery: 0.31, wind_mps: 11.4 })               # => 1, the frame's seq
s.send(frame: "approaching the tree line", image: DecisionNode::Image.new("frame", data: jpeg))

s.replies.each do |event|
  case event
  when DecisionNode::Reply then puts event["mode"].choice
  when DecisionNode::FrameError then warn "#{event.seq}: #{event.error_type} #{event.message}"
  when DecisionNode::SessionClosed then warn "closed #{event.code}"
  end
end
s.end
```

| Method | Does |
|---|---|
| `Session#connect` | Opens the socket, with the API key in the `Authorization` header (never in the URL) and the client's custom headers on the handshake |
| `Session#send(frame:, image:, questions:, reset:, seq:)` | Sends one frame and returns its `seq`, counted from 1 unless given; never waits for a reply. A frame's image follows the threshold of "Images"; a URL image is refused, since frames take bytes or an upload |
| `Session#replies` | Each event in turn: `Reply` and `FrameError` values (a frame error is a value, never raised), then the `SessionClosed` that ends the stream. `next_event(timeout:)` reads one |
| `Session#end` | Ends the session; a session already gone counts as ended |
| `Session#close` | Closes the socket |

`Reply` has `seq`, `answers` (typed as in a `Decision`), `dropped`, `usage`, `latency_ms` and `safety`. `FrameError` has `seq`, `error_type`, `message`, `category`, `retry_after_ms`, `usage` and `safety`. `SessionClosed` has `code`, `reason` and `reopen`: true for the codes after which a new session with the same body is the remedy (1001, 1006, 1011, 4404, 4408, 4409, 4410), false otherwise. Pings are answered at once, and a socket that hears nothing for 65 seconds is closed as 1006.

`supervise` runs one long-lived feed through sessions and reopens them as the close codes say:

```ruby
readings = Enumerator.new { |y| loop { y << { frame: telemetry.read } } }
closed = dn.supervise({ state: { mission: "Survey" }, questions: questions }, readings) do |event|
  handle(event) # every Reply and FrameError
end
```

It reopens with the same body after 1001, 1006, 1011, 4404, 4409 (after a capped backoff with jitter, 1 to 30 seconds), and after 4408 and 4410 (without a wait), connects again to the same session after 1013, and stops on any other code. When the feed ends it waits for the outstanding replies, ends the session and returns the last `SessionClosed` (nil when none was seen); when it stops on a code it returns that `SessionClosed`.

Opening a session when the key already holds its most open sessions raises `DecisionNode::SessionLimitError`, a `RateLimitError`, and is never retried.

## Batches

The Batch API answers requests within 24 hours at half the price. A request is a Hash of `decide`'s arguments plus a `custom_id`.

```ruby
requests = tickets.map.with_index do |t, i|
  { custom_id: "ticket-#{i}", state: t, questions: { route: route_question } }
end

batch, results = dn.run_batch(requests, poll_interval: 60)
results.each do |r|
  if r.decision then puts "#{r.custom_id}: #{r.decision['route'].choice}"
  else warn "#{r.custom_id}: #{r.status} #{r.error&.message}"
  end
end
```

`run_batch` creates an empty draft, adds the requests (in calls of at most 10 MiB), finalizes it, reads the batch every `poll_interval` seconds (at least 10; the server's `Retry-After` when it is longer) until it ends, and returns the ended `Batch` and its results. If adding fails, the draft is cancelled and the error raised. Past `timeout` seconds (26 hours by default) it raises `TimeoutError` and the batch keeps running.

The calls one by one, on `dn.batches`:

| Method | Sends | Returns |
|---|---|---|
| `create(requests = [])` | `POST /v1/batches`, JSON Lines; with no requests an empty draft | `Batch` |
| `add(batch_id, requests)` | `POST /v1/batches/{id}/requests`, split into calls of at most 10 MiB, in order | `Batch` |
| `finalize(batch_id)` | `POST /v1/batches/{id}/finalize` | `Batch` |
| `get(batch_id)` | `GET /v1/batches/{id}` | `Batch` |
| `list(offset: nil, limit: nil)` | `GET /v1/batches` | `BatchPage` (`batches`, `offset`, `limit`, `total`, `next_offset`) |
| `results(batch_id)` | `GET /v1/batches/{id}/results` | One `BatchResult` per request, in upload order |
| `cancel(batch_id)` | `POST /v1/batches/{id}/cancel` | `Batch` |

A `Batch` has every field of the batch object by name (`id`, `state`, `counters`, `created_at`, `finalized_at`, `expires_at`, `ended_at`, `results_url`, `results_expire_at`, `price_factor`, `usage`, `error`) and `ended?`. A `BatchResult` has `custom_id`, `status` (an Integer, or `"expired"` or `"cancelled"`), `headers`, `decision` (a `Decision` for a 200 line) and `error` (for an error line, the error `decide` would have raised, as a value).

Every line carries `custom_id`, `model` (the request's, else the client's) and `state` (`""` when absent), and is checked before anything is sent. Its images follow the threshold of "Images", per line. `get`, `list`, `results` and `cancel` are retried like every call. `create`, `add` and `finalize` are retried only on 429 and 529, never after a timeout, a lost answer or a 5xx, since a repeat could make a second draft. A `finalize` answered with a 409 is resolved by reading the batch: if it is no longer a draft, the earlier finalize went through and the batch is returned.

## Safety

Every decision from the hosted API carries the result of its safety check, parsed into `decision.safety`:

```ruby
s = d.safety
s.checked?   # => true
s.harm       # => 0.031
s.self_harm  # => 0.004
s.flagged    # => [] (the categories above your key's thresholds)
s.reason     # why the check did not run, when checked? is false
```

`safety` is nil when the server sends no safety result, as a self-hosted server does. A request that is refused raises `DecisionNode::RefusalError` and is never retried.

### The safety result in the response body

The safety result always arrives in the `x-decisionnode-safety` response header. To receive it in the response body as well, send the request header `x-decisionnode-safety-body` with the value `true` (`1` and `yes` also work). Pass it through `headers:`, which a client sends with every request:

```ruby
dn = DecisionNode.new(headers: { "x-decisionnode-safety-body" => "true" })

d = dn.decide(state: text, questions: questions)
d.raw["safety"]
# => {"checked" => true, "harm" => 0.0312, "self_harm" => 0.0041, "flagged" => []}
```

The body then carries one more top-level field, `safety`, read from `decision.raw`; it is `{"checked" => false, "reason" => "<code>"}` when the check did not run. Without the header the body has no `safety` field. `decision.safety`, parsed from the response header, is the same with or without it.

## Errors

Every error derives from `DecisionNode::DecisionNodeError`, which has `status`, `error_type`, `message`, `request_id` and `reason`. The error's `message` is the server's message, or the SDK's description when no response arrived; it is an empty string when the server sent none. `reason` is the server's explanation in words from the `x-decisionnode-error` header, for example `question 'q': a score takes up to 10 levels, got 11`. The report Ruby prints for an uncaught error adds the class, status and reason.

| Status | Error | Extra fields |
|---|---|---|
| 400 | `BadRequestError`; `ContextLimitError` when `error_type` is `max_tokens_exceeded` | |
| 401 | `AuthenticationError` | |
| 402 | `InsufficientCreditError` | |
| 403 | `RefusalError` when the request was refused, else `PermissionDeniedError` | `category` (`harm` or `self_harm`), `safety` |
| 404 | `NotFoundError` | |
| 422 | `ValidationError` | `entries` |
| 429 | `RateLimitError`; `SessionLimitError` when `error_type` is `session_limit_exceeded` | `retry_after` (seconds) |
| 529 | `OverloadedError` | `retry_after` (seconds) |
| other 5xx, a 2xx whose body is not JSON, or a helper's missing or malformed answer | `ServerError` | |
| any other status (a 3xx, 405, 409, 410, 408 once its retries are spent) | `DecisionNodeError` itself, with `status` | |
| no response | `ConnectionError`, `TimeoutError` | |

An image upload that storage refuses raises `DecisionNodeError` itself with the storage's `status`, `error_type` `upload_failed`, and the storage's error code in `reason`.

```ruby
begin
  dn.decide(state: text, questions: questions)
rescue DecisionNode::ValidationError => e
  warn e.entries.inspect
rescue DecisionNode::RateLimitError => e
  sleep(e.retry_after || 1)
  retry
rescue DecisionNode::DecisionNodeError => e
  warn "#{e.class} #{e.status}: #{e.message} (request #{e.request_id})"
end
```

## Retries and timeouts

- The timeout is 10 seconds per attempt, and it covers the whole attempt: from sending the request to the last byte of the body, not each network step. A server that sends its answer slowly, a few bytes at a time, still ends the attempt at the deadline with a `TimeoutError`.
- Only a 2xx status is a success. Redirects are never followed, so the API key is never sent to another URL or over plain HTTP; a 3xx raises `DecisionNodeError` with its status.
- A request is retried twice after the first attempt on 408, 429, any 5xx, timeouts and connection errors. The wait is the server's `retry-after-ms`, else `Retry-After` in seconds or as an HTTP date, capped at 60 seconds; without either, an exponential backoff from 0.5 seconds with jitter, capped at 8 seconds. A decision changes nothing on the server, so a retry is always safe.
- 400, 401, 402, 403, 404 and 422 are never retried, and neither is a session limit. Batch create, add and finalize follow their own rule (see "Batches"). An image `PUT` to storage is retried on 5xx and connection errors in the same way.

## Configuration

| Setting | Argument | Environment variable | Default |
|---|---|---|---|
| API key | `api_key:` | `DECISIONNODE_API_KEY` | none |
| Base URL | `base_url:` | `DECISIONNODE_BASE_URL` | `https://api.decisionnode.com` |
| Model | `model:` | `DECISIONNODE_MODEL` | `decisionnode-latest` |
| Inline threshold | `inline_threshold:` | | `524288` bytes |

Model ids: `decisionnode-latest`, `decisionnode-flash-latest`, and the pinned versions `decisionnode-1.0` and `decisionnode-1.0-flash`.

The SDK sends no telemetry. The only header it adds is `User-Agent: decisionnode-ruby/<version>`. To receive the safety result in the response body as well, send the request header `x-decisionnode-safety-body: true` through `headers:` (see "The safety result in the response body").

With a `logger:`, each attempt is logged at debug level with its method, path, status, request id and timing. State, questions, answers and image bytes are never logged.

To set a proxy or TLS options, pass the default transport built with them:

```ruby
transport = DecisionNode::NetHTTPTransport.new(
  proxy: "http://proxy.example.com:3128",
  net_http: { ca_file: "/etc/ssl/certs/company-ca.pem" } # Net::HTTP settings, by name
)
dn = DecisionNode.new(http_client: transport)
```

`net_http:` may add trust (`ca_file`, `ca_path`, `cert_store`) or a client certificate (`cert`, `key`), but it can never turn TLS or its checks off. `use_ssl`, a `verify_mode` other than `OpenSSL::SSL::VERIFY_PEER`, `verify_hostname: false` and `verify_callback` raise `ArgumentError` when the transport is made, and for an `https` URL the transport sets TLS with peer and hostname checks again after applying your settings. `max_idle:` (16) sets how many idle connections are kept per host and `keep_alive_timeout:` (15 seconds) how long an idle one is reused.

To use another HTTP stack, pass `http_client:`, an object with `call(method, url, headers, body, timeout)` that returns a `DecisionNode::HTTPResponse` and raises `DecisionNode::TimeoutError` or `DecisionNode::ConnectionError` when no response arrives. It is called with `GET`, `POST`, `DELETE`, and `PUT` for image uploads to storage, which must carry exactly the headers given. The client holds every transport to the same rules as its own:

- The timeout covers the whole call: the client ends an attempt at its deadline, whatever the transport is doing.
- Redirects are never followed, so the API key is never sent to another URL. A transport must return a 3xx as it is and say so by answering `false` to `follow_redirects?`; any other transport is refused with `ArgumentError` when the client is made. A transport may also set `url` on the `HTTPResponse` to the address the response came from; a response from any other address than the one requested raises `DecisionNodeError`.

```ruby
class MyTransport
  def follow_redirects? = false

  def call(method, url, headers, body, timeout)
    # send the request without following redirects
    DecisionNode::HTTPResponse.new(status, lower_case_headers, body_text)
  end
end
```

Sessions use their own socket, opened with the standard library's TCP and TLS sockets and the `websocket-driver` gem, with certificate and hostname checks always on.

## Development

```sh
bundle install
bundle exec rake test
DECISIONNODE_CONFORMANCE_DIR=/path/to/decision-node-conformance bundle exec rake conformance
```

The conformance tests run the language-neutral DecisionNode conformance suite (version 1.4) against its mock server. They need `DECISIONNODE_CONFORMANCE_DIR`: without it, they fail rather than skip.

This gem implements version 1.1 of the DecisionNode SDK surface (`DecisionNode::SPEC_VERSION`).

## License

MIT. See [LICENSE](LICENSE).
