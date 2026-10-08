# frozen_string_literal: true

class DecisionNode
  # Reads an image's format and pixel size from its first bytes, without
  # decoding it: the JPEG start-of-frame segment, the PNG IHDR chunk and the
  # WebP VP8, VP8L or VP8X header.
  #
  #   DecisionNode::ImageHeader.media_type(bytes)            # => "image/png"
  #   DecisionNode::ImageHeader.dimensions(bytes, "image/png") # => [640, 480]
  module ImageHeader
    module_function

    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
    JPEG_SIGNATURE = "\xFF\xD8\xFF".b.freeze
    RIFF = "RIFF".b.freeze
    WEBP = "WEBP".b.freeze
    IHDR = "IHDR".b.freeze
    VP8_START_CODE = "\x9D\x01\x2A".b.freeze

    # JPEG start-of-frame markers that carry the frame size: SOF0 to SOF15
    # except DHT (C4), JPG (C8) and DAC (CC).
    JPEG_SOF = ([0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]).freeze
    # Markers that stand alone, with no length: TEM, RST0 to RST7, SOI.
    JPEG_STANDALONE = ([0x01, 0xD8] + (0xD0..0xD7).to_a).freeze
    JPEG_SOS = 0xDA
    JPEG_EOI = 0xD9

    # "image/jpeg", "image/png" or "image/webp" from the magic bytes, else nil.
    def media_type(bytes)
      return "image/jpeg" if bytes.start_with?(JPEG_SIGNATURE)
      return "image/png" if bytes.start_with?(PNG_SIGNATURE)
      return "image/webp" if bytes.start_with?(RIFF) && bytes.byteslice(8, 4) == WEBP

      nil
    end

    # [width, height] in pixels read from the header, or nil when the header
    # is missing, truncated or not of this type.
    def dimensions(bytes, media_type)
      case media_type
      when "image/png" then png(bytes)
      when "image/jpeg" then jpeg(bytes)
      when "image/webp" then webp(bytes)
      end
    end

    # The IHDR chunk is the first chunk: length (4), "IHDR", width (4), height (4).
    def png(bytes)
      return nil unless bytes.byteslice(12, 4) == IHDR

      size = bytes.byteslice(16, 8)
      size&.bytesize == 8 ? size.unpack("NN") : nil
    end

    # Walks the segments after SOI to the first start-of-frame segment:
    # FF marker, length (2, counting itself), precision (1), height (2), width (2).
    def jpeg(bytes)
      i = 2
      size = bytes.bytesize
      while i + 1 < size
        return nil unless bytes.getbyte(i) == 0xFF

        marker = bytes.getbyte(i + 1)
        if marker == 0xFF # fill byte before a marker
          i += 1
          next
        end
        if JPEG_STANDALONE.include?(marker)
          i += 2
          next
        end
        return nil if marker == JPEG_SOS || marker == JPEG_EOI || i + 4 > size

        length = bytes.byteslice(i + 2, 2).unpack1("n")
        return nil if length < 2

        if JPEG_SOF.include?(marker)
          frame = bytes.byteslice(i + 5, 4)
          return nil unless frame&.bytesize == 4

          height, width = frame.unpack("nn")
          return [width, height]
        end
        i += 2 + length
      end
      nil
    end

    # RIFF (4), size (4), "WEBP", then the first chunk's fourcc at 12.
    def webp(bytes)
      case bytes.byteslice(12, 4)
      when "VP8 ".b
        # Frame tag (3) at 20, start code (3) at 23, then 14-bit width and height.
        return nil unless bytes.byteslice(23, 3) == VP8_START_CODE

        size = bytes.byteslice(26, 4)
        return nil unless size&.bytesize == 4

        width, height = size.unpack("vv")
        [width & 0x3FFF, height & 0x3FFF]
      when "VP8L".b
        # Signature 0x2F at 20, then width - 1 and height - 1 in 14 bits each.
        return nil unless bytes.getbyte(20) == 0x2F

        bits = bytes.byteslice(21, 4)
        return nil unless bits&.bytesize == 4

        value = bits.unpack1("V")
        [(value & 0x3FFF) + 1, ((value >> 14) & 0x3FFF) + 1]
      when "VP8X".b
        # Flags (4) at 20, then canvas width - 1 and height - 1 in 24 bits each.
        canvas = bytes.byteslice(24, 6)
        return nil unless canvas&.bytesize == 6

        w = canvas.getbyte(0) | (canvas.getbyte(1) << 8) | (canvas.getbyte(2) << 16)
        h = canvas.getbyte(3) | (canvas.getbyte(4) << 8) | (canvas.getbyte(5) << 16)
        [w + 1, h + 1]
      end
    end
  end
end
