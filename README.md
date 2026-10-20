# DecisionNode Ruby SDK

[DecisionNode](https://decisionnode.com) is a decision engine: send it text, JSON or images with a question, and it answers with calibrated probabilities.

Ruby client for the [DecisionNode](https://decisionnode.com) API: ask yes-or-no, choice, score and number questions about any state and get calibrated answers back, one request at a time, over a live session, or as a batch.

Ruby 3.2 or later. One runtime dependency, `websocket-driver`, used by sessions only and loaded on the first one.

## Install

Not on RubyGems yet: the first release publishes it there. Until then, install it from GitHub:

```sh
bundle add bynn-decisionnode --git https://github.com/Bynn-Intelligence/decision-node-ruby
```

Once it is on RubyGems:

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

A key's kind decides what it may call: Full access for your servers, Decisions only for a device or a service that only decides, Manage device keys for the server that hands out device keys, and Publishable for a web page or an app. See [API keys](https://decisionnode.com/docs/concepts/keys).

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
  model: "decisionnode-moe",                 # else DECISIONNODE_MODEL
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
| `Decision` | `answers` (by question id, also `decision["id"]`), `model` (the resolved version), `usage.input_tokens`, `usage.output_tokens`, `usage.video_frames`, `usage.video_seconds`, `usage.booster_tokens`, `usage.boosters`, `usage.cost`, `evidence` (see "Boosters"), `fallback` (see "Fallback"), `warnings`, `request_id`, `latency_ms`, `safety`, `raw` |
| `TruthAnswer` | `truth` |
| `ChoiceAnswer` | `choice`, `confidence`, `probabilities` (by option name, exactly as sent) |
| `ScoreAnswer` | `score`, `confidence`, `probabilities` (by level index, an Integer), `legend` (level index to the level as sent) |
| `NumberAnswer` | `number` (the most probable value of the grid), `expected` (the probability-weighted mean), `confidence` (the probability of `number`), `probabilities` (by the value exactly as the server wrote it, `"7"`, `"3.5"`) |
| `PointAnswer` | `x`, `y`, `present`, `confidence`, `image`, `width`, `height` (see "Points and boxes") |
| `BoxAnswer` | `x1`, `y1`, `x2`, `y2`, `present`, `confidence`, `image`, `width`, `height` (see "Points and boxes") |
| `ModelInfo` | `name`, `description`, `release_date`, `limits` (every other field of the entry, its prices included), the prices as sent, each `nil` when the entry states none (`price_per_million_input`, `price_per_million_output`, `price_per_million_image` and `price_per_million_video`, in USD per million tokens, and `batch_price_factor`, which a fine-tuned model does not state), and `sessions` and `batch`, the session and Batch API limits; `limit("sessions", "max_per_key")` reads one. A fine-tuned model's entry also has `fine_tuned`, `base`, `adapter_version` and `status` (see "Fine-tuned models") |

Answers are read by question id. An answer of a type this version does not know is returned as a `DecisionNode::UnknownAnswer` with its `type` and `raw` fields, so the rest of the decision still parses. So is an answer of a known type with a field missing or of the wrong type (a `truth` answer without a number in `truth`, for example): the decision does not fail. All answer classes derive from `DecisionNode::Answer`.

A token count or `latency_ms` the server did not send is `nil`, never 0. So are `usage.video_frames` and `usage.video_seconds` for a request without videos (`warnings` is then an empty Array), and `evidence`, `usage.booster_tokens` and `usage.boosters` for a request without boosters. `fallback` is `nil` on an ordinary answer.

`usage.cost` is what the answer cost, a `DecisionNode::Cost` with `usd`, `model_usd` and `boosters_usd` in USD and `free_tier` (true when the free tier paid for it). It is read as sent, never summed by the SDK, and `nil` when the response has none. A batch result's decision and a session frame's reply carry it too.

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
| `face_detection` | Any picture | How many faces the picture shows and where, a box and a confidence for each |
| `face_recognition` | A picture of a person | Which faces match the collection the request names (see Collections): a box, a score and the matched item's reference for each |
| `ocr` | Any picture | The picture's text, whole, or what the booster's `prompt` asks for |
| `bynn_depth` (Depth Vision) | Any picture | How far away things are, in meters: the nearest obstacle straight ahead, seven directions from left to right, and a grid of the picture |
| `bynn_segment` (Segment Vision) | Any picture | Where the things you name in words are: each one's outline, box and centre, and with depth on, its distance and size in meters |
| `knowledge` (Knowledge) | The request's state and questions, never a picture | The passages of your own documents that apply to the request, as facts and rules to apply (see Knowledge) |

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
| `options` | The booster's settings, a Hash, for boosters that have any. The API checks them. |

| Booster | `options` |
|---|---|
| `face_recognition` | `collection` (required): `celebrities`, or the id of one of your collections; `threshold`, 0 to 1 (0.5): a face scored below it is no match |
| `ocr` | `prompt`: the model's instruction, at most 2,000 characters; left out, all the visible text |
| `bynn_depth` | `grid_size`: the grid's cells per side, 2 to 16 (8) |
| `bynn_segment` | `prompt` (required): what to find, one phrase as a String or 1 to 4 phrases as an Array, each at most 120 characters; `max_instances`, 1 to 16 (8); `min_score`, 0 to 1 (0.25); `polygon_points`, the points of each outline, 3 to 64 (24); `depth`, distances and sizes in meters (`true`) |
| `knowledge` | `collection` (required): a knowledge base's id; `query`, `scope`, `match`, `filter`, `top_k`, `max_tokens`, `pinned`, `min_score`, `include_text` (see Knowledge). `DecisionNode.knowledge(collection, ...)` builds it |

```ruby
d = dn.decide(
  images: [DecisionNode::Image.new("cam", url: "https://files.example.com/drone/frame-0412.jpg")],
  boosters: [
    DecisionNode::Booster.new("bynn_depth", options: { "grid_size" => 8 }),
    DecisionNode::Booster.new("bynn_segment", options: { "prompt" => ["landing pad", "person"] })
  ],
  questions: { clear: DecisionNode.truth("Is the landing pad clear of people?") }
)

depth = d.evidence["bynn_depth"].results.first     # a DecisionNode::DepthReading
[depth.ahead, depth.directions[3], depth.ground]   # => [3.21, 2.81, true]
d.evidence["bynn_segment"].results.first.instances.each do |found|
  puts [found.label, found.score, found.centroid, found.depth&.median].inspect
end
```

`bynn_segment`'s `prompt` as a String is always one phrase; send several as an Array. Descriptive phrases match better than short names: "purple octagonal frame on a pole" finds what "purple gate" may not. Each picture it reads is one booster call, its depth included. Depth Vision's and Segment Vision's distances are estimates from one picture, for decisions and planning, never a safety stop: a robot or a drone uses stereo cameras or LiDAR for that.

Boosters go with `decide`, the helpers, `decide_many` and batch requests; sessions take none. They read images in every form: a URL, inline bytes or an upload. Without `boosters:` (or with an empty Array) the request has no `boosters` field at all. Nothing about boosters is checked before sending: the API answers a malformed list, an unknown name and a booster turned off before any booster runs and before any charge.

`d.evidence` holds one `DecisionNode::Evidence` per booster the request named, by name in the request's order, and is `nil` when it named none:

| Class | Fields |
|---|---|
| `Evidence` | `version` (the booster version that read), `status` (`ok`, `timeout`, `error` or `skipped`, when none of the request's images is one it reads), `latency_ms`, `billed_calls` (the calls of this booster billed on this request), `results` (one reading per image the booster was to read; a picture it did not read, because it timed out or failed, or could not decode, `readable` false, is an `UnknownReading` holding those fields, and `status` says why), `raw` |
| `AgeReading` | `image`, `faces` (how many faces were found), and `age_years`, `low`, `high`, `confidence`, each `nil` when `faces` is 0 |
| `AiGeneratedReading` | `image`, `generated` (the probability that a generator made the picture), `confidence`, `method` (`inference`, read from the pixels, or `c2pa`, when the file's trusted Content Credentials declare it generated or edited by AI), `top_generator` (`name` and `probability` of the likeliest generator when the reading says likely generated; `nil` otherwise, and always on a `c2pa` reading), `c2pa_signer` (who signed the file's Content Credentials when they are trusted, else `nil`), `c2pa` (`"untrusted"` when the file carries Content Credentials that validate but are not trusted, which change nothing in the reading; else `nil`) |
| `FaceDetectionReading` | `image`, `faces` (how many faces the picture shows; 0 is a reading), `detections` (at most 64, each a `FaceDetection`: `box`, a `FaceBox` with the corners `x1`, `y1`, `x2`, `y2` in the request's units, and `confidence`) |
| `FaceRecognitionReading` | `image`, `faces` (how many faces were searched), `matches` (best first, each a `FaceMatch`: `box`, `score`, `collection`, `reference`, `name` for a public figure, `label` and `metadata` for your own item, `collection_name`), `collection_name` (your collection's name) |
| `KnowledgeReading` | One reading, not one per picture: the passages found, with their citations (see Knowledge) |
| `OcrReading` | `image`, `text` (the reading; empty when the picture shows no text), `truncated` (`true` when the reading was cut at the model's context limit) |
| `DepthReading` | `image`, `ahead` (meters to the nearest obstacle straight ahead, the floor left out; `nil` when none is found), `directions` (7 entries, left to right, each meters or `nil`), `ground` (whether a floor or ground was found and left out), `grid_rows`, `grid_cols`, `grid` (rows of meters from the top left), `depth_min`, `depth_max`, `depth_median`, `width`, `height` (the picture's size in pixels) |
| `SegmentReading` | `image`, `width`, `height`, `prompts` (the phrases searched for), `instances` (best first, each a `SegmentInstance`: `label`, `score`, `box` `[x1, y1, x2, y2]`, `polygon` `[[x, y], ...]`, `area`, `centroid` `[x, y]`, `opening` (a `SegmentOpening` for the hole of a gate, a doorway or a ring, or `nil`), `depth` (a `SegmentDepth`: `median`, `opening_median`, `opening_rim_median`) and `size_m` (a `SegmentSize` in meters: `width`, `height`, `opening`), both `nil` with depth off), `depth_source`, `assumed_hfov_deg`. Coordinates are fractions of the picture from its top left |
| `UnknownReading` | `image` and `raw`: a reading of a booster this version does not know, or one with a field missing or of the wrong type. The decision still parses. |

A request whose boosters name `ocr` waits 30 seconds per attempt when the client has no `timeout:` of its own; a `timeout:` you set is used as given, even below 30. Such a request is never retried after a timeout, because the server finishes that attempt and may bill it: the `TimeoutError` is raised instead. Its other retries stay. Set a timeout of at least 30 seconds for requests that name `ocr`.

Booster calls are drawn from the prepaid balance with the request's tokens: one call per booster and image read with status `ok`. A booster that timed out or failed is free, and a refused request bills none. The readings' tokens are input tokens at the model's price. The price per call is on the [pricing page](https://decisionnode.com/docs/pricing#boosters).

| Status | `error_type` | Error | When |
|---|---|---|---|
| 400 | `api_usage_error` | `BadRequestError` | `boosters` malformed: more than 4 entries, a booster named twice, an entry that is neither a name nor a Hash with `name`, a key in `options` the booster does not take. The reason is in `reason`. |
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
d = dn.decide(state: claim, questions: questions, model: "decisionnode-moe@acme/fraud")
d.model # => "decisionnode-moe@acme/fraud:3", the version that answered
```

The name is `<base>@<workspace>/<name>`, the base a family id (`decisionnode-moe` or `decisionnode-flash`), which means the version deployed most recently, or `<base>@<workspace>/<name>:<n>` for one version. The SDK sends it as given; a name that does not exist, is not deployed or belongs to another workspace raises the API's `BadRequestError` ("Unknown model: ..."). `Decision#model` is always the pinned name with its version. `models` lists your workspace's fine-tuned models beside the catalogue, each `ModelInfo` with `fine_tuned` (`true`), `base` (the base model), `adapter_version` (its version number) and `status` (`deployed`, which answers decisions, or `ready`, trained but not deployed); these are `nil` on a catalogue model.

## Fallback

A `decisionnode-moe` request that no ready worker can take at once is answered by Flash instead, billed at Flash's price. `d.model` is then the model that answered, and `d.fallback` names both: the model that answered by its pinned id, and the model asked for as it was asked (a family id or an older id as the family id, a pinned id as itself):

```ruby
d = dn.decide(state: ticket, questions: questions, model: "decisionnode-moe")
d.fallback # => #<struct DecisionNode::Fallback served_model="decisionnode-flash-<version>", requested_model="decisionnode-moe">
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
| An empty or repeated image id, an id longer than 64 characters (counted in characters, not bytes: "Image 1: its id is longer than 64 characters.", the image counted from 0), bytes that are not JPEG, PNG or WebP or not of the declared type, over 10,485,760 bytes or 40,000,000 pixels, an upload reference with another media type, a URL that is not `https` | `BadRequestError` | `api_usage_error` |
| An `https` image URL over 2,048 characters, with user information, on a port other than 443, without a host, or naming a private or reserved address literally | `BadRequestError` | `image_url_refused` |
| A video fault: see "Videos" | `BadRequestError` with the API's message | `api_usage_error` |
| `open_session`: `window` outside 1 to 64, `ttl_seconds` outside 1 to 3,600 | `ValidationError` with the server's `entries` | null |
| `Session#send`: see "Sessions" | `BadRequestError` | `api_usage_error` |
| `batches.create` and `add`: a missing, empty, non-String or repeated `custom_id`, an add with no requests; `batches.list`: `offset` below 0, `limit` outside 1 to 100 | `BadRequestError` with the API's documented message | `api_usage_error` |

After a `models` call the client also holds the limits `/v1/models` publishes and checks them: a session's `max_window` and `max_ttl_seconds`, a model that serves no sessions or answers no number questions, a batch's `requests_per_batch` and `max_custom_id_chars`, and the image and option bounds. A request's model is found in that list by its name, else by the entry that states it as its `alias` or pinned `version`, so `decisionnode-moe` takes the limits of the pinned version it points to. Without that call, or for a model the list does not state, those checks are left to the server. Limits counted in tokens are always the server's to judge. `decide_raw` sends its body unchecked.

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

## Collections

A collection holds faces your workspace enrolled, each under your own `reference`, so a `face_recognition` booster can match a picture against them. `dn.collections` returns each answer as the API sent it, a Hash with the API's field names.

```ruby
staff = dn.collections.create(name: "Staff")
dn.collections.enroll(staff["id"], image: DecisionNode::Image.new("badge", path: "badge.jpg"),
                      reference: "emp-1042", label: "Reception", metadata: { "desk" => 4, "remote" => false })

page = dn.collections.list_items(staff["id"], reference_prefix: "emp-")
item = page["items"].first
dn.collections.update_item(staff["id"], item["id"], label: nil)            # clears the label
dn.collections.update_item(staff["id"], item["id"], metadata: { "desk" => 7 }) # replaces the whole object
```

| Call | Sends |
|---|---|
| `create(name:, type: "face")` | `POST /v1/collections` |
| `list`, `get(id)`, `delete(id)` | `GET /v1/collections`, `GET` and `DELETE /v1/collections/{id}` |
| `enroll(id, image:, reference:, label: nil, metadata: nil)` | one face from one image, sent as a decision sends its images |
| `update_item(id, item_id, reference:, label:, metadata:)` | `PATCH` with only the fields given: `label: nil` clears the label, `metadata` replaces the item's whole object (`{}` clears it) |
| `list_items(id, offset:, limit:, reference:, reference_prefix:)` | one page; `reference` finds the items of one reference, `reference_prefix` those whose reference starts with it (not both) |
| `delete_item(id, item_id)` | removes one item |

A reference is 1 to 64 of `A-Z a-z 0-9 _ . : -`, a label 1 to 128 characters, and metadata a Hash of at most 20 keys of 1 to 40 of `a-z 0-9 _`, each value a text of at most 500 characters, a number, true or false. They are checked before sending, with the API's `ValidationError` or `BadRequestError`. `create`, `enroll` and `update_item` send an `Idempotency-Key`, a new UUID for each call and the same on every attempt of it, so the API acts and bills once however often the call is tried. They retry like every call, and also on a 409 `idempotency_in_progress` after its `Retry-After`; a 409 `idempotency_key_reused` is raised.

## Knowledge

A knowledge base holds your workspace's own documents: a claims policy, house rules, a mission's special instructions. The `knowledge` booster finds the passages that apply to a request and gives them to the decision as facts and rules to apply, with citations back to each document. A knowledge base is a collection of type `text`, under `dn.collections` with the face collections, and every call returns the API's answer as sent, a Hash with the API's field names.

### 1. Create a knowledge base

```ruby
kb = dn.collections.create(name: "Claims policy", type: "text", scope_key: "mission")
kb["id"] # => "col_3f6c..."
```

`scope_key` is optional, 1 to 40 of `a-z 0-9 _`, and fixed for the knowledge base's life. It names the one metadata key whose value scopes a document to, say, one mission (step 3).

### 2. Add documents

```ruby
policy = DecisionNode::Document.new(text: <<~MD)
  # Receipts

  Reject any claim over 500 SEK without a receipt.
MD
dn.collections.add_document(kb["id"], document: policy, title: "Claims policy 2026", reference: "policy-2026")

item = dn.collections.add_document(kb["id"], document: DecisionNode::Document.new(path: "handbook.pdf"))
item["status"] # => "queued"
```

| `DecisionNode::Document` | What it is |
|---|---|
| `Document.new(text:, format: nil)` | Text in memory, `format` `"markdown"` (the API's default) or `"text"`. A text needs a `title:` |
| `Document.new(path:, content_type: nil, filename: nil)` | A local file, read when the call is made |
| `Document.new(data:, content_type: nil, filename: nil)` | The file's bytes |
| `Document.new(io:, content_type: nil, filename: nil)` | An IO, read to its end once, into memory, before anything is sent |
| `Document.new(upload_id:)` | A file uploaded before with `dn.upload_documents` |

A file's type comes from `content_type`, else from its name's extension, else from its first bytes (PDF, PNG, JPEG, TIFF, WebP); DOCX, PPTX, XLSX and text need a `content_type` or a file name. A file's title is its name without the extension unless you give `title:`. A text, and a text or Markdown file under the client's `inline_threshold` (512 KiB) that is UTF-8, go inline in one call; every other file is uploaded first (one presign and one PUT, 120 seconds per attempt or the client's `upload_timeout:`) and named by its upload id. `dn.upload_documents([doc, ...])` uploads 1 to 16 documents ahead of time and returns their upload ids, each usable for an hour.

PDF, DOCX, PPTX, XLSX, HTML and pictures are converted to text. Only the text is kept: the original file is deleted once its text is ready.

Ingestion is asynchronous: a document is `queued`, then `processing` (`stage` `extracting` for a converted file, `chunking`, `embedding`), then `ready` or `failed`, whose `error` says why. Wait for it in the call, or after:

```ruby
dn.collections.add_document(kb["id"], document: policy, title: "Claims policy 2026", wait: true) # up to 10 s on the server
dn.collections.wait_until_ready(kb["id"], item["id"])          # the item, ready or failed
dn.collections.wait_until_ready(kb["id"], timeout: 600)        # the knowledge base, once nothing is queued or processing
```

`wait: true` holds the call on the server up to 10 seconds and answers once the document is ready, else as it stands; such a call waits 20 seconds per attempt unless you set the client's `timeout:`. `wait_until_ready` reads at once, then every `poll_interval:` seconds (default 1, half as long again after each read, at most 10), and raises `DecisionNode::TimeoutError` past `timeout:` seconds (default 300).

### 3. Pin rules and scope documents

A rule that must always apply is pinned: a pinned document is given to every request that names the knowledge base, before any passage found by search. A document whose metadata holds the scope key's value is seen only by requests that name that value; a document without it is global.

```ruby
dn.collections.add_document(kb["id"], document: DecisionNode::Document.new(text: "Never approve a claim over 10,000 SEK."),
                                      title: "Hard limit", pinned: true, pin_rank: 0)
dn.collections.add_document(kb["id"], document: DecisionNode::Document.new(path: "m42-brief.md"),
                                      metadata: { "mission" => "M-42" })
dn.collections.update_item(kb["id"], item["id"], pinned: true)  # applied at once, never billed again
```

### 4. Decide with knowledge

```ruby
d = dn.decide(
  state: { claim: { amount: "740.00", receipt: false }, mission: "M-42" },
  questions: { approve: DecisionNode.truth("Should the claim be approved under our policy?") },
  boosters: [DecisionNode.knowledge(kb["id"], scope: "M-42", require: true)]
)

reading = d.evidence["knowledge"].results.first # a DecisionNode::KnowledgeReading
reading.passages.each do |p|
  puts [p.n, p.pinned, p.title, p.heading, p.score].inspect
end

p = reading.passages.first
text = dn.collections.get_item(kb["id"], p.item, include_text: true)["text"]
text.byteslice(p.byte_start, p.byte_end - p.byte_start) # the passage, cited
```

`DecisionNode.knowledge(collection, query:, scope:, match:, filter:, top_k:, max_tokens:, pinned:, min_score:, include_text:, require:)` builds the booster; each option is sent only when given, as given, and the API checks them. `collection` is required; `scope` names the scope key's value; `match` and `filter` select documents by metadata; `top_k` is the most passages found by search (4 by default; 0 gives the pins only); `max_tokens` is the passages' budget (`"auto"` or 128 to 8,192); `pinned: false` leaves the pins out; `min_score` is a floor for passages found by meaning; `include_text: true` adds each passage's text (a full-scope key). `require: true` fails the request when the reading did not run. The booster reads no picture and goes with `decide`, the helpers, `decide_many` and batch requests.

| Class | Fields |
|---|---|
| `KnowledgeReading` | `collection`, `collection_name`, `corpus` (`{"version"}`), `query` (`{"source", "tokens", "text"}`), `budget` (`{"mode", "tokens", "entry", "cause"}`), `scope` (`{"key", "value"}`), `warnings` (`scope_not_named`, `over_budget`, `budget_floor`, `pinned_filtered`), `passages`, `omitted` (counts by cause), `pending_items`, `search`, `truncated` |
| `KnowledgePassage` | `n` (its number in the block), `pinned`, `item`, `chunk`, `byte_start`, `byte_end`, `reference`, `title`, `heading`, `tokens`, `score` (`nil` for a pin), `lexical`, `rendered`, `text` |

`byte_start` and `byte_end` are UTF-8 byte offsets into the document's stored text, end exclusive: slice with `byteslice`, as above. A publishable key's reading has `collection_name`, `reference`, `title` and `heading` `nil`. A reading with a field missing or of the wrong type is an `UnknownReading` holding its raw fields, and the decision still parses.

### 5. Search without a decision

```ruby
found = dn.collections.search(kb["id"], query: "claims without a receipt", scope: "M-42", top_k: 3)
found.passages.map(&:text)
```

`search` takes the booster's options and returns a `KnowledgeReading` with every passage's text. It is billed as one knowledge call and needs a full-scope key.

### 6. Errors

| Status | `error_type` | Error | When |
|---|---|---|---|
| 409 | `knowledge_collection_empty` | `DecisionNodeError` | `require: true` on a knowledge base with nothing ready and nothing pending: `details["items"]`, `details["failed"]` |
| 529 | `booster_unavailable` | `OverloadedError` | `require: true` while no document is ready yet but some are being ingested: retried after its `Retry-After` (5 s). With `details["reason"]` `ingestion_delayed` (`Retry-After` 60 s) it is raised at once, never retried: ingestion is delayed and you decide when to try again |
| 429 | `rate_limit_error` | `RateLimitError` | The workspace's ingestion rate: `details["reason"]` `ingest_queue_full` or `ingest_tokens_per_hour`; retried after its `Retry-After` |
| 413 | `item_too_large` | `RequestTooLargeError` | A text over 512 KiB once normalised |
| 422 | `invalid_text` | `ValidationError` | A text that is not UTF-8 or holds a NUL; `entries` is empty |
| 409 | `reference_taken`, `pinned_budget_exceeded`, `chunks_limit_reached` | `DecisionNodeError` | The reference is another document's (`details["item_id"]`), the pinned documents are over their budget, the workspace's chunks are used up |
| 400 | `collection_type_mismatch` | `BadRequestError` | A face collection named by `knowledge` or `search` |
| 400 | `upload_purpose_mismatch` | `BadRequestError` | An image upload named as a document, or a document upload named as an image |
| 403 | `key_scope_denied` | `PermissionDeniedError` | `search`, `include_text` or a document upload from a key that is not full-scope |

### 7. Files and limits

| What | Limit |
|---|---|
| File types | Text, Markdown, PDF, DOCX, PPTX, XLSX, HTML, PNG, JPEG, TIFF, WebP |
| A file | 50 MB; a PDF 100 pages |
| A document's text | 512 KiB once extracted and normalised |
| `title` | 1 to 200 characters |
| `pin_rank` | 0 to 1,000 |

The title, `pin_rank`, a text's format, an empty text, the reference, the label, the metadata, the scope key, a file's size and type, and the paging of `list_items` and `list_chunks` are checked before sending, with the API's `ValidationError` or `BadRequestError`.

| Call | Sends |
|---|---|
| `create(name:, type: "text", scope_key: nil)` | `POST /v1/collections` |
| `add_document(id, document:, title:, reference:, pinned:, pin_rank:, label:, metadata:, wait: false)` | `POST /v1/collections/{id}/items` |
| `replace_document(id, item_id, document:, ...)` | `PUT`: a new version, the old one serving until it is ready; the same text again changes nothing |
| `update_item(id, item_id, reference:, label:, metadata:, pinned:, pin_rank:, title:)` | `PATCH` with only the fields given; a new title makes a new version |
| `get_item(id, item_id, include_text: false)` | `GET`, with the stored text when asked |
| `list_items(id, offset:, limit:, reference:, reference_prefix:, q:, sort:)`, `list_chunks(id, item_id, offset:, limit:)` | One page of documents (never their text; `q`, 1 to 200 characters, finds them by title, file name or reference, `sort` is `"newest"`, `"oldest"` or `"title"`), one page of a document's chunks |
| `delete_item(id, item_id)`, `delete_failed(id)`, `delete(id)` | One document; every failed document (`{"deleted" => n}`); the knowledge base (`{"deleted" => true}`, or `{"status" => "purging"}` while it finishes) |
| `wait_until_ready(id, item_id = nil, timeout: 300, poll_interval: 1)` | Reads until ready |
| `search(id, query:, ...)` | `POST /v1/collections/{id}/search` |

`add_document`, `replace_document` and `update_item` send an `Idempotency-Key`, the same on every attempt of a call. A knowledge call costs USD 0.001, one a request whatever it retrieves, with ingestion and storage on the [pricing page](https://decisionnode.com/docs/pricing#boosters).

## Device keys

A Manage device keys key, kept on your provisioning server, makes a Decisions-only key for each device as it enrolls, and changes or revokes it later. `dn.keys` returns each answer as the API sent it, a Hash with the API's field names.

```ruby
admin = DecisionNode.new(api_key: ENV.fetch("DECISIONNODE_MANAGE_KEY"))

created = admin.keys.create("Kiosk 0412", device_id: "kiosk-0412", labels: { "store" => "118", "fw" => "2.4" },
                                          limits: { "requests_per_second" => 5, "tokens_per_second" => 20_000 },
                                          daily_spend_cap: { "usd" => 2.0 },
                                          idempotency_key: "enroll-kiosk-0412") # a retried enrollment gets the same key back
secret = created["secret"] # hand it to the device once; never log it

admin.keys.update(created["key"]["id"], labels: { "store" => "120" })
loop { break unless admin.keys.revoke_by_labels({ "store" => "118" })["more"] }
```

| Call | Sends |
|---|---|
| `create(name, device_id:, labels:, limits:, daily_spend_cap:, expires_at:, may_search_collections:, idempotency_key:)` | `POST /v1/keys`, each field only when given: `{key, secret}`, the secret shown only here |
| `list(labels:, device_id:, status:, limit:, cursor:)` | one page of keys, newest first: `{items, next_cursor}`; `labels` keeps the keys with all of them, `status` is `active` (the default), `expired`, `revoked` or `all`, `limit` 1 to 200 |
| `all(labels:, device_id:, status:, limit:)` | every key `list` finds, its pages followed to the end |
| `update(key_id, name:, labels:, limits:, daily_spend_cap:, expires_at:, may_search_collections:)` | `PATCH` with only the fields given: `labels` replaces the whole set, and `nil` clears `labels`, `limits`, `daily_spend_cap` or `expires_at`; a key's `device_id` never changes |
| `revoke(key_id)` | `DELETE /v1/keys/{id}`: revoked at once |
| `revoke_by_labels(labels, device_ids:, dry_run:)` | every active key with all of `labels`, at most 10,000 a call: `{revoked, more}`; call again while `more` is true. `dry_run: true` counts them instead: `{would_revoke, more}` |

`create` sends an `Idempotency-Key`: yours when you pass one (one per enrollment), else a new UUID for each call, the same on every attempt of it, so a retried call makes one key. A retry with the same key and body within 24 hours returns the same key and secret.

What the API checks by fixed rules is checked before anything is sent, with its messages: a key's name (1 to 48 characters once trimmed), a `device_id` (1 to 128 printable ASCII characters, not starting with a space), labels (at most 16, each name 1 to 32 of `a-z`, `0-9`, `_`, `.` and `-`, each value 1 to 64 characters), `limits` being a Hash, and a `daily_spend_cap` from USD 0.01 to 1,000 in whole cents raise the API's `ValidationError` (the first fault, in the body's order); an update with nothing to change, a malformed `idempotency_key`, `list`'s filters and `limit`, and a bulk revoke without a label or with over 1,000 `device_ids` raise its `BadRequestError` or `ValidationError`. A limit's ceiling (your workspace's own), the expiry's window and a name's characters are the API's to judge. The whole flow is in [Keys on devices](https://decisionnode.com/docs/patterns/device-keys).

## Per-key usage

What each key used and cost over a period: a Full access key reads every key of its workspace, a Manage device keys key its Decisions-only keys. `dn.usage` returns each answer as the API sent it.

```ruby
one = dn.usage.key("key_7c2e9a41b0d34f6e8a5c1d2b3e4f5a60", granularity: "day")
items = dn.usage.all(start: "2026-10-01T00:00:00Z", end: "2026-11-01T00:00:00Z",
                     labels: { "customer" => "acme" }, status: "all")
items.each { |item| puts "#{item['key']['name']}: #{item['totals']['cost']['usd']}" }
```

| Call | Sends |
|---|---|
| `key(key_id, start:, end:, granularity:, group_by:)` | `GET /v1/keys/{id}/usage`; without `start` and `end`, the UTC month so far |
| `list(start:, end:, granularity:, group_by:, labels:, device_id:, key_ids:, scope:, status:, include_empty:, limit:, cursor:)` | `GET /v1/usage`, one page: `{period, as_of, items, next_cursor}`; pass `next_cursor` as `cursor` until it is `nil` |
| `all(start:, end:, ...)` | `list`'s arguments but `cursor`: every page's `items`, in order |

`start` and `end` are RFC 3339 times, rounded to the hour. `granularity` (`none`, `hour`, `day` or `month`) adds `buckets`, and `group_by` (`model` or `channel`) `by_model` or `by_channel`. `labels` keeps the keys with all of them, `key_ids` (at most 100) the keys named, `scope` (`full`, `decide` or `keys`) and `status` (`active`, `expired`, `revoked` or `all`) the keys of that kind or state; `include_empty: true` lists keys with no usage too; `limit` is 1 to 1,000. A page can hold fewer keys than `limit`, so only `next_cursor` says when the list is done: `all` follows it for you. These query rules are checked before sending, with the API's messages; the period's own rules are the server's. See [Usage](https://decisionnode.com/docs/api/usage).

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

The Batch API answers requests at the batch price: 50% off the live price on `decisionnode-flash`, 30% off on `decisionnode-moe`. The batch price is each model's, its `batch_price_factor` in `models` (0.5 and 0.7; a fine-tuned model's entry states none), never the batch's, and each line's charge is in its usage. There is no set time at which a batch runs or finishes, so poll for it. Requests not answered within 24 hours of finalizing expire and are not charged. A request is a Hash of `decide`'s arguments plus a `custom_id`.

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

A `Batch` has every field of the batch object by name (`id`, `state`, `counters`, `created_at`, `finalized_at`, `expires_at`, `ended_at`, `results_url`, `results_expire_at`, `usage`, `error`) and `ended?`. A `BatchResult` has `custom_id`, `status` (an Integer, or `"expired"` or `"cancelled"`), `headers`, `decision` (a `Decision` for a 200 line) and `error` (for an error line, the error `decide` would have raised, as a value).

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

Every error derives from `DecisionNode::DecisionNodeError`, which has `status`, `error_type`, `message`, `request_id`, `reason`, `boosters` (see "Boosters"; an empty Hash for a request without boosters) and `details` (the error body's `detail.details` when it is an object, for example `{"reason" => "enrollment_unpriced"}` on an enrollment's 529, else `nil`). The error's `message` is the server's message, or the SDK's description when no response arrived; it is an empty string when the server sent none. `reason` is the server's explanation in words from the `x-decisionnode-error` header, for example `question 'q': a score takes up to 10 levels, got 11`. The report Ruby prints for an uncaught error adds the class, status and reason.

| Status | Error | Extra fields |
|---|---|---|
| 400 | `BadRequestError`; `ContextLimitError` when `error_type` is `max_tokens_exceeded` | |
| 401 | `AuthenticationError` | |
| 402 | `InsufficientCreditError` | |
| 403 | `RefusalError` when the request was refused (`error_type` `refusal_error`), else `PermissionDeniedError` (a booster turned off for the workspace, a suspended workspace, a call outside the key's kind (`key_scope_denied`), and for a publishable key `origin_not_allowed` and `model_not_allowed`, its models in `details["allowed"]`; `error_type` tells them apart) | `category` (`harm` or `self_harm`), `safety` |
| 404 | `NotFoundError` | |
| 413 | `RequestTooLargeError`: the body is over 26,214,400 bytes (25 MiB); also raised before sending, with no status | |
| 422 | `ValidationError` | `entries` |
| 429 | `RateLimitError`; `SessionLimitError` when `error_type` is `session_limit_exceeded`; `error_type` `key_spend_cap_reached` for a key past its daily spend cap, with `details` `resets_at`, `cap` and `spent`; a publishable key's per-address rate and calls in flight with `details["reason"]` `client_rate` or `in_flight` | `retry_after` (seconds) |
| 529 | `OverloadedError`, also for `booster_unavailable` (a required booster failed) | `retry_after` (seconds) |
| other 5xx, a 2xx whose body is not JSON, or a helper's missing or malformed answer | `ServerError` | |
| any other status (a 3xx, 405, 409, 410, 408 once its retries are spent) | `DecisionNodeError` itself, with `status` | |
| no response | `ConnectionError`, `TimeoutError` | |

An error whose body is not the API's JSON (a page from a proxy or the service's edge, or no body at all) is classified by its status alone, from the table above: a 400 is a `BadRequestError` and a 403 a `PermissionDeniedError`, never their subclasses. Its `error_type` is `nil`, `request_id` and `reason` come from the headers, and `message` is the SDK's own description, `HTTP <status> <text>` with the request id after it when there is one: `HTTP 413 Content Too Large`, `HTTP 408 Request Timeout (request id req_edge_0408)`. The body is never read into the error. Retries follow the status as for any error.

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
- 400, 401, 402, 403, 404, 413 and 422 are never retried, and neither is a session limit, nor a 429 `key_spend_cap_reached` (the key's cap resets at 00:00 UTC, so it is raised at once), nor a 529 whose `details` reason is `enrollment_unpriced` (an enrollment with no price, which a retry never cures). Batch create, add and finalize follow their own rule (see "Batches"). An image `PUT` to storage is retried on 5xx and connection errors in the same way.

## Configuration

| Setting | Argument | Environment variable | Default |
|---|---|---|---|
| API key | `api_key:` | `DECISIONNODE_API_KEY` | none |
| Base URL | `base_url:` | `DECISIONNODE_BASE_URL` | `https://api.decisionnode.com` |
| Model | `model:` | `DECISIONNODE_MODEL` | `decisionnode-moe` |
| Inline threshold | `inline_threshold:` | | `524288` bytes |
| Upload timeout | `upload_timeout:` | | `60` seconds per image `PUT` |

Model ids: the family ids `decisionnode-moe` (the main model) and `decisionnode-flash` (faster and lower cost) always mean the current release. A pinned id is `decisionnode-<family>-<version>`, with the versions `models` lists, and every answer's `model` is the pinned id that answered. `model:` is free text: a pinned id, a fine-tuned model's name and the older ids the API still accepts (`decisionnode-1.0`, `decisionnode-1.0-flash`, `decisionnode-latest`, `decisionnode-flash-latest`) are sent as given.

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

The conformance tests run the language-neutral DecisionNode conformance suite (version 1.26) against its mock server. They need `DECISIONNODE_CONFORMANCE_DIR`: without it, they fail rather than skip.

This gem implements version 1.3 of the DecisionNode SDK surface (`DecisionNode::SPEC_VERSION`).

## License

MIT. See [LICENSE](LICENSE).
