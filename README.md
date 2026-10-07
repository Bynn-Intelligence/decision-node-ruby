# DecisionNode Ruby SDK

Ruby client for the [DecisionNode](https://decisionnode.com) API: ask yes-or-no, choice and score questions about any state and get calibrated answers back.

Ruby 3.2 or later. No runtime dependencies.

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

Three builders return a question's wire form as a plain Hash:

| Builder | Asks for |
|---|---|
| `DecisionNode.truth(instructions, if_true: nil, if_false: nil)` | The probability that something is true. `if_true` and `if_false` describe each side and are optional. |
| `DecisionNode.choice(instructions, options)` | One option of a set. `options` is a Hash of name to description, or an Array of names. |
| `DecisionNode.score(instructions, levels)` | A place on an ordered scale. `levels` is an Array, listed from low to high. |

`include DecisionNode::Questions` makes them available as `truth(...)`, `choice(...)` and `score(...)`.

`state`, instructions, descriptions and levels take a String or any JSON value. A question Hash copied from the API documentation works wherever a builder does:

```ruby
dn.decide(
  state: "Customer: refund me.",
  questions: { "refund" => { "type" => "truth", "instructions" => "Is this a refund request?" } }
)
```

## The client

```ruby
dn = DecisionNode.new(
  api_key: "dn_...",                         # else DECISIONNODE_API_KEY
  base_url: "https://api.decisionnode.com",  # else DECISIONNODE_BASE_URL
  model: "decisionnode-latest",              # else DECISIONNODE_MODEL
  timeout: 10,                               # seconds for a whole attempt
  max_retries: 2,
  headers: { "x-team" => "support-tools" },  # sent with every request
  logger: nil                                # a Logger for debug lines
)
```

Every argument is optional. An explicit argument wins over the environment, which wins over the default. An empty string for `api_key`, `base_url` or `model` counts as not given, here and for `model:` on a call. A client is safe to share between threads and keeps its connections alive.

The client checks its arguments when it is made and raises `ArgumentError` for a bad one:

- `base_url` (from the argument or `DECISIONNODE_BASE_URL`) must use `https`. Plain `http` is accepted only for `localhost`, `127.0.0.1` and `::1`, so an API key never travels unencrypted.
- `timeout` must be above 0 seconds.
- `max_retries` must be a whole number, 0 or more.

| Method | Returns |
|---|---|
| `decide(state:, questions:, images: nil, model: nil)` | A `DecisionNode::Decision` |
| `decide_many(requests, concurrency: 8)` | One `DecisionNode::DecisionResult` per request, in input order: a `Decision`, or the `DecisionNodeError` that request ended with. Every request is checked before any is sent: a `concurrency` below 1, or any request `decide` would refuse (an empty question map, an unknown argument, a bad image, a value that cannot be serialised), raises `ArgumentError` and nothing is sent. |
| `check(state:, instructions:, if_true: nil, if_false: nil, images: nil, model: nil)` | A `TruthAnswer` |
| `classify(state:, instructions:, options:, images: nil, model: nil)` | A `ChoiceAnswer` |
| `score(state:, instructions:, levels:, images: nil, model: nil)` | A `ScoreAnswer` |

`check`, `classify` and `score` promise a typed answer, so when their answer is missing or malformed they raise `ServerError` (with the response's `status`, `request_id`, and `reason` from `x-decisionnode-error`). `decide` returns such an answer as an `UnknownAnswer` instead.
| `gate(action:, context: nil, images: nil, model: nil)` | A `Decision` with the answers `risk` (score), `touches_production` (truth) and `verdict` (choice of `allow`, `confirm`, `block`) |
| `models` | An Array of `DecisionNode::ModelInfo` with `name`, `description`, `release_date` and `limits` |
| `decide_raw(body)` | The response body as a Hash. Sends `body` exactly as given, for API fields this version does not know yet. |

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

## Answers

| Class | Fields |
|---|---|
| `Decision` | `answers` (by question id, also `decision["id"]`), `model` (the resolved version), `usage.input_tokens`, `usage.output_tokens`, `request_id`, `latency_ms`, `safety`, `raw` |
| `TruthAnswer` | `truth` |
| `ChoiceAnswer` | `choice`, `confidence`, `probabilities` (by option name, exactly as sent) |
| `ScoreAnswer` | `score`, `confidence`, `probabilities` (by level index, an Integer), `legend` (level index to the level as sent) |

Answers are read by question id. An answer of a type this version does not know is returned as a `DecisionNode::UnknownAnswer` with its `type` and `raw` fields, so the rest of the decision still parses. So is an answer of a known type with a field missing or of the wrong type (a `truth` answer without a number in `truth`, for example): the decision does not fail. All answer classes derive from `DecisionNode::Answer`.

A token count or `latency_ms` the server did not send is `nil`, never 0.

## Images

```ruby
dn.decide(
  state: { claim: { total: "740.00" } },
  images: [
    DecisionNode::Image.new("receipt", path: "receipt.png"),
    DecisionNode::Image.new("photo", data: jpeg_bytes, media_type: "image/jpeg"),
    DecisionNode::Image.new("scan", url: "https://example.com/scan.webp")
  ],
  questions: { matches: DecisionNode.truth("Does the receipt total equal the claim?") }
)
```

A file is read and base64-encoded by the SDK when the `Image` is made, and its media type is taken from its first bytes (JPEG, PNG or WebP). Bytes given without `media_type:` are recognised the same way. A file that cannot be read, or bytes in another format without a `media_type:`, raise `ArgumentError` where the `Image` is made. The API accepts up to 4 images a request, 10 MB each, and `https` URLs only.

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
| 429 | `RateLimitError` | `retry_after` (seconds) |
| 529 | `OverloadedError` | `retry_after` (seconds) |
| other 5xx, a 2xx whose body is not JSON, or a helper's missing or malformed answer | `ServerError` | |
| any other status (a 3xx, 405, 409, 408 once its retries are spent) | `DecisionNodeError` itself, with `status` | |
| no response | `ConnectionError`, `TimeoutError` | |

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

The SDK checks very little before sending, and nothing it checks is sent. A bad argument raises Ruby's own `ArgumentError`, never a DecisionNode class: a `base_url`, `timeout` or `max_retries` the client refuses (see "The client"), a `concurrency` below 1, an image file that cannot be read or bytes in an unknown format, and a value that cannot be serialised as JSON. An empty question map is an `ArgumentError` too, and so is any invalid request given to `decide_many`, which then sends none of them. A missing API key raises `AuthenticationError`, also without a request. Everything else is judged by the server, because limits differ by model and are published by `models`.

## Retries and timeouts

- The timeout is 10 seconds per attempt, and it covers the whole attempt: from sending the request to the last byte of the body, not each network step. A server that sends its answer slowly, a few bytes at a time, still ends the attempt at the deadline with a `TimeoutError`.
- Only a 2xx status is a success. Redirects are never followed, so the API key is never sent to another URL or over plain HTTP; a 3xx raises `DecisionNodeError` with its status.
- A request is retried twice after the first attempt on 408, 429, any 5xx, timeouts and connection errors. The wait is the server's `retry-after-ms`, else `Retry-After` in seconds or as an HTTP date, capped at 60 seconds; without either, an exponential backoff from 0.5 seconds with jitter, capped at 8 seconds. A decision changes nothing on the server, so a retry is always safe.
- 400, 401, 402, 403, 404 and 422 are never retried.

## Configuration

| Setting | Argument | Environment variable | Default |
|---|---|---|---|
| API key | `api_key:` | `DECISIONNODE_API_KEY` | none |
| Base URL | `base_url:` | `DECISIONNODE_BASE_URL` | `https://api.decisionnode.com` |
| Model | `model:` | `DECISIONNODE_MODEL` | `decisionnode-latest` |

Model ids: `decisionnode-latest`, `decisionnode-flash-latest`, and the pinned versions `decisionnode-1.0` and `decisionnode-1.0-flash`.

The SDK sends no telemetry. The only header it adds is `User-Agent: decisionnode-ruby/<version>`. To receive the safety result in the response body as well, send the request header `x-decisionnode-safety-body: true` through `headers:` (see "The safety result in the response body").

With a `logger:`, each attempt is logged at debug level with its method, path, status, request id and timing. State, questions and answers are never logged.

To set a proxy or TLS options, pass the default transport built with them:

```ruby
transport = DecisionNode::NetHTTPTransport.new(
  proxy: "http://proxy.example.com:3128",
  net_http: { ca_file: "/etc/ssl/certs/company-ca.pem" } # Net::HTTP settings, by name
)
dn = DecisionNode.new(http_client: transport)
```

`net_http:` may add trust (`ca_file`, `ca_path`, `cert_store`) or a client certificate (`cert`, `key`), but it can never turn TLS or its checks off. `use_ssl`, a `verify_mode` other than `OpenSSL::SSL::VERIFY_PEER`, `verify_hostname: false` and `verify_callback` raise `ArgumentError` when the transport is made, and for an `https` URL the transport sets TLS with peer and hostname checks again after applying your settings.

To use another HTTP stack, pass `http_client:`, an object with `call(method, url, headers, body, timeout)` that returns a `DecisionNode::HTTPResponse` and raises `DecisionNode::TimeoutError` or `DecisionNode::ConnectionError` when no response arrives. The client holds every transport to the same rules as its own:

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

## Development

```sh
bundle install
bundle exec rake test
DECISIONNODE_CONFORMANCE_DIR=/path/to/decision-node-conformance bundle exec rake conformance
```

The conformance tests run the language-neutral DecisionNode conformance suite against its mock server. They need `DECISIONNODE_CONFORMANCE_DIR`: without it, they fail rather than skip. CI runs conformance suite 1.3, checked out at the commit set once in `CONFORMANCE_REF` in `.github/workflows/ci.yml`; every action there is pinned to a commit SHA and every checkout sets `persist-credentials: false`.

This gem implements version 1.0 of the DecisionNode SDK surface (`DecisionNode::SPEC_VERSION`).

## License

MIT. See [LICENSE](LICENSE).
