# frozen_string_literal: true

require "digest"

class DecisionNode
  # A document for a knowledge base (a collection of type "text"): the
  # content of one item.
  #
  #   DecisionNode::Document.new(text: "# Receipts\n\nReject any claim ...")      # Markdown inline
  #   DecisionNode::Document.new(text: "Plain words.", format: "text")
  #   DecisionNode::Document.new(path: "claims-policy-2026.pdf")
  #   DecisionNode::Document.new(data: docx_bytes, filename: "rules.docx")
  #   DecisionNode::Document.new(io: $stdin, content_type: "text/markdown")
  #   DecisionNode::Document.new(upload_id: "upl_...")                           # from #upload_documents
  #
  # A text is sent inline, whatever its size. A file (a path, bytes or an IO)
  # is read when the call is made: a text or Markdown file whose bytes total
  # under the client's inline threshold and are UTF-8 without a NUL is sent
  # inline as its text; every other file is uploaded first and named by its
  # upload id. An IO is read to its end once, into memory, before anything is
  # sent.
  #
  # content_type:: one of CONTENT_TYPES. Left out, it comes from the file
  #                name's extension, else from the first bytes (PDF, PNG, JPEG,
  #                TIFF, WebP). DOCX, PPTX, XLSX and text cannot be told from
  #                their bytes: they need content_type or a file name.
  # filename::     a path's base name unless given; optional for bytes and IOs.
  #                Its stem is the item's title when none is given.
  class Document
    # The types a knowledge file may have, in the API's order.
    CONTENT_TYPES = %w[
      text/plain text/markdown application/pdf
      application/vnd.openxmlformats-officedocument.wordprocessingml.document
      application/vnd.openxmlformats-officedocument.presentationml.presentation
      application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
      text/html image/png image/jpeg image/tiff image/webp
    ].freeze

    # The most bytes a knowledge file may have (50 MB).
    MAX_BYTES = 52_428_800

    FORMATS = %w[markdown text].freeze

    EXTENSIONS = {
      ".txt" => "text/plain", ".md" => "text/markdown", ".markdown" => "text/markdown",
      ".pdf" => "application/pdf",
      ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      ".html" => "text/html", ".htm" => "text/html", ".png" => "image/png", ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg", ".tif" => "image/tiff", ".tiff" => "image/tiff", ".webp" => "image/webp"
    }.freeze
    private_constant :EXTENSIONS

    # What a call sends for a document, once its bytes are read: `kind` :text
    # (inline), :file (to upload) or :upload (an upload id given).
    Loaded = Struct.new(:kind, :text, :format, :data, :content_type, :filename, :upload_id) do
      def md5
        Digest::MD5.digest(data)
      end

      def sha256
        Digest::SHA256.digest(data)
      end
    end

    attr_reader :text, :format, :path, :data, :io, :content_type, :filename, :upload_id

    def initialize(text: nil, format: nil, path: nil, data: nil, io: nil, upload_id: nil, content_type: nil,
                   filename: nil)
      sources = [text, path, data, io, upload_id].compact.size
      raise ArgumentError, "give exactly one of text:, path:, data:, io: or upload_id:" unless sources == 1
      raise ArgumentError, "text: must be a String" unless text.nil? || text.is_a?(String)
      raise ArgumentError, "data: must be a String of bytes" unless data.nil? || data.is_a?(String)
      raise ArgumentError, "io: must respond to read" unless io.nil? || io.respond_to?(:read)
      raise ArgumentError, "format: goes with text:; a file's format comes from its type" unless format.nil? || !text.nil?
      if text || upload_id
        raise ArgumentError, "content_type: and filename: go with a file" unless content_type.nil? && filename.nil?
      end

      @text = text
      @format = format.is_a?(Symbol) ? format.to_s : format
      @path = path&.to_s
      @data = data
      @io = io
      @upload_id = upload_id&.to_s
      @content_type = content_type.nil? || content_type.to_s.empty? ? nil : content_type.to_s
      @filename = filename.nil? ? @path && File.basename(@path) : filename.to_s
    end

    def inspect
      what = if @text then "text"
             elsif @upload_id then "upload_id=#{@upload_id}"
             else "file#{@filename ? " #{@filename.inspect}" : ''}"
             end
      "#<#{self.class.name} #{what}>"
    end

    # True for a text given in memory.
    def text?
      !@text.nil?
    end

    # True for a file (a path, bytes or an IO).
    def file?
      @text.nil? && @upload_id.nil?
    end

    # The file's bytes and type, read now, checked as the presign checks them
    # (`index` is the file's place in it). A text and an upload id come back
    # as they are.
    def load(index = 0)
      return Loaded.new(:text, @text, @format) if @text
      return Loaded.new(:upload, nil, nil, nil, nil, nil, @upload_id) if @upload_id

      bytes = read_bytes
      type = @content_type || self.class.type_of(@filename, bytes)
      if type.nil?
        raise ArgumentError, "the document's type cannot be told from its name or its first bytes: give content_type: or filename:"
      end
      unless CONTENT_TYPES.include?(type)
        usage("files[#{index}].content_type: must be one of #{CONTENT_TYPES.join(', ')}, got #{type}.")
      end
      usage("files[#{index}].byte_size: must be an integer from 1 to #{MAX_BYTES}.") if bytes.empty?
      if bytes.bytesize > MAX_BYTES
        usage("files[#{index}].byte_size: #{bytes.bytesize} is over the limit of #{MAX_BYTES} bytes.")
      end

      Loaded.new(:file, nil, nil, bytes.b.freeze, type, @filename)
    end

    # The type of a file: from its name's extension, else from its first bytes;
    # nil when neither tells.
    def self.type_of(filename, bytes)
      ext = filename && File.extname(filename).downcase
      return EXTENSIONS[ext] if ext && EXTENSIONS.key?(ext)

      head = bytes.byteslice(0, 12).b
      if head.start_with?("%PDF-") then "application/pdf"
      elsif head.start_with?("\x89PNG\r\n\x1A\n".b) then "image/png"
      elsif head.start_with?("\xFF\xD8\xFF".b) then "image/jpeg"
      elsif head.start_with?("II*\0".b, "MM\0*".b) then "image/tiff"
      elsif head.start_with?("RIFF") && head.byteslice(8, 4) == "WEBP" then "image/webp"
      end
    end

    # The stem of a file name: the name without its last extension.
    def self.stem(filename)
      base = File.basename(filename.to_s)
      ext = File.extname(base)
      ext.empty? ? base : base.delete_suffix(ext)
    end

    private

    # The file's bytes; a path or an IO is read to its end, or to one byte
    # past the limit, which the size check then refuses.
    def read_bytes
      return @data if @data
      return read_io(@io) if @io

      File.open(@path, "rb") { |f| read_io(f) }
    rescue SystemCallError, IOError => e
      raise ArgumentError, "cannot read #{@path}: #{e.message}"
    end

    def read_io(io)
      out = +"".b
      while out.bytesize <= MAX_BYTES && (chunk = io.read([1 << 20, MAX_BYTES + 1 - out.bytesize].min))
        out << chunk.b
      end
      out
    end

    def usage(message)
      raise BadRequestError.new(message, error_type: "api_usage_error")
    end
  end
end
