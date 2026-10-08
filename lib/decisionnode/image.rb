# frozen_string_literal: true

require "digest"

class DecisionNode
  # Local images whose bytes total less than this go inline as base64 `data`;
  # at or above it they are uploaded once and sent by `upload_id`. Counted over
  # all the local images of one request, one session frame or one batch line.
  # The client's `inline_threshold:` option overrides it.
  DEFAULT_INLINE_THRESHOLD = 524_288

  # An image sent with a decision.
  #
  #   DecisionNode::Image.new("scan", url: "https://example.com/scan.webp")   # recommended
  #   DecisionNode::Image.new("receipt", path: "receipt.png")
  #   DecisionNode::Image.new("photo", data: jpeg_bytes)
  #   DecisionNode::Image.new("photo", data: File.open("photo.jpg", "rb"))
  #   DecisionNode::Image.new("photo", base64: "/9j/4AAQ...")
  #   DecisionNode::Image.new("receipt", upload_id: "upl_...")
  #
  # A URL is sent as it is and fetched by the API, so nothing is uploaded: the
  # fastest form. A file, an IO, bytes or base64 text are read here, when the
  # Image is made; `data:` also takes base64 text and decodes it when the text
  # is not already image bytes. The bytes are checked locally before any
  # request (format from the magic bytes, at most 10,485,760 bytes, at most
  # 40,000,000 pixels read from the header), then sent inline or uploaded by
  # the client's inline threshold. An image is never resized or re-encoded.
  #
  # An unreadable file or an argument of the wrong type raises ArgumentError
  # here; a fault in the image itself raises BadRequestError when it is sent,
  # before any request.
  class Image
    # The API's limits on one image, checked before any request.
    MAX_BYTES = 10_485_760
    MAX_PIXELS = 40_000_000
    MAX_URL_CHARS = 2_048
    MEDIA_TYPES = %w[image/jpeg image/png image/webp].freeze

    attr_reader :id, :url, :upload_id

    # The image's bytes (a frozen binary String), or nil for a URL or an upload id.
    attr_reader :data

    # "image/jpeg", "image/png" or "image/webp" from the magic bytes, or the
    # media type given when the bytes are none of these.
    def self.sniff_media_type(bytes)
      ImageHeader.media_type(bytes.b)
    end

    def initialize(id, url: nil, path: nil, data: nil, base64: nil, upload_id: nil, media_type: nil)
      sources = [url, path, data, base64, upload_id].compact.size
      raise ArgumentError, "give exactly one of url:, path:, data:, base64: or upload_id:" unless sources == 1

      @id = id.to_s
      @declared = media_type.nil? || media_type.to_s.empty? ? nil : media_type.to_s
      @url = url
      @upload_id = upload_id&.to_s
      @data = read_bytes(path, data, base64)&.freeze
      @media_type = @data ? self.class.sniff_media_type(@data) || @declared : @declared
      @data_type = @data ? self.class.sniff_media_type(@data) : nil
      @lock = Mutex.new
    end

    # The image's media type: detected from the bytes, else as given.
    attr_reader :media_type

    def local?
      !@data.nil?
    end

    def bytesize
      @data ? @data.bytesize : 0
    end

    # [width, height] read from the header, or nil.
    def dimensions
      return nil unless @data && @data_type

      @lock.synchronize do
        @dimensions = ImageHeader.dimensions(@data, @data_type) unless defined?(@dimensions)
        @dimensions
      end
    end

    # The SHA-256 of the bytes, raw.
    def sha256
      @sha256 ||= Digest::SHA256.digest(@data)
    end

    # The MD5 of the bytes, raw.
    def md5
      @md5 ||= Digest::MD5.digest(@data)
    end

    # Raises BadRequestError (`api_usage_error`), as the API would answer,
    # when the image's bytes break one of the API's rules: the format from the
    # magic bytes (and a declared media type that differs), the size, and the
    # pixel count read from the header. Returns self otherwise. A URL or an
    # upload id is checked with the request (Checks.images!).
    def validate!(max_bytes: MAX_BYTES)
      fault = find_fault(max_bytes)
      raise BadRequestError.new(fault, error_type: "api_usage_error") if fault

      self
    end

    # The image's wire form with its bytes inline, or its URL or upload id.
    def to_h
      return url_wire if @url
      return upload_wire(@upload_id) if @upload_id

      { "id" => id, "media_type" => media_type, "data" => [@data].pack("m0") }
    end

    # The wire form naming an upload of these bytes.
    def upload_wire(upload_id)
      wire = { "id" => id, "upload_id" => upload_id }
      wire["media_type"] = media_type if @upload_id && media_type
      wire
    end

    def inspect
      source = if @url then "url=#{@url.inspect}"
               elsif @upload_id then "upload_id=#{@upload_id.inspect}"
               else "#{media_type} #{bytesize} bytes"
               end
      "#<#{self.class.name} #{id.inspect} #{source}>"
    end

    private

    def url_wire
      wire = { "id" => id, "url" => @url }
      wire["media_type"] = @declared if @declared
      wire
    end

    def read_bytes(path, data, base64)
      if path
        begin
          File.binread(path.to_s)
        rescue SystemCallError, IOError => e
          raise ArgumentError, "image #{@id.inspect}: cannot read #{path}: #{e.message}"
        end
      elsif base64
        decode_base64(base64.to_s) || raise(ArgumentError, "image #{@id.inspect}: base64: is not base64 text")
      elsif data.respond_to?(:read)
        data.read.to_s.b
      elsif data
        raise ArgumentError, "image #{@id.inspect}: data must be a String of bytes or base64 text, or an IO" unless data.is_a?(String)

        bytes = data.b
        if ImageHeader.media_type(bytes).nil? && (decoded = decode_base64(bytes))
          ImageHeader.media_type(decoded) ? decoded : bytes
        else
          bytes
        end
      end
    end

    # The decoded bytes of base64 text (line breaks allowed), or nil.
    def decode_base64(text)
      text.delete("\r\n").unpack1("m0").b
    rescue ArgumentError
      nil
    end

    # The first rule the bytes break, or nil. The pixel size is read once.
    def find_fault(max_bytes)
      return nil unless @data

      found = @data_type
      return "Image #{@id} is not a JPEG, PNG or WebP image." if found.nil?
      return "Image #{@id} could not be decoded as #{@declared}." if @declared && @declared != found
      return "Image #{@id} is larger than #{max_bytes / 1_048_576} MB." if @data.bytesize > max_bytes

      size = @lock.synchronize do
        @dimensions = ImageHeader.dimensions(@data, found) unless defined?(@dimensions)
        @dimensions
      end
      return "Image #{@id}: its header cannot be read." if size.nil?

      width, height = size
      return "Image #{@id} is #{width}x#{height} pixels, over 40 megapixels." if width * height > MAX_PIXELS

      nil
    end
  end
end
