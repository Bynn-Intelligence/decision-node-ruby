# frozen_string_literal: true

require "ipaddr"
require "json"
require "socket"

class DecisionNode
  # The API's fixed, documented request rules, checked before any request so
  # the server never sees a request the client could have refused. A fault
  # raises what the server would answer: the same class, the same
  # `error_type`, the documented message, and for a 422 a ValidationError
  # whose `entries` are the server's list. A local error has no status and no
  # request id. Checks run in the server's order: the nesting limit, every 422
  # entry, the first 400 in question order, then the images.
  #
  # A limit that only `GET /v1/models` states is checked against the value the
  # client holds from an earlier `models` call, and skipped when it holds none.
  # Token counts and anything that depends on server state stay the server's.
  module Checks
    MAX_IMAGES = 16
    # An image's id, counted in characters (code points), never bytes.
    MAX_IMAGE_ID_CHARS = 64
    MAX_VIDEOS = 4
    MAX_FPS = 4
    MAX_CHOICE_OPTIONS = 255
    MAX_SCORE_LEVELS = 10
    MAX_GRID_VALUES = 4_096
    MAX_NESTING = 128
    # The API's request body limit, 25 MiB, counted on the encoded body.
    MAX_BODY_BYTES = 26_214_400
    BODY_TOO_LARGE = "The request body is over 26,214,400 bytes (25 MiB). Send large images as uploads " \
                     "(POST /v1/uploads) and name them by upload_id."
    private_constant :MAX_IMAGE_ID_CHARS, :MAX_BODY_BYTES, :BODY_TOO_LARGE
    MAX_WINDOW = 64
    MAX_TTL_SECONDS = 3_600
    MAX_SEQ = (2**53) - 1
    TWO_53 = 2**53
    MAX_NUMBER_DECIMALS = 6
    LIST_LIMIT_MAX = 100
    CUSTOM_ID_CHARS = 512
    MEDIA_TYPES = %w[image/jpeg image/png image/webp].freeze
    UNITS = %w[pixels normalized].freeze
    GRID_DEFAULTS = { "min" => 0, "max" => 255, "step" => 1 }.freeze

    # Literal addresses an image URL may not name (IPv4-mapped and NAT64
    # addresses are judged by the IPv4 address they embed).
    BLOCKED_NETWORKS = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32
      ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32 fd00:ec2::254/128
    ].map { |net| IPAddr.new(net) }.freeze
    NAT64 = IPAddr.new("64:ff9b::/96")

    module_function

    # The question types the API takes, the older name of truth included,
    # which a raw question may still use.
    TRUTH_OLD_TYPE = "noul"
    QUESTION_TYPES = ["truth", TRUTH_OLD_TYPE, "choice", "score", "number", "point", "box"].freeze

    # ---- requests

    # Checks a request body (String keys) for `/v1/decide` (profile :decide),
    # a session's opening (:session) or a batch line. A point or box question is checked against the ids of the body's
    # `images`; a session's images come with its frames, so there they are
    # the server's to judge.
    def request!(body, profile: :decide, limits: {}, entries: [], counts: [])
      nesting!(body)
      entries = entries.dup
      deferred = []
      state = body["state"]
      entries.concat(sdl_entries(%w[body state], state)) unless state.nil? || sdl?(state)
      image_ids = profile == :session ? nil : Array(body["images"]).map { |img| img.is_a?(Hash) ? img["id"] || img[:id] : nil }
      (body["questions"] || {}).each { |id, q| question(id, q, entries, deferred, limits, image_ids) }
      entries.concat(counts)
      raise invalid(entries) unless entries.empty?
      raise deferred.first unless deferred.empty?

      nil
    end

    # Checks a question map alone.
    def questions!(questions, profile: :decide, limits: {})
      request!({ "questions" => questions }, profile: profile, limits: limits)
    end

    # How many objects and arrays sit inside each other, the outermost included.
    def nesting_depth(value)
      deepest = 0
      stack = [[value, 1]]
      until stack.empty?
        node, depth = stack.pop
        children = case node
                   when Hash then node.values
                   when Array then node
                   else next
                   end
        deepest = depth if depth > deepest
        children.each { |child| stack << [child, depth + 1] if child.is_a?(Hash) || child.is_a?(Array) }
      end
      deepest
    end

    def nesting!(body)
      depth = nesting_depth(body)
      return if depth <= MAX_NESTING

      raise BadRequestError.new("Invalid request.", error_type: "api_usage_error",
                                                    reason: "the request nests #{depth} objects and arrays inside each other; " \
                                                            "the limit is #{MAX_NESTING}")
    end

    # The encoded body, exactly as it would be sent, against the API's body
    # limit: RequestTooLargeError when it is over.
    def body_size!(data)
      size = data.bytesize
      return if size <= MAX_BODY_BYTES

      raise RequestTooLargeError.new(BODY_TOO_LARGE, error_type: "request_too_large_error",
                                                     reason: "the body is #{size} bytes; the limit is #{MAX_BODY_BYTES}")
    end

    # ---- images

    # The 422 entries of a request with more images or videos than the API
    # takes, images first: `too_long` on the list, whose `input` is the list
    # in its wire form (a local image without its bytes). They join the
    # request's other 422 entries, after the state's and the questions'.
    def count_entries(images, videos, limits: {})
      out = []
      most = held(limits, "max_images") || MAX_IMAGES
      out << too_long("images", images.map { |img| image_listed(img) }, most) if images.size > most
      out << too_long("videos", videos.map { |v| v.is_a?(Video) ? v.to_h : v }, MAX_VIDEOS) if videos.size > MAX_VIDEOS
      out
    end

    def too_long(name, input, most)
      entry("too_long", ["body", name], "List should have at most #{most} items after validation, not #{input.size}", input,
            { "field_type" => "List", "max_length" => most, "actual_length" => input.size })
    end

    # An image as a count entry lists it: a local image by its id and media
    # type, its bytes left out.
    def image_listed(img)
      return img unless img.is_a?(Image)

      img.local? ? { "id" => img.id, "media_type" => img.media_type } : img.to_h
    end

    # Checks a request's images, once their count is known to be within the
    # limit: ids, URLs, upload references and each local image's bytes.
    # id_length is the 64-character id rule, for a body that carries the ids;
    # a session frame's image is sent without its id, so a frame skips it.
    def images!(images, limits: {}, id_length: true)
      return nil if images.nil? || images.empty?

      biggest = held(limits, "max_image_bytes") || Image::MAX_BYTES
      seen = {}
      images.each_with_index do |img, i|
        id = img.is_a?(Image) ? img.id : (img["id"] || img[:id])
        usage("Image #{i} needs an id.") unless id.is_a?(String) && !id.empty?
        if id_length && code_points(id) > MAX_IMAGE_ID_CHARS
          usage("Image #{i}: its id is longer than #{MAX_IMAGE_ID_CHARS} characters.")
        end
        usage("Duplicate image id: #{id}") if seen.key?(id)

        seen[id] = true
        image!(img, biggest) if img.is_a?(Image)
      end
      nil
    end

    # A string's length in code points, whatever its encoding says; bytes
    # without an encoding are read as UTF-8.
    def code_points(text)
      text = text.dup.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY
      text.length
    end

    def image!(img, biggest)
      if img.url
        image_url!(img.id, img.url)
      elsif img.upload_id
        return if img.media_type.nil? || MEDIA_TYPES.include?(img.media_type)

        usage("Image #{img.id}: media_type must be image/jpeg, image/png or image/webp.")
      else
        img.validate!(max_bytes: biggest)
      end
    end

    # The URL rules that need no network: https, then at most 2,048
    # characters, no user information, port 443, a host, and no literal
    # address in a blocked range. A DNS name is the server's to resolve.
    def image_url!(id, url)
      usage("Image #{id}: only https URLs are accepted.") unless url.is_a?(String) && url.start_with?("https://")

      reason = url_refusal(url)
      return if reason.nil?

      raise BadRequestError.new("Image '#{id}': #{reason}.", error_type: "image_url_refused")
    end

    def url_refusal(url)
      return "the URL is #{url.length} characters, over the limit of #{Image::MAX_URL_CHARS}" if url.length > Image::MAX_URL_CHARS

      authority = url.delete_prefix("https://")[%r{\A[^/?#]*}]
      return "the URL carries user information" if authority.include?("@")

      host, port = split_authority(authority)
      return "the URL uses a port other than 443" unless port.nil? || port == "443"
      return "the URL has no host" if host.empty?
      return "the URL resolves to a private address" if blocked_address?(host)

      nil
    end

    # Host and port of a URL authority; the port is nil when none is written.
    def split_authority(authority)
      if authority.start_with?("[")
        close = authority.index("]")
        return [authority, "-1"] if close.nil?

        rest = authority[(close + 1)..]
        port = if rest.empty? then nil
               elsif rest.start_with?(":") then rest[1..]
               else "-1"
               end
        return [authority[1...close], port]
      end
      host, sep, port = authority.partition(":")
      [host, sep.empty? ? nil : port]
    end

    def blocked_address?(host)
      addr = IPAddr.new(host)
      if addr.ipv6?
        addr = addr.native if addr.ipv4_mapped?
        addr = IPAddr.new(addr.to_i & 0xFFFFFFFF, Socket::AF_INET) if addr.ipv6? && NAT64.include?(addr)
      end
      BLOCKED_NETWORKS.any? { |net| net.family == addr.family && net.include?(addr) }
    rescue IPAddr::Error, ArgumentError
      false # a DNS name: resolved and judged by the server
    end

    # An image limit the client holds from /v1/models: on the model's entry,
    # or inside its `images` object.
    def held(limits, name)
      value = limits[name]
      value = limits["images"][name] if value.nil? && limits["images"].is_a?(Hash)
      value.is_a?(Integer) && value.positive? ? value : nil
    end

    # ---- videos

    # Checks a request's videos in the API's order, after its images, once
    # their count is known to be within the limit: each video's id (unique
    # across images and videos), its
    # frames (each time a number of at least 0, larger than the one before,
    # and a JPEG, PNG or WebP media type), `fps`, `start` and `end`. The
    # frame counts, a frame's bytes and the window holding a frame are the
    # server's to judge.
    def videos!(videos, image_ids: [])
      return nil if videos.nil? || videos.empty?

      seen = image_ids.to_h { |id| [id, true] }
      videos.each_with_index do |video, i|
        id = video_field(video, "id")
        usage("Video #{i} needs an id.") unless id.is_a?(String) && !id.empty?
        usage("Video id #{py_repr(id)} is used twice (ids are unique across images and videos).") if seen.key?(id)

        seen[id] = true
        video!(id, video)
      end
      nil
    end

    def video!(id, video)
      frames = video_field(video, "frames")
      video_usage(id, "frames must be a non-empty list of frames") unless frames.is_a?(Array) && !frames.empty?
      before = nil
      frames.each_with_index do |frame, n|
        video_usage(id, "frame #{n} must be an object with t, media_type and data") unless frame.is_a?(VideoFrame) || frame.is_a?(Hash)
        t = video_field(frame, "t")
        video_usage(id, "frame #{n}: t must be a number of seconds, at least 0") unless seconds?(t) && t >= 0
        video_usage(id, "frame #{n}: t must be larger than the frame before it (#{g(before)})") if before && t <= before
        before = t
        video_usage(id, "frame #{n}: data must be base64 text") unless frame.is_a?(VideoFrame) || video_field(frame, "data").is_a?(String)
        unless MEDIA_TYPES.include?(video_field(frame, "media_type"))
          video_usage(id, "frame #{n}: media_type must be one of #{MEDIA_TYPES.join(', ')}")
        end
      end
      fps = video_field(video, "fps")
      video_usage(id, "fps must be a number above 0 and at most #{g(MAX_FPS)}") unless fps.nil? || (seconds?(fps) && fps.positive? && fps <= MAX_FPS)
      %w[start end].each do |name|
        value = video_field(video, name)
        video_usage(id, "#{name} must be a number of seconds, at least 0") unless value.nil? || (seconds?(value) && value >= 0)
      end
      last = video_field(video, "end")
      video_usage(id, "end must be after start") if !last.nil? && last <= (video_field(video, "start") || 0)
    end

    # A field of a Video or VideoFrame, or of its wire-form Hash (String or Symbol keys).
    def video_field(item, name)
      case item
      when Video, VideoFrame then item.public_send(name)
      when Hash then item.key?(name) ? item[name] : item[name.to_sym]
      end
    end

    # A finite JSON number, never a boolean.
    def seconds?(value)
      (value.is_a?(Integer) || value.is_a?(Float)) && value.finite?
    end

    # A number as the API writes it in a message (printf's %g): 1.5, 4, 1e+06.
    def g(value)
      format("%g", value)
    end

    # A string quoted as the API quotes an id in a message: 'dock', or
    # "it's" when the id holds a single quote and no double quote.
    def py_repr(text)
      quote = text.include?("'") && !text.include?('"') ? '"' : "'"
      body = text.gsub("\\") { "\\\\" }.gsub(quote) { "\\#{quote}" }
      body = body.gsub(/[\x00-\x1f\x7f]/) { |c| REPR_ESCAPES.fetch(c) { format("\\x%02x", c.ord) } }
      "#{quote}#{body}#{quote}"
    end

    REPR_ESCAPES = { "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze

    def video_usage(id, problem)
      usage("Video #{py_repr(id)}: #{problem}.")
    end

    # ---- sessions

    # `POST /v1/sessions`: window 1 to 64 and ttl_seconds 1 to 3,600 (a held
    # sessions.max_window or max_ttl_seconds replaces the bound), the types of
    # instructions and state, every question rule, and a model the client
    # knows serves no sessions.
    def session_open!(body, limits: {})
      nesting!(body)
      sessions = limits["sessions"].is_a?(Hash) ? limits["sessions"] : {}
      entries = []
      %w[instructions state].each do |name|
        value = body[name]
        entries.concat(sdl_entries(["body", name], value)) unless value.nil? || sdl?(value)
      end
      bounds = { "window" => sessions["max_window"] || MAX_WINDOW, "ttl_seconds" => sessions["max_ttl_seconds"] || MAX_TTL_SECONDS }
      bounds.each do |name, most|
        fault = bounded_int(name, body[name], most)
        entries << fault if fault
      end
      request!({ "questions" => body["questions"] }, profile: :session, limits: limits, entries: entries)
      usage("Model #{limits['model']} does not serve sessions.") if sessions["enabled"] == false
      nil
    end

    def bounded_int(name, value, most)
      return nil if value.nil?
      return entry("int_type", ["body", name], "Input should be a valid integer", value) unless value.is_a?(Integer)
      return entry("greater_than_equal", ["body", name], "Input should be greater than or equal to 1", value, { "ge" => 1 }) if value < 1
      return nil if value <= most

      entry("less_than_equal", ["body", name], "Input should be less than or equal to #{most}", value, { "le" => most })
    end

    # One frame, before it is written: the fault the server's frame error
    # would name, raised as BadRequestError with `api_usage_error`.
    def frame!(frame:, image:, questions:, reset:, seq:, known_questions:, limits: {})
      usage("seq: must be an integer from 0 to #{MAX_SEQ}.") unless seq.nil? || (seq.is_a?(Integer) && seq.between?(0, MAX_SEQ))
      usage("frame: a frame needs a frame value or an image.") if frame.nil? && image.nil?
      usage("frame: must be a string, an object or an array, not empty.") if !frame.nil? && (!sdl?(frame) || frame == "")
      frame_questions!(questions, known_questions) unless questions.nil?
      usage("reset: must be true or false.") unless [nil, true, false].include?(reset)
      if !frame.nil? && nesting_depth(frame) + 1 > MAX_NESTING
        usage("The frame nests more than #{MAX_NESTING} objects and arrays inside each other.")
      end
      return unless image.is_a?(Image)

      usage("image: a frame takes bytes or an upload, not a url.") if image.url
      images!([image], limits: limits, id_length: false)
    end

    def frame_questions!(questions, known)
      list = questions.to_a
      usage("questions: must be a non-empty list of the session's question ids.") if list.empty?
      return unless known.is_a?(Array)

      unknown = list.find { |id| !known.include?(id) }
      return if unknown.nil?

      usage("questions: unknown question id #{unknown.is_a?(String) ? "'#{unknown}'" : JSON.generate(unknown, max_nesting: false)}")
    end

    # ---- batches

    # The custom_id rules of one create or add call (lines numbered from 1),
    # an add with no requests, and the held requests_per_batch and
    # max_custom_id_chars.
    def lines!(requests, allow_empty:, limits: {})
      usage("The call holds no requests.") if requests.empty? && !allow_empty
      batch = limits["batch"].is_a?(Hash) ? limits["batch"] : {}
      most = batch["requests_per_batch"]
      usage("The batch would hold #{requests.size} requests. The limit is #{most}.") if most && requests.size > most
      longest = batch["max_custom_id_chars"]
      seen = {}
      requests.each.with_index(1) do |req, n|
        raise ArgumentError, "batch request #{n} must be a Hash of decide's arguments and a custom_id" unless req.is_a?(Hash)

        id = req.key?("custom_id") ? req["custom_id"] : req[:custom_id]
        custom_id!(id, n, longest)
        if seen.key?(id)
          shown = JSON.generate(id, max_nesting: false)
          usage("Line #{n}: custom_id #{shown.length <= 64 ? shown : "#{shown[0, 64]}..."} is already in the batch.")
        end
        seen[id] = true
      end
      nil
    end

    def custom_id!(id, line, longest)
      usage("Line #{line} has no custom_id.") if id.nil?
      return if id.is_a?(String) && !id.empty? && (longest.nil? || id.length <= longest)

      usage("Line #{line}: custom_id must be a string of 1 to #{longest || CUSTOM_ID_CHARS} characters.")
    end

    # `GET /v1/batches`: offset an integer of 0 or more, limit 1 to 100.
    def list!(offset, limit)
      unless offset.nil? || (offset.is_a?(Integer) && !offset.negative?)
        usage("Query parameter offset must be an integer of 0 or more, got #{offset}.")
      end
      return if limit.nil? || (limit.is_a?(Integer) && limit.between?(1, LIST_LIMIT_MAX))

      usage("Query parameter limit must be an integer from 1 to #{LIST_LIMIT_MAX}, got #{limit}.")
    end

    # ---- questions

    def question(id, q, entries, deferred, limits, image_ids)
      base = ["body", "questions", id]
      unless q.is_a?(Hash)
        entries << entry("model_type", base, "Input should be a valid dictionary or object", q)
        return
      end
      if q["type"].nil?
        entries << entry("missing", base + ["type"], "Field required", q)
        return
      end
      type = q["type"]
      unless QUESTION_TYPES.include?(type)
        deferred << BadRequestError.new("Invalid request.", error_type: "api_usage_error",
                                                            reason: "question '#{id}': unknown type #{JSON.generate(type, max_nesting: false)}")
        return
      end
      loc = base + [type]
      instructions = q["instructions"]
      entries.concat(sdl_entries(loc + ["instructions"], instructions)) unless instructions.nil? || sdl?(instructions)
      case type
      when "number" then number(id, q, loc, entries, deferred, limits)
      when "choice" then choice(id, q, loc, entries, deferred, limits)
      when "score" then score(q, loc, entries, deferred, limits)
      when "point", "box" then place(id, q, loc, entries, deferred, image_ids)
      else truth(id, q, loc, entries, deferred)
      end
    end

    # A point or box question: the image it looks in, its units, and its
    # instructions. `image_ids` are the request's image ids, nil when the
    # images are not known here.
    def place(id, q, loc, entries, deferred, image_ids)
      image = q["image"]
      unless image_ids.nil?
        if image_ids.empty?
          entries << entry("image_required", loc, "A #{q['type']} question needs an image in the request", q)
        elsif image.nil?
          entries << entry("missing", loc + ["image"], "Field required", q) if image_ids.size >= 2
        elsif !image.is_a?(String)
          entries << entry("string_type", loc + ["image"], "Input should be a valid string", image)
        elsif !image_ids.include?(image)
          entries << entry("unknown_image", loc + ["image"], "Input should be the id of an image of the request", image)
        end
      end
      units = q["units"]
      unless units.nil? || UNITS.include?(units)
        entries << entry("literal_error", loc + ["units"], "Input should be 'pixels' or 'normalized'", units,
                         { "expected" => "'pixels' or 'normalized'" })
      end
      instructions = q["instructions"]
      deferred << plain("#{q['type'].capitalize} question must have instructions: #{id}") if instructions.nil? || instructions == ""
    end

    def choice(id, q, loc, entries, deferred, limits)
      criteria = q["criteria"]
      most = limits["max_choice_options"] || MAX_CHOICE_OPTIONS
      if criteria.nil?
        entries << entry("missing", loc + ["criteria"], "Field required", q)
      elsif !criteria.is_a?(Hash)
        entries << entry("dict_type", loc + ["criteria"], "Input should be a valid dictionary", criteria)
      else
        criteria.each do |name, desc|
          entries.concat(sdl_entries(loc + ["criteria", name.to_s], desc)) unless desc.nil? || sdl?(desc)
        end
        if criteria.empty?
          deferred << plain("Choice question must have at least one choice: #{id}")
        elsif criteria.size > most
          deferred << plain("Too many choices. Must have at most #{most} choices.")
        end
      end
    end

    def score(q, loc, entries, deferred, limits)
      criteria = q["criteria"]
      most = limits["max_score_levels"] || MAX_SCORE_LEVELS
      if criteria.nil?
        entries << entry("missing", loc + ["criteria"], "Field required", q)
        return
      end
      levels = score_levels(criteria)
      if levels.nil?
        entries << entry("list_type", loc + ["criteria"], "Input should be a valid list", criteria)
        return
      end
      if levels.empty?
        entries << entry("too_short", loc + ["criteria"], "List should have at least 1 item after validation, not 0", criteria)
        return
      end
      levels.each_with_index { |level, i| entries.concat(sdl_entries(loc + ["criteria", i], level)) unless sdl?(level) }
      deferred << plain("Too many score levels. Must have at most #{most} levels.") if levels.size > most
    end

    # The levels of a score: a list, or an object keyed "0" to "K-1".
    def score_levels(criteria)
      return criteria if criteria.is_a?(Array)
      return nil unless criteria.is_a?(Hash)

      keyed = criteria.transform_keys(&:to_s)
      return nil unless keyed.keys.sort_by { |k| [k.length, k] } == Array.new(keyed.size) { |i| i.to_s }

      Array.new(keyed.size) { |i| keyed[i.to_s] }
    end

    def truth(id, q, loc, entries, deferred)
      criteria = q["criteria"]
      if !criteria.nil? && !criteria.is_a?(Hash)
        entries << entry("dict_type", loc + ["criteria"], "Input should be a valid dictionary", criteria)
        return
      end
      sides = (criteria || {}).transform_keys(&:to_s)
      %w[true false].each do |side|
        value = sides[side]
        entries.concat(sdl_entries(loc + ["criteria", side], value)) unless value.nil? || sdl?(value)
      end
      return unless q["instructions"].nil? && sides["true"].nil? && sides["false"].nil?

      name = q["type"] == TRUTH_OLD_TYPE ? TRUTH_OLD_TYPE.capitalize : "Truth"
      deferred << plain("#{name} question must have criteria or instructions: #{id}")
    end

    # The number grid rules: the 422 entries in the server's order, then the 400.
    def number(id, q, loc, entries, deferred, limits)
      if limits["number_max_grid_values"] == 0
        deferred << BadRequestError.new("Model #{limits['model']} does not answer number questions.", error_type: "api_usage_error")
        return
      end
      values = grid_values(q, loc, entries)
      return if values.nil?

      lo, hi, step = values
      d = [places(lo), places(step)].max
      return if d.positive? && beyond_decimal_bound?(q, loc, entries, lo, hi, d)

      if lo > hi
        max_sent = q["max"].nil? ? 255 : q["max"]
        min_sent = q["min"].nil? ? 0 : q["min"]
        entries << entry("less_than_equal", loc + ["min"], "Input should be less than or equal to #{JSON.generate(max_sent)}",
                         min_sent, { "le" => max_sent })
        return
      end
      most = limits["number_max_grid_values"] || MAX_GRID_VALUES
      scale = 10**d
      size = ((hi * scale).floor - (lo * scale).to_i).div((step * scale).to_i) + 1
      if size > most
        entries << entry("too_long", loc, "Grid should have at most #{most} values, not #{size}", q,
                         { "field_type" => "Grid", "max_length" => most, "actual_length" => size })
        return
      end
      instructions = q["instructions"]
      deferred << plain("Number question must have instructions: #{id}") if instructions.nil? || instructions == ""
    end

    # min, max and step as exact values, or nil after adding their entries.
    def grid_values(q, loc, entries)
      faults = %w[min max step].filter_map { |name| q[name].nil? ? nil : number_fault(name, q[name], loc + [name]) }
      unless faults.empty?
        entries.concat(faults)
        return nil
      end

      %w[min max step].map { |name| q[name].nil? ? Rational(GRID_DEFAULTS[name]) : exact(q[name]) }
    end

    def beyond_decimal_bound?(q, loc, entries, lo, hi, places)
      bound = Rational(10**(15 - places)) - Rational(1, 10**places)
      text = decimal_text(bound)
      { "min" => lo, "max" => hi }.each do |name, value|
        if value > bound
          entries << entry("less_than_equal", loc + [name], "Input should be less than or equal to #{text}", q[name],
                           { "le" => json_number(bound) })
          return true
        elsif value < -bound
          entries << entry("greater_than_equal", loc + [name], "Input should be greater than or equal to -#{text}", q[name],
                           { "ge" => json_number(-bound) })
          return true
        end
      end
      false
    end

    def number_fault(name, sent, field)
      return entry("float_type", field, "Input should be a valid number", sent) unless sent.is_a?(Integer) || sent.is_a?(Float)
      return entry("finite_number", field, "Input should be a finite number", sent) if sent.is_a?(Float) && !sent.finite?

      value = exact(sent)
      bounded = %w[min max].include?(name)
      if bounded && value < -TWO_53
        return entry("greater_than_equal", field, "Input should be greater than or equal to -#{TWO_53}", sent, { "ge" => -TWO_53 })
      end
      return entry("less_than_equal", field, "Input should be less than or equal to #{TWO_53}", sent, { "le" => TWO_53 }) if bounded && value > TWO_53
      return entry("greater_than", field, "Input should be greater than 0", sent, { "gt" => 0 }) if name == "step" && value <= 0
      return nil unless %w[min step].include?(name) && places(value) > MAX_NUMBER_DECIMALS

      entry("decimal_max_places", field, "Decimal input should have no more than #{MAX_NUMBER_DECIMALS} decimal places",
            sent, { "decimal_places" => MAX_NUMBER_DECIMALS })
    end

    # The exact value of a JSON number as written (a Float by its shortest form).
    def exact(value)
      value.is_a?(Float) ? Rational(value.to_s) : Rational(value)
    end

    # Decimal places of an exact value, trailing zeros dropped.
    def places(value)
      d = 0
      d += 1 until (value * (10**d)).denominator == 1 || d > 40
      d
    end

    def decimal_text(value)
      d = places(value)
      return value.to_i.to_s if d.zero?

      sign = value.negative? ? "-" : ""
      digits = (value.abs * (10**d)).to_i.to_s.rjust(d + 1, "0")
      "#{sign}#{digits[0...-d]}.#{digits[-d..]}"
    end

    def json_number(value)
      text = decimal_text(value)
      text.include?(".") ? Float(text) : Integer(text)
    end

    # ---- helpers

    def sdl?(value)
      value.is_a?(String) || value.is_a?(Hash) || value.is_a?(Array)
    end

    # A value that may be a string, an object or an array: three entries.
    def sdl_entries(loc, value)
      [
        entry("string_type", loc + ["str"], "Input should be a valid string", value),
        entry("dict_type", loc + ["dict[any,any]"], "Input should be a valid dictionary", value),
        entry("list_type", loc + ["list[any]"], "Input should be a valid list", value)
      ]
    end

    def entry(type, loc, msg, input, ctx = nil)
      e = { "type" => type, "loc" => loc, "msg" => msg, "input" => input }
      e["ctx"] = ctx unless ctx.nil?
      e
    end

    def invalid(entries)
      ValidationError.new("", entries: entries)
    end

    # The API's plain-string 400: no error_type.
    def plain(message)
      BadRequestError.new(message)
    end

    def usage(message)
      raise BadRequestError.new(message, error_type: "api_usage_error")
    end
  end
end
