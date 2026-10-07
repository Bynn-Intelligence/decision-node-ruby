# frozen_string_literal: true

class DecisionNode
  # An image sent with a decision, from a file, from bytes or from an https URL.
  #
  #   DecisionNode::Image.new("receipt", path: "receipt.png")
  #   DecisionNode::Image.new("photo", data: bytes, media_type: "image/jpeg")
  #   DecisionNode::Image.new("scan", url: "https://example.com/scan.webp")
  #
  # A file is read here, when the Image is made, and base64-encoded; its media
  # type is taken from its first bytes (JPEG, PNG or WebP), as it is for bytes
  # given without media_type:. An unreadable file or an unrecognised format
  # raises ArgumentError. Size and count limits are checked by the server.
  class Image
    attr_reader :id, :data, :media_type, :url

    def self.sniff_media_type(bytes)
      bytes = bytes.b
      return "image/jpeg" if bytes.start_with?("\xFF\xD8\xFF".b)
      return "image/png" if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      return "image/webp" if bytes.start_with?("RIFF".b) && bytes.byteslice(8, 4) == "WEBP".b

      nil
    end

    def initialize(id, path: nil, data: nil, media_type: nil, url: nil)
      sources = [path, data, url].compact.size
      raise ArgumentError, "give exactly one of path:, data: or url:" unless sources == 1

      @id = id.to_s
      @url = url
      if path
        begin
          data = File.binread(path)
        rescue SystemCallError, IOError => e
          raise ArgumentError, "image #{@id.inspect}: cannot read #{path}: #{e.message}"
        end
        media_type = nil
      end
      return if url

      raise ArgumentError, "image #{@id.inspect}: data must be a String of bytes" unless data.is_a?(String)

      @data = data.b
      @media_type = media_type.nil? || media_type.to_s.empty? ? self.class.sniff_media_type(@data) : media_type.to_s
      return if @media_type

      raise ArgumentError, "image #{@id.inspect} is not a JPEG, PNG or WebP image; pass media_type:"
    end

    # The image's wire form.
    def to_h
      return { "id" => id, "url" => url } if url

      { "id" => id, "media_type" => media_type, "data" => [data].pack("m0") }
    end
  end
end
