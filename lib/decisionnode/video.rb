# frozen_string_literal: true

class DecisionNode
  # One frame of a video: its time in seconds and its image.
  #
  #   DecisionNode::Frame.new(30.0, data: jpeg_bytes)                       # media type from the bytes
  #   DecisionNode::Frame.new(30.5, path: "frames/0001.jpg")
  #   DecisionNode::Frame.new(31.0, base64: "/9j/4AAQ...", media_type: "image/jpeg")
  #
  # Bytes are sent as base64; base64 text is sent exactly as given and needs
  # its `media_type`. A frame is always sent inline: it is never uploaded and
  # never counted toward the inline threshold of images. It is never resized
  # or re-encoded.
  #
  # The values are checked with the request, before anything is sent: a time
  # below 0, times that do not increase, or a media type other than
  # image/jpeg, image/png or image/webp raise BadRequestError as the API
  # would. A time that is not a number, or a source of the wrong type, raises
  # ArgumentError here.
  class Frame
    # The frame's time in seconds.
    attr_reader :t
    # "image/jpeg", "image/png" or "image/webp": as given, else detected from
    # the bytes; nil when neither says.
    attr_reader :media_type
    # The bytes (a frozen binary String), or nil for base64 text.
    attr_reader :data

    def initialize(t, data: nil, base64: nil, path: nil, media_type: nil)
      raise ArgumentError, "frame time t must be a number of seconds, got #{t.inspect}" unless t.is_a?(Integer) || t.is_a?(Float)
      raise ArgumentError, "give exactly one of data:, base64: or path:" unless [data, base64, path].compact.size == 1

      @t = t
      @base64 = base64.nil? ? nil : text(base64)
      @data = (@base64 ? nil : read_bytes(data, path)).freeze
      declared = media_type.nil? || media_type.to_s.empty? ? nil : media_type.to_s
      @media_type = declared || (@data && ImageHeader.media_type(@data))
    end

    # The frame's wire form: `{"t", "media_type", "data"}`.
    def to_h
      { "t" => t, "media_type" => media_type, "data" => @base64 || [@data].pack("m0") }
    end

    def inspect
      size = @base64 ? "#{@base64.bytesize} base64 characters" : "#{@data.bytesize} bytes"
      "#<#{self.class.name} t=#{t} #{media_type || 'unknown type'} #{size}>"
    end

    private

    def text(value)
      raise ArgumentError, "frame base64: must be a String of base64 text" unless value.is_a?(String)

      value
    end

    def read_bytes(data, path)
      if path
        begin
          File.binread(path.to_s)
        rescue SystemCallError, IOError => e
          raise ArgumentError, "frame at #{t}: cannot read #{path}: #{e.message}"
        end
      elsif data.respond_to?(:read)
        data.read.to_s.b
      elsif data.is_a?(String)
        data.b
      else
        raise ArgumentError, "frame data: must be a String of bytes or an IO"
      end
    end
  end

  # A video sent as the frames the caller sampled, each with its time.
  #
  #   frames = jpegs.each_with_index.map { |bytes, i| DecisionNode::Frame.new(i * 0.5, data: bytes) }
  #   DecisionNode::Video.new("dock", frames: frames)
  #   DecisionNode::Video.new("dock", frames: frames, fps: 4, start: 30, end: 90)
  #
  # `fps` caps the rate the API reads (above 0, at most 4; the API's default
  # is 2); `start` and `end` are the window read, on the frames' own times.
  # Each is sent only when given. The API takes videos when it enables them;
  # only these frames are sent, never a video file, a URL or sound.
  class Video
    attr_reader :id, :frames, :fps, :start, :end

    def initialize(id, frames:, fps: nil, start: nil, end: nil)
      last = binding.local_variable_get(:end)
      raise ArgumentError, "frames: must be an Array of DecisionNode::Frame" unless frames.is_a?(Array)

      frames.each do |frame|
        next if frame.is_a?(Frame) || frame.is_a?(Hash)

        raise ArgumentError, "each frame must be a DecisionNode::Frame or a wire-form Hash, got #{frame.class}"
      end
      { "fps" => fps, "start" => start, "end" => last }.each do |name, value|
        next if value.nil? || value.is_a?(Integer) || value.is_a?(Float)

        raise ArgumentError, "#{name} must be a number, got #{value.inspect}"
      end
      @id = id.is_a?(Symbol) ? id.to_s : id
      @frames = frames.dup.freeze
      @fps = fps
      @start = start
      @end = last
    end

    # The video's wire form, `fps`, `start` and `end` only when given.
    def to_h
      wire = { "id" => id }
      wire["fps"] = fps unless fps.nil?
      wire["start"] = start unless start.nil?
      wire["end"] = self.end unless self.end.nil?
      wire["frames"] = frames.map { |f| f.is_a?(Frame) ? f.to_h : f }
      wire
    end

    def inspect
      "#<#{self.class.name} #{id.inspect} #{frames.size} frames>"
    end
  end
end
