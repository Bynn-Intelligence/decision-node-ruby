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

Six builders return a question's wire form as a plain Hash:

| Builder | Asks for |
|---|---|
| `DecisionNode.truth(instructions, if_true: nil, if_false: nil)` | The probability that something is true. `if_true` and `if_false` describe each side and are optional. |
| `DecisionNode.choice(instructions, options)` | One option of a set. `options` is a Hash of name to description, or an Array of names. |
| `DecisionNode.score(instructions, levels)` | A place on an ordered scale. `levels` is an Array, listed from low to high. |
| `DecisionNode.number(instructions, min: nil, max: nil, step: nil)` | A value on a grid from `min` to `max` in steps of `step`. A bound left out is left out of the request, so the server's defaults apply: 0, 255 and 1. |
| `DecisionNode.point(instructions, image: nil, units: nil)` | One spot in an image (see "Points and boxes"). |
| `DecisionNode.box(instructions, image: nil, units: nil)` | A rectangle in an image (see "Points and boxes"). |

`include DecisionNode::Questions` makes them available as `truth(...)`, `choice(...)`, `score(...)`, `number(...)`, `point(...)` and `box(...)`.

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
  upload_timeout: 60,                        # seconds for one image PUT to storage
  logger: nil                                # a Logger for debug lines
)
```

Every argument is optional. An explicit argument wins over the environment, which wins over the default. An empty string for `api_key`, `base_url` or `model` counts as not given, here and for `model:` on a call. A client is safe to share between threads and keeps its connections alive, so repeated calls skip the TCP and TLS handshakes.

The client checks its arguments when it is made and raises `ArgumentError` for a bad one:

- `base_url` (from the argument or `DECISIONNODE_BASE_URL`) must use `https`. Plain `http` is accepted only for `localhost`, `127.0.0.1` and `::1`, so an API key never travels unencrypted.
- `timeout` must be above 0 seconds.
- `max_retries` must be a whole number, 0 or more.
- `inline_threshold` must be a whole number of bytes, 0 or more.
- `upload_timeout` must be above 0 seconds.

| Method | Returns |
|---|---|
| `decide(state:, questions:, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)` | A `DecisionNode::Decision` |
| `decide_many(requests, concurrency: 8)` | One `DecisionNode::DecisionResult` per request, in input order: a `Decision`, or the `DecisionNodeError` that request ended with |
| `check(state:, instructions:, if_true: nil, if_false: nil, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)` | A `TruthAnswer` |
| `classify(state:, instructions:, options:, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)` | A `ChoiceAnswer` |
| `score(state:, instructions:, levels:, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)` | A `ScoreAnswer` |
| `number(state:, instructions:, min: nil, max: nil, step: nil, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)` | A `NumberAnswer` |
| `gate(action:, context: nil, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)` | A `Decision` with the answers `risk` (score), `touches_production` (truth) and `verdict` (choice of `allow`, `confirm`, `block`) |
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
| `Decision` | `answers` (by question id, also `decision["id"]`), `model` (the resolved version), `usage.input_tokens`, `usage.output_tokens`, `usage.video_frames`, `usage.video_seconds`, `usage.booster_tokens`, `usage.boosters`, `evidence` (see "Boosters"), `fallback` (see "Fallback"), `warnings`, `request_id`, `latency_ms`, `safety`, `raw` |
| `TruthAnswer` | `truth` |
| `ChoiceAnswer` | `choice`, `confidence`, `probabilities` (by option name, exactly as sent) |
| `ScoreAnswer` | `score`, `confidence`, `probabilities` (by level index, an Integer), `legend` (level index to the level as sent) |
| `NumberAnswer` | `number` (the most probable value of the grid), `expected` (the probability-weighted mean), `confidence` (the probability of `number`), `probabilities` (by the value exactly as the server wrote it, `"7"`, `"3.5"`) |
| `PointAnswer` | `x`, `y`, `present`, `confidence`, `image`, `width`, `height` (see "Points and boxes") |
| `BoxAnswer` | `x1`, `y1`, `x2`, `y2`, `present`, `confidence`, `image`, `width`, `height` (see "Points and boxes") |
| `ModelInfo` | `name`, `description`, `release_date`, `limits` (every other field of the entry), and `sessions` and `batch`, the session and Batch API limits; `limit("sessions", "max_per_key")` reads one. A fine-tuned model's entry also has `fine_tuned`, `base`, `adapter_version` and `status` (see "Fine-tuned models") |

Answers are read by question id. An answer of a type this version does not know is returned as a `DecisionNode::UnknownAnswer` with its `type` and `raw` fields, so the rest of the decision still parses. So is an answer of a known type with a field missing or of the wrong type (a `truth` answer without a number in `truth`, for example): the decision does not fail. All answer classes derive from `DecisionNode::Answer`.

A token count or `latency_ms` the server did not send is `nil`, never 0. So are `usage.video_frames` and `usage.video_seconds` for a request without videos (`warnings` is then an empty Array), and `evidence`, `usage.booster_tokens` and `usage.boosters` for a request without boosters. `fallback` is `nil` on an ordinary answer.

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

An upload is one `POST /v1/uploads` for the request's images, then one `PUT` per image, in parallel, straight to storage with exactly the headers the API returned: never your API key, never your custom headers, and no redirect followed. Concurrent calls with the same bytes (`decide_many` over one document, for example) share one upload. Each `PUT` attempt has its own timeout, `upload_timeout` (60 seconds by default), apart from the API's `timeout`, so a 10 MB image on a slow link is not cut off at 10 seconds. The cache lives in the client's memory (at most 256 entries, keyed by the SHA-256 of the bytes and the media type) and is never written to disk. If the API answers that an upload the SDK placed has expired or been used up, the SDK uploads it again and sends the request once more. `upload(images)` uploads whatever the size and returns the upload ids, for use in later requests.

Every local image is checked before any request: its format from the first bytes (JPEG, PNG or WebP; a `media_type:` you give must match them), at most 10,485,760 bytes, and at most 40,000,000 pixels, read from the image header without decoding it. A request takes up to 16 images (URLs, inline and uploaded together), with unique ids; one upload call takes all of them. A 17th raises the API's `ValidationError`, a `too_long` entry on the images, before anything is sent. Many large images can still pass the model's token limit, which the API answers with a `ContextLimitError`. No image is ever resized or re-encoded. A file that cannot be read raises `ArgumentError` where the `Image` is made.

A request body may be at most 26,214,400 bytes (25 MiB). Inline images and video frames count toward it; uploaded images and URLs count only by their id or URL. The SDK measures the body as it will send it before anything is sent or uploaded, and raises `RequestTooLargeError` when it is over. Local images at or over the inline threshold are uploaded, so a request with images stays far under the limit; a base64 image in a wire-form Hash is sent as given and counts in full.

### Referring to images and videos

There are two ways to say which image a question is about:

1. **By id (recommended).** Give each image a short, meaningful id and use it in the instructions, in backticks: "Does the total on `receipt` match the amount in the claim?"
2. **By number.** Images are numbered from 1 in the order of `images:`: "image 2", "the second image", "Picture 2" and "the last image" all work.

The model sees each image as `Picture 1 (receipt):`, `Picture 2 (claim_photo):`, so both ways point to the same image. Prefer ids: they stay right when images are added or reordered. Use names, not digits, as ids (`front`, not `2`). Videos work the same way, by id or by number ("video 1"), numbered separately in the order of `videos:`. The `image` of a point or box question takes the id.

```ruby
dn.decide(
  state: "Expense claim 4411: 740.00 EUR.",
  images: [
    DecisionNode::Image.new("receipt", url: "https://files.example.com/claims/4411/receipt.jpg"),
    DecisionNode::Image.new("claim_photo", url: "https://files.example.com/claims/4411/photo.jpg")
  ],
  questions: { matches: DecisionNode.truth("Does the total on `receipt` match the amount in the claim?") }
)
```

## Points and boxes

A `point` question finds one spot in an image and a `box` question a rectangle around something, so the answer can be drawn, cropped or handed to a robot.

```ruby
d = dn.decide(
  images: [DecisionNode::Image.new("belt", url: "https://files.example.com/line-3/cam-2/0917.jpg")],
  questions: {
    pick: DecisionNode.point("Point to the yellow package closest to the robot arm."),
    damage: DecisionNode.box("Draw a box around the damaged package.", image: "belt"),
    any_damage: DecisionNode.truth("Is any package on the belt damaged?")
  }
)
d["pick"].x                       # => 812
d["pick"].y                       # => 455
d["damage"].x1                    # => 300 (top-left corner x1, y1; bottom-right x2, y2)
d["damage"].present               # => 0.95
d["any_damage"].truth             # => 0.93
```

| Argument | Meaning |
|---|---|
| `image:` | The id of the image to look in, a string. Needed when the request has two or more images; with one, that one is used. A reference by number ("Picture 2") goes in the instructions. |
| `units:` | `"pixels"` (the default): integers in pixels of the image as sent, after its EXIF orientation. `"normalized"`: fractions of the width and the height from 0 to 1. |

| Field | Meaning |
|---|---|
| `x`, `y` (point) | The spot, from the top-left corner of the image, `x` to the right and `y` down. |
| `x1`, `y1`, `x2`, `y2` (box) | The top-left and bottom-right corners, in the same units. |
| `present` | The probability that what the instructions describe is in the image at all. Under a low value the place is only the best guess for something that is probably absent. |
| `confidence` | The probability that the place is right if the thing is there. |
| `image`, `width`, `height` | The image looked in and its size in pixels. |

Every number is as the API sent it. Points and boxes go with `decide`, `decide_many` and batch requests. A request with a point or box question needs an image, and `image:` must name one of the request's images; these faults raise a `ValidationError` before anything is sent (see "Checked before sending").

## Videos

A video is sent as frames you already hold, each with its time in seconds: only the frames go to the API, never a video file, a video URL or sound. Every question sees every video, the images and the state.

```ruby
# JPEG frames from a camera, two a second
frames = camera_jpegs.each_with_index.map { |bytes, i| DecisionNode::VideoFrame.new(30 + (i * 0.5), data: bytes) }

d = dn.decide(
  state: "Warehouse camera 4, loading dock.",
  videos: [DecisionNode::Video.new("dock", frames: frames)],
  questions: { fall: DecisionNode.truth("Does a person fall in the video?") }
)
d["fall"].truth             # => 0.12
d.usage.video_frames        # the frames the API read
d.usage.video_seconds       # the seconds of video they cover
d.warnings                  # set when the API read a video at a lower rate or resolution
```

| Argument | Meaning |
|---|---|
| `VideoFrame.new(t, data:)`, `VideoFrame.new(t, path:)` | A frame's time in seconds (0 or more, larger than the frame before it) and its JPEG, PNG or WebP bytes; the media type comes from the bytes. |
| `VideoFrame.new(t, base64:, media_type:)` | The same from base64 text, sent as given, with its media type. |
| `Video.new(id, frames:, fps: nil, start: nil, end: nil)` | Up to 4 videos a request. `id` is unique across the request's images and videos. `fps` caps the rate the API reads (above 0, at most 4); `start` and `end` choose the window on the frames' own times. Each is sent only when given. |

Videos go with `decide`, the helpers, `decide_many` and batch requests; sessions take none. Frames are always sent inline as base64: they are never uploaded and never counted toward `inline_threshold`, and no frame is resized or re-encoded. A Hash in the API's wire form works wherever a `Video` or a `VideoFrame` does.

The SDK checks a video's form before sending, in the API's order and words: an id, ids unique across images and videos, a non-empty frame list, each frame's time a number of at least 0 and larger than the one before, a JPEG, PNG or WebP media type, `fps` above 0 and at most 4, `start` and `end` at least 0, and `end` after `start`. A fault raises `BadRequestError` with `error_type` `api_usage_error`. More than 4 videos raises the API's `ValidationError`, a `too_long` entry on the videos. How many frames a request may hold, a frame's bytes and size, and whether the window holds a frame are the API's to judge.

To turn a video file into frames, use the `dn` command line: `dn truth "Does a person fall?" --video dock.mp4` samples the file on your machine and sends only the frames.

## Boosters

A booster is a specialist model that reads the request's images before the decision. Its reading is added to what the model sees as evidence and comes back in the response. The model still answers every question: a booster never answers or adds one, and a request without boosters is answered exactly as before.

| Booster | Reads | Tells the model |
|---|---|---|
| `age` | A picture of a person | How old the person is, with a range and a confidence (the largest face is read) |
| `ai_generated` | Any picture | How likely the picture was made by an image generator, which generator most likely, and whether the file carries Content Credentials (C2PA) and who signed them |

```ruby
d = dn.decide(
  images: [
    DecisionNode::Image.new("a1b2", path: "selfie.jpg"),
    DecisionNode::Image.new("c3d4", url: "https://files.example.com/c3d4.jpg")
  ],
  boosters: %w[age ai_generated],
  questions: {
    adult: DecisionNode.truth("Is the person in the first picture an adult?"),
    synthetic: DecisionNode.truth("Is the second picture AI-generated?")
  }
)

d["adult"].truth                                    # => 0.97
age = d.evidence["age"]                             # a DecisionNode::Evidence
age.status                                          # => "ok"
age.results.first.age_years                         # => 27, with .low, .high, .confidence and .faces
d.evidence["ai_generated"].results.last.generated   # => 0.93
d.usage.booster_tokens                              # the readings' share of input_tokens
d.usage.boosters                                    # the booster calls billed
```

`boosters:` takes booster names, up to 4, each booster at most once, sent in the order given. A booster that needs a setting is a `DecisionNode::Booster`. Here `ai_generated` reads only the second picture, and the request fails if it cannot:

```ruby
d = dn.decide(
  images: images,
  boosters: ["age", DecisionNode::Booster.new("ai_generated", images: ["c3d4"], require: true)],
  questions: questions
)
```

`DecisionNode::Booster.new(name, images: nil, require: nil, options: nil)` is sent as `{"name": "ai_generated", "images": ["c3d4"], "require": true}`, each argument only when given; a Hash in that form works too. A `Booster` with no argument set is sent as its name, so the request stays the plain list:

| Argument | Meaning |
|---|---|
| `images` | The ids of the request's images the booster reads. Left out: every image of the request. |
| `require` | `true`: a booster that fails or does not answer in time fails the request with the 529 `booster_unavailable`, which is retried like every 529. Left out or `false`: the decision runs without that reading, and `evidence` says why. |
| `options` | The booster's settings, a Hash. |

Boosters go with `decide`, the helpers, `decide_many` and batch requests; sessions take none. They read images in every form: a URL, inline bytes or an upload. Without `boosters:` (or with an empty Array) the request has no `boosters` field at all. Nothing about boosters is checked before sending: the API answers a malformed list, an unknown name and a booster turned off before any booster runs and before any charge.

`d.evidence` holds one `DecisionNode::Evidence` per booster the request named, by name in the request's order, and is `nil` when it named none:

| Class | Fields |
|---|---|
| `Evidence` | `version` (the booster version that read), `status` (`ok`, `timeout`, `error` or `skipped`, when none of the request's images is one it reads), `latency_ms`, `billed_calls` (the calls of this booster billed on this request; a picture it read for your workspace in the last hour is not billed again), `results` (one reading per image read; empty unless `status` is `ok`), `raw` |
| `AgeReading` | `image`, `faces` (how many faces were found), and `age_years`, `low`, `high`, `confidence`, each `nil` when `faces` is 0 |
| `AiGeneratedReading` | `image`, `generated` (the probability that a generator made the picture), `confidence`, `method` (`inference`, read from the pixels, or `c2pa`, when the file's trusted Content Credentials declare it generated or edited by AI), `top_generator` (`name` and `probability` of the likeliest generator when the reading says likely generated; `nil` otherwise, and always on a `c2pa` reading), `c2pa_signer` (who signed the file's Content Credentials when they are trusted, else `nil`), `c2pa` (`"untrusted"` when the file carries Content Credentials that validate but are not trusted, which change nothing in the reading; else `nil`) |
| `UnknownReading` | `image` and `raw`: a reading of a booster this version does not know, or one with a field missing or of the wrong type. The decision still parses. |

Each booster call billed costs USD 0.002, drawn from the prepaid balance with the request's tokens: one call per booster and image read with status `ok`. A booster that timed out or failed is free, a picture the same booster read for your workspace in the last hour is not billed again, and a refused request bills none. The readings' tokens are input tokens at the model's price.

| Status | `error_type` | Error | When |
|---|---|---|---|
| 400 | `api_usage_error` | `BadRequestError` | `boosters` malformed: more than 4 entries, a booster named twice, an entry that is neither a name nor a Hash with `booster`, a key in `options`. The reason is in `reason`. |
| 400 | `booster_unknown` | `BadRequestError` | A name that is not a booster |
| 400 | `booster_input_mismatch` | `BadRequestError` | A booster that reads images on a request without any, or an `images` entry that is not an image of the request |
| 403 | `booster_not_enabled` | `PermissionDeniedError` | The booster is turned off for the workspace (an owner or admin turns boosters on and off in the console) |
| 529 | `booster_unavailable` | `OverloadedError` | A booster with `require: true` failed or did not answer in time; retried |

Every error carries `boosters`, the `x-decisionnode-boosters` header as booster name to `DecisionNode::BoosterStatus` (`status`, `latency_ms`) in the request's order, so you can see which required booster failed:

```ruby
begin
  dn.decide(images: images, questions: questions, boosters: [DecisionNode::Booster.new("ai_generated", require: true)])
rescue DecisionNode::OverloadedError => e
  e.boosters["ai_generated"]&.status # => "timeout"
end
```

## Fine-tuned models

A model your workspace fine-tuned in the console is called by its name in `model:`, by the keys of that workspace, and answers like its base model: the same question types, answers, limits and errors.

```ruby
d = dn.decide(state: claim, questions: questions, model: "decisionnode-1.0-flash@acme/fraud")
d.model # => "decisionnode-1.0-flash@acme/fraud:3", the version that answered
```

The name is `<base>@<workspace>/<name>`, which means the version deployed most recently, or `<base>@<workspace>/<name>:<n>` for one version. The SDK sends it as given; a name that does not exist, is not deployed or belongs to another workspace raises the API's `BadRequestError` ("Unknown model: ..."). `Decision#model` is always the pinned name with its version. `models` lists your workspace's fine-tuned models beside the catalogue, each `ModelInfo` with `fine_tuned` (`true`), `base` (the base model), `adapter_version` (its version number) and `status` (`deployed`, which answers decisions, or `ready`, trained but not deployed); these are `nil` on a catalogue model.

## Fallback

A request for `decisionnode-1.0` that no ready worker can take at once is answered by `decisionnode-1.0-flash` instead, billed at Flash's price. `d.model` is then the model that answered, and `d.fallback` names both:

```ruby
d = dn.decide(state: ticket, questions: questions, model: "decisionnode-1.0")
d.fallback # => #<struct DecisionNode::Fallback served_model="decisionnode-1.0-flash", requested_model="decisionnode-1.0">
```

`d.fallback` is `nil` on an ordinary answer. Pass `fallback: false` (on `decide`, the helpers, `decide_many` requests and batch requests) to get the 529 `OverloadedError` instead, which is retried like every 529; left out, the API's default (`true`) applies and the request carries no `fallback` field. Sessions, batch lines and fine-tuned models never fall back.

## Checked before sending

The SDK checks every fixed rule the API documents before any network call, so the server never sees a request the client could have refused. A fault raises what the server would answer: the same class, the same `error_type`, the documented message, and for a 422 a `ValidationError` whose `entries` are the server's list. A local error has no `status` and no `request_id`. The checks run in the server's order: the nesting limit, the 422 entries, the first 400 in question order, then the images, then the videos.

| Fault | Error | `error_type` |
|---|---|---|
| More than 128 objects and arrays inside each other; an unknown question type | `BadRequestError`, "Invalid request." | `api_usage_error` |
| A question that is not a Hash or has no `type`; instructions, a state, an option description, a score level or a truth side that is not a String, Hash or Array; a choice or score without criteria, or with criteria of the wrong shape; a score with no levels | `ValidationError` with the server's `entries` | null |
| A number grid: a bound that is not a finite number, beyond 2^53, `step` not above 0, more than 6 decimals in `min` or `step`, beyond the decimal bound, `min` above `max`, more than 4,096 values (counted in exact decimals) | `ValidationError` with the server's `entries` | null |
| A choice with no options or more than 255, a score with more than 10 levels, a truth question with neither instructions nor criteria, a number, point or box question without instructions | `BadRequestError` with the API's documented message | null |
| A point or box question in a request with no image, without `image:` when the request has two or more, with an `image:` that is not one of the request's image ids, or with `units:` other than `"pixels"` and `"normalized"` | `ValidationError` with the server's `entries` | null |
| More than 16 images or more than 4 videos (a `too_long` entry on the list, after the state's and the questions' entries) | `ValidationError` with the server's `entries` | null |
| An empty or repeated image id, bytes that are not JPEG, PNG or WebP or not of the declared type, over 10,485,760 bytes or 40,000,000 pixels, an upload reference with another media type, a URL that is not `https` | `BadRequestError` | `api_usage_error` |
| An `https` image URL over 2,048 characters, with user information, on a port other than 443, without a host, or naming a private or reserved address literally | `BadRequestError` | `image_url_refused` |
| A video fault: see "Videos" | `BadRequestError` with the API's message | `api_usage_error` |
| `open_session`: `window` outside 1 to 64, `ttl_seconds` outside 1 to 3,600 | `ValidationError` with the server's `entries` | null |
| `Session#send`: see "Sessions" | `BadRequestError` | `api_usage_error` |
| `batches.create` and `add`: a missing, empty, non-String or repeated `custom_id`, an add with no requests; `batches.list`: `offset` below 0, `limit` outside 1 to 100 | `BadRequestError` with the API's documented message | `api_usage_error` |

After a `models` call the client also holds the limits `/v1/models` publishes and checks them: a session's `max_window` and `max_ttl_seconds`, a model that serves no sessions or answers no number questions, a batch's `requests_per_batch` and `max_custom_id_chars`, and the image and option bounds. A request's model is found in that list by its name, else by the entry that states it as its `alias` or pinned `version`, so `decisionnode-latest` takes the limits of the version it points to. Without that call, or for a model the list does not state, those checks are left to the server. Limits counted in tokens are always the server's to judge. `decide_raw` sends its body unchecked.

A bad argument raises Ruby's own `ArgumentError`, never a DecisionNode class: a `base_url`, `timeout`, `max_retries` or `inline_threshold` the client refuses, a `concurrency` below 1, an empty question map, an image file that cannot be read, and a value that cannot be serialised as JSON. A missing API key raises `AuthenticationError`, also without a request.

### Checking without sending

`check_request(method, request)` runs every check a call would run before sending, alone: it raises exactly what the call would raise (held `/v1/models` limits included) and returns `nil` when the request would be sent. It sends nothing and uploads nothing. `method` is `"decide"`, `"open_session"`, `"batches.create"` or `"batches.add"`; `request` holds the call's arguments, as a Hash or as keywords.

```ruby
dn.check_request("decide", state: ticket, questions: questions, images: images, videos: videos) # => nil
dn.check_request("open_session", questions: questions, window: 128)
# raises DecisionNode::ValidationError, as open_session would
dn.check_request("batches.create", requests: requests)
```

`Session#check_frame(frame:, image:, questions:, reset:, seq:)` does the same for a frame: it raises what `Session#send` would and writes nothing, uses no `seq`, and needs no connected socket.

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
| `Session#send(frame:, image:, questions:, reset:, seq:)` | Sends one frame and returns its `seq`, counted from 1 unless given; never waits for a reply. A frame's image follows the threshold of "Images". A frame that breaks a fixed rule (no frame and no image, an empty frame, a `seq` out of range, an empty question list or an id the session does not have, a `reset` that is not a boolean, nesting over 128, a URL image, an image the API would refuse) raises `BadRequestError`: nothing is written and the frame takes no `seq` |
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
| `results(batch_id)` | `GET /v1/batches/{id}/results`, read from the network line by line as it arrives | One `BatchResult` per request, in upload order; with a block, each one as its line arrives |
| `cancel(batch_id)` | `POST /v1/batches/{id}/cancel` | `Batch` |

A `Batch` has every field of the batch object by name (`id`, `state`, `counters`, `created_at`, `finalized_at`, `expires_at`, `ended_at`, `results_url`, `results_expire_at`, `price_factor`, `usage`, `error`) and `ended?`. A `BatchResult` has `custom_id`, `status` (an Integer, or `"expired"` or `"cancelled"`), `headers`, `decision` (a `Decision` for a 200 line) and `error` (for an error line, the error `decide` would have raised, as a value).

Every line carries `custom_id`, `model` (the request's, else the client's) and `state` (`""` when absent), and every line of a call is checked before anything is sent. Its images follow the threshold of "Images", per line, and its videos go inline with it. `get`, `list`, `results` and `cancel` are retried like every call. `create`, `add` and `finalize` are retried only on 429 and 529, never after a timeout, a lost answer or a 5xx, since a repeat could make a second draft. A `finalize` answered with a 409 is resolved by reading the batch: if it is no longer a draft, the earlier finalize went through and the batch is returned.

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

Every error derives from `DecisionNode::DecisionNodeError`, which has `status`, `error_type`, `message`, `request_id`, `reason` and `boosters` (see "Boosters"; an empty Hash for a request without boosters). The error's `message` is the server's message, or the SDK's description when no response arrived; it is an empty string when the server sent none. `reason` is the server's explanation in words from the `x-decisionnode-error` header, for example `question 'q': a score takes up to 10 levels, got 11`. The report Ruby prints for an uncaught error adds the class, status and reason.

| Status | Error | Extra fields |
|---|---|---|
| 400 | `BadRequestError`; `ContextLimitError` when `error_type` is `max_tokens_exceeded` | |
| 401 | `AuthenticationError` | |
| 402 | `InsufficientCreditError` | |
| 403 | `RefusalError` when the request was refused (`error_type` `refusal_error`), else `PermissionDeniedError` (a booster turned off for the workspace, a suspended workspace; `error_type` tells them apart) | `category` (`harm` or `self_harm`), `safety` |
| 404 | `NotFoundError` | |
| 413 | `RequestTooLargeError`: the body is over 26,214,400 bytes (25 MiB); also raised before sending, with no status | |
| 422 | `ValidationError` | `entries` |
| 429 | `RateLimitError`; `SessionLimitError` when `error_type` is `session_limit_exceeded` | `retry_after` (seconds) |
| 529 | `OverloadedError`, also for `booster_unavailable` (a required booster failed) | `retry_after` (seconds) |
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
- 400, 401, 402, 403, 404, 413 and 422 are never retried, and neither is a session limit. Batch create, add and finalize follow their own rule (see "Batches"). An image `PUT` to storage is retried on 5xx and connection errors in the same way.

## Configuration

| Setting | Argument | Environment variable | Default |
|---|---|---|---|
| API key | `api_key:` | `DECISIONNODE_API_KEY` | none |
| Base URL | `base_url:` | `DECISIONNODE_BASE_URL` | `https://api.decisionnode.com` |
| Model | `model:` | `DECISIONNODE_MODEL` | `decisionnode-latest` |
| Inline threshold | `inline_threshold:` | | `524288` bytes |
| Upload timeout | `upload_timeout:` | | `60` seconds per image `PUT` |

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
- A transport may also answer `stream(method, url, headers, timeout) { |chunk| ... }`, handing a 2xx body over in chunks as it arrives; batch results are then read line by line. Without it they are read from the whole body.
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

A session's socket is opened with the standard library's TCP and TLS sockets and the `websocket-driver` gem, and follows the default transport as far as a WebSocket can: it goes through the transport's `proxy:` (else the proxy the environment names, `no_proxy` honoured) with an HTTP `CONNECT` tunnel, and its TLS takes the `net_http:` trust and client certificate settings (`ca_file`, `ca_path`, `cert_store`, `cert`, `key`, and the version and cipher settings). Certificate and hostname checks are always on. A transport of your own can say what sessions take by answering `session_options` with `{proxy:, tls:}`; without it the environment's proxy and the default trust apply.

## Development

```sh
bundle install
bundle exec rake test
DECISIONNODE_CONFORMANCE_DIR=/path/to/decision-node-conformance bundle exec rake conformance
```

The conformance tests run the language-neutral DecisionNode conformance suite (version 1.11) against its mock server. They need `DECISIONNODE_CONFORMANCE_DIR`: without it, they fail rather than skip.

This gem implements version 1.3 of the DecisionNode SDK surface (`DecisionNode::SPEC_VERSION`).

## License

MIT. See [LICENSE](LICENSE).
