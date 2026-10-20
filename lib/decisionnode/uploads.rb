# frozen_string_literal: true

require "time"
require "uri"

class DecisionNode
  # The client's memory of the images it uploaded: by the SHA-256 of the bytes
  # and the media type, the upload id and when it stops being usable. An entry
  # is used until 5 minutes before the upload's `expires_at`; at most 256
  # entries, the least recently used out first. Never on disk, never shared
  # between clients.
  class UploadCache
    MAX_ENTRIES = 256
    # Seconds before `expires_at` from which an entry is no longer used.
    MARGIN = 300

    Entry = Struct.new(:upload_id, :expires_at)

    def initialize(max_entries: MAX_ENTRIES, clock: -> { Time.now.to_f })
      @max = max_entries
      @clock = clock
      @entries = {}
      @lock = Mutex.new
    end

    def empty?
      @entries.empty?
    end

    def size
      @entries.size
    end

    # The live upload id for these bytes, or nil.
    def get(key)
      @lock.synchronize do
        entry = @entries.delete(key)
        return nil if entry.nil? || @clock.call >= entry.expires_at - MARGIN

        @entries[key] = entry # most recently used last
        entry.upload_id
      end
    end

    def put(key, upload_id, expires_at)
      @lock.synchronize do
        @entries.delete(key)
        @entries[key] = Entry.new(upload_id, expires_at)
        @entries.delete(@entries.first.first) while @entries.size > @max
      end
    end

    # Forgets every entry naming one of these upload ids.
    def drop(upload_ids)
      @lock.synchronize { @entries.delete_if { |_, e| upload_ids.include?(e.upload_id) } }
    end

    def clear
      @lock.synchronize { @entries.clear }
    end
  end

  # Image preparation and uploads, mixed into the client.
  module Uploads
    # A `400` with one of these error types names an upload that can no longer
    # be used: an upload the SDK placed is uploaded again and the request sent
    # once more.
    STALE_UPLOAD = %w[upload_expired upload_consumed upload_not_found upload_incomplete].freeze

    # An upload id of the API's length (36 characters), naming an image that
    # would be uploaded when a body is measured before anything is sent.
    UPLOAD_ID_PLACEHOLDER = "upl_#{'0' * 32}".freeze
    private_constant :UPLOAD_ID_PLACEHOLDER

    # Uploads every image, whatever its size, and returns one upload id per
    # image (from the cache when the same bytes were uploaded before). URL
    # images and upload ids cannot be uploaded and raise ArgumentError.
    #
    # Sends one `POST /v1/uploads` for the images not in the cache, then one
    # `PUT` per image, in parallel. A call takes 1 to 16 images; more raise
    # the API's BadRequestError before anything is sent. An id names the
    # upload for an hour, in any image slot: `Image.new("receipt", upload_id: id)`.
    def upload(images)
      raise ArgumentError, "images must be an Array of DecisionNode::Image" unless images.is_a?(Array)

      images.each do |img|
        next if img.is_a?(Image) && img.local?

        raise ArgumentError, "upload takes images made from a path, bytes, base64 or an IO"
      end
      if images.size > Checks::MAX_IMAGES
        raise BadRequestError.new("files: 1 to #{Checks::MAX_IMAGES} files, got #{images.size}.", error_type: "api_usage_error")
      end

      Checks.images!(images, limits: limits_for(nil))
      ids = images.map { |img| @uploads.get(cache_key(img)) }
      missing = images.each_index.reject { |i| ids[i] }
      fresh = missing.empty? ? [] : upload_images(missing.map { |i| images[i] })
      missing.each_with_index { |i, j| ids[i] = fresh[j] }
      ids
    end

    # Uploads 1 to 16 documents for knowledge bases, whatever their type and
    # size, and returns one upload id each, in order, for a later
    # `Document.new(upload_id: id)`. A text document is uploaded as
    # text/markdown, or text/plain for format "text". A document given by its
    # upload id raises ArgumentError. Each file is checked before anything is
    # sent, as the API checks it (at most 52,428,800 bytes, not empty, one of
    # Document::CONTENT_TYPES), and nothing is cached: an upload is consumed by
    # the item it makes. An upload not named within its hour expires.
    def upload_documents(documents)
      raise ArgumentError, "documents must be an Array of DecisionNode::Document" unless documents.is_a?(Array)

      documents.each do |doc|
        next if doc.is_a?(Document) && !doc.upload_id

        raise ArgumentError, "upload_documents takes documents made from a text, a path, bytes or an IO"
      end
      unless documents.size.between?(1, Checks::MAX_IMAGES)
        raise BadRequestError.new("files: 1 to #{Checks::MAX_IMAGES} files, got #{documents.size}.",
                                  error_type: "api_usage_error")
      end

      upload_knowledge(documents.each_with_index.map { |doc, i| document_file(doc, i) })
    end

    private

    # A document's bytes as a knowledge file: a text as its UTF-8 bytes,
    # typed by its format.
    def document_file(doc, index)
      return doc.load(index) unless doc.text?

      unless doc.format.nil? || Document::FORMATS.include?(doc.format)
        raise Checks.invalid([Checks.entry("literal_error", %w[body format], "Input should be 'markdown' or 'text'",
                                           doc.format)])
      end
      type = doc.format == "text" ? "text/plain" : "text/markdown"
      Document.new(data: doc.text.encode(Encoding::UTF_8), content_type: type).load(index)
    end

    # One presign for the files with the knowledge purpose, then one PUT each
    # (in parallel), each with the document timeout. Returns the upload ids.
    def upload_knowledge(loaded)
      files = loaded.map do |f|
        file = { "purpose" => "knowledge", "content_type" => f.content_type, "byte_size" => f.data.bytesize,
                 "checksum" => [f.md5].pack("m0"), "sha256" => [f.sha256].pack("m0") }
        file["filename"] = f.filename unless f.filename.nil?
        file
      end
      targets, valid_until = presign(files)
      if targets.size != loaded.size
        raise ServerError.new("the upload answer holds #{targets.size} uploads for #{loaded.size} files")
      end

      put_all(loaded, files, targets, valid_until, timeout: @document_upload_timeout)
      targets.map { |t| t["upload_id"] }
    end

    # The per-attempt timeout of a document write: 20 s with `wait` unless
    # the caller set one; nil (the client's) otherwise.
    def write_timeout(wait)
      wait && !@timeout_given ? WAIT_TIMEOUT : nil
    end

    def cache_key(img)
      [img.sha256, img.media_type]
    end

    # Forgets uploads the API called stale, so the next image_wires uploads
    # those images again.
    def drop_uploads(upload_ids)
      @uploads.drop(upload_ids)
    end

    # The wire forms of a request's images and the upload ids the SDK placed in
    # them. URLs and upload ids go as given; a cached upload by its id whatever
    # its size; the other local images inline when all the local images total
    # under the inline threshold, else uploaded. With project: true nothing is
    # uploaded: an image that would be is named by UPLOAD_ID_PLACEHOLDER.
    def image_wires(images, project: false)
      wires = Array.new(images.size)
      placed = []
      pending = []
      total = 0
      images.each_with_index do |img, i|
        unless img.is_a?(Image)
          wires[i] = img
          next
        end
        unless img.local?
          wires[i] = img.to_h
          next
        end
        total += img.bytesize
        hit = @uploads.empty? ? nil : @uploads.get(cache_key(img))
        if hit
          wires[i] = img.upload_wire(hit)
          placed << hit
        else
          pending << i
        end
      end
      return [wires, placed] if pending.empty?

      if total >= @inline_threshold
        ids = project ? [UPLOAD_ID_PLACEHOLDER] * pending.size : upload_images(pending.map { |i| images[i] })
        pending.each_with_index do |i, j|
          wires[i] = images[i].upload_wire(ids[j])
          placed << ids[j]
        end
      else
        pending.each { |i| wires[i] = images[i].to_h }
      end
      [wires, placed]
    end

    # One presign for the distinct images, one PUT each (in parallel), then the
    # cache. Returns one upload id per image, in order. Bytes another thread is
    # uploading at the same moment are waited for, not uploaded twice.
    def upload_images(images)
      distinct = images.uniq { |img| cache_key(img) }
      mine, theirs = claim(distinct)
      by_key = {}
      begin
        transfer(mine).each { |key, id| by_key[key] = id } unless mine.empty?
      ensure
        release(mine, by_key)
      end
      theirs.each { |key, pending| by_key[key] = pending.value }
      images.map { |img| by_key[cache_key(img)] }
    end

    # The upload of one set of bytes by another thread.
    class Pending
      def initialize
        @lock = Mutex.new
        @done = ConditionVariable.new
        @state = nil
      end

      def resolve(id)
        settle([:ok, id])
      end

      def reject
        settle([:failed])
      end

      # The upload id, or the upload's failure raised.
      def value
        @lock.synchronize do
          @done.wait(@lock) while @state.nil?
          raise DecisionNodeError.new("the upload of the same image by another call failed", error_type: "upload_failed") if @state.first == :failed

          @state.last
        end
      end

      private

      def settle(state)
        @lock.synchronize do
          @state = state
          @done.broadcast
        end
      end
    end
    private_constant :Pending

    # Splits the images into those this call uploads and those another call is
    # uploading now.
    def claim(images)
      mine = []
      theirs = {}
      @inflight_lock.synchronize do
        images.each do |img|
          key = cache_key(img)
          if @inflight.key?(key)
            theirs[key] = @inflight[key]
          else
            @inflight[key] = Pending.new
            mine << img
          end
        end
      end
      [mine, theirs]
    end

    def release(images, by_key)
      pendings = @inflight_lock.synchronize { images.map { |img| @inflight.delete(cache_key(img)) } }
      images.zip(pendings).each do |img, pending|
        id = by_key[cache_key(img)]
        id ? pending.resolve(id) : pending.reject
      end
    end

    # The presign and the PUTs; returns cache key to upload id.
    def transfer(images)
      files = images.map do |img|
        { "content_type" => img.media_type, "byte_size" => img.bytesize,
          "checksum" => [img.md5].pack("m0"), "sha256" => [img.sha256].pack("m0") }
      end
      targets, valid_until = presign(files)
      if targets.size != images.size
        raise ServerError.new("the upload answer holds #{targets.size} uploads for #{images.size} files")
      end

      put_all(images, files, targets, valid_until)
      images.each_with_index.to_h do |img, i|
        target = targets[i]
        @uploads.put(cache_key(img), target["upload_id"], expiry(target["expires_at"]))
        [cache_key(img), target["upload_id"]]
      end
    end

    def presign(files)
      body, = request("POST", "/v1/uploads", { "files" => files })
      uploads = body.is_a?(Hash) ? body["uploads"] : nil
      unless uploads.is_a?(Array) && uploads.all? { |u| u.is_a?(Hash) && u["upload_id"].is_a?(String) && u["url"].is_a?(String) }
        raise ServerError.new("the upload answer has no uploads list", body: body)
      end

      uploads.each { |u| storage_uri(u["url"]) } # every URL is checked before any byte is sent
      ttl = body["expires_in"].is_a?(Numeric) ? body["expires_in"] : 300
      [uploads, @clock.call + ttl] # the URLs live expires_in seconds, by the client's clock
    end

    # The PUTs, in parallel when there are several. The first failure is raised
    # once every PUT has ended.
    def put_all(images, files, targets, valid_until, timeout: @upload_timeout)
      if images.size == 1
        put_object(images[0], files[0], targets[0], valid_until, timeout: timeout)
        return
      end

      errors = Array.new(images.size)
      threads = images.each_index.map do |i|
        Thread.new do
          put_object(images[i], files[i], targets[i], valid_until, timeout: timeout)
        rescue StandardError => e
          errors[i] = e
        end
      end
      threads.each(&:join)
      first = errors.compact.first
      raise first if first
    end

    # One PUT to the storage URL with exactly the returned headers and the
    # bytes: no key, none of the client's headers, no redirect followed. Each
    # attempt has the client's upload_timeout, apart from the API timeout.
    # Retried on 5xx and connection errors as an API call is; a 412 on a retry
    # means an earlier attempt stored the object; a 403 after the URL's time
    # is up presigns again, once. On success `target` names the stored upload.
    # A document's PUT has its own timeout.
    def put_object(image, file, target, valid_until, represigned: false, timeout: @upload_timeout)
      url = target["url"]
      headers = (target["headers"] || {}).to_h { |k, v| [k.to_s, v.to_s] }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      attempt = 0
      loop do
        response = begin
          attempt_once("PUT", url, headers, image.data, timeout: timeout)
        rescue TimeoutError, ConnectionError => e
          log("PUT", "storage", e.class.name.split("::").last, nil, started, attempt)
          raise if attempt >= @max_retries

          @sleeper.call(backoff(attempt))
          attempt += 1
          next
        end
        log("PUT", "storage", response.status, nil, started, attempt)
        status = response.status
        return if (200..299).cover?(status) || (status == 412 && attempt.positive?)

        if status >= 500 && attempt < @max_retries
          @sleeper.call(retry_wait(response.headers) || backoff(attempt))
          attempt += 1
          next
        end
        if status == 403 && !represigned && @clock.call >= valid_until
          fresh, fresh_until = presign([file])
          put_object(image, file, fresh.first, fresh_until, represigned: true, timeout: timeout)
          target.replace(fresh.first)
          return
        end
        raise storage_error(response)
      end
    end

    def storage_error(response)
      code = response.body.to_s[%r{<Code>([^<]*)</Code>}, 1]
      DecisionNodeError.new("the upload to storage failed with HTTP #{response.status}",
                            status: response.status, error_type: "upload_failed", reason: code,
                            headers: response.headers)
    end

    # A storage URL must be https; plain http only on a loopback host.
    def storage_uri(url)
      uri = URI.parse(url)
      host = uri.host.to_s.delete_prefix("[").delete_suffix("]").downcase
      return uri if uri.scheme&.downcase == "https" && !host.empty?
      return uri if uri.scheme&.downcase == "http" && LOOPBACK_HOSTS.include?(host)

      raise DecisionNodeError.new("the storage URL must use https, got #{uri.scheme}://#{uri.host}",
                                  error_type: "upload_failed")
    rescue URI::InvalidURIError
      raise DecisionNodeError.new("the storage URL is not a valid URL", error_type: "upload_failed")
    end

    def expiry(text)
      Time.iso8601(text.to_s).to_f
    rescue ArgumentError
      begin
        Time.httpdate(text.to_s).to_f
      rescue ArgumentError
        Time.now.to_f + UploadCache::MARGIN + 60 # unknown: usable for a minute
      end
    end
  end
end
