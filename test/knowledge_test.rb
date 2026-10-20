# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "stringio"
require "tempfile"

# Knowledge bases (spec 1.4): text collections, documents inline and by
# upload, the reads, waiting, search, the knowledge booster and its reading,
# the local checks and the errors.
class KnowledgeTest < Minitest::Test
  include ClientHelpers

  COL = "col_3f6c1a9e0b2d4c7f8a1e5d9b2c4f6a80"
  ITEM = "itm_9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d"
  STORAGE = "https://storage.example.test"
  PDF = "%PDF-1.7\n#{'x' * 64}".b

  # A fake API and storage for knowledge: presigns, stores PUTs, and answers
  # every other call from a block (the Call and how many calls that path has had).
  class FakeAPI
    attr_reader :calls

    def initialize(&answer)
      @answer = answer || ->(_call, _n) { FakeHTTP.json(202, { "id" => ITEM, "status" => "queued" }) }
      @calls = []
      @lock = Mutex.new
      @counter = 0
    end

    def follow_redirects?
      false
    end

    def call(method, url, headers, body, timeout)
      call = FakeHTTP::Call.new(method, url, headers, body, timeout)
      @lock.synchronize { @calls << call }
      if method == "POST" && URI(url).path == "/v1/uploads"
        uploads = call.json["files"].map do |f|
          id = @lock.synchronize { @counter += 1 }
          { "upload_id" => format("upl_%032x", id), "url" => "#{STORAGE}/obj/#{id}", "method" => "PUT",
            "headers" => { "Content-Type" => f["content_type"] }, "expires_at" => "2099-01-01T00:00:00Z",
            "purpose" => "knowledge" }
        end
        return FakeHTTP.json(201, { "uploads" => uploads, "expires_in" => 300 })
      end
      return DecisionNode::HTTPResponse.new(200, {}, "") if method == "PUT"

      @answer.call(call, @lock.synchronize { @calls.count { |c| c.method == method && URI(c.url).path == URI(url).path } })
    end

    def api_calls
      @calls.reject { |c| c.url.start_with?(STORAGE) }
    end
  end

  def path(call)
    URI(call.url).request_uri
  end

  def error(status, error_type, message = "", details: nil, headers: {})
    detail = { "error_type" => error_type, "message" => message }
    detail["details"] = details if details
    FakeHTTP.json(status, { "detail" => detail }, headers)
  end

  def text_doc(text = "# Receipts\n\nReject any claim over 500 SEK without a receipt.", **kw)
    DecisionNode::Document.new(text: text, **kw)
  end

  def passage(**extra)
    { "n" => 1, "pinned" => true, "item" => ITEM, "reference" => "policy-2026", "title" => "Claims policy 2026",
      "heading" => "Receipts", "chunk" => 3, "byte_start" => 1840, "byte_end" => 2310, "tokens" => 96,
      "score" => nil, "lexical" => false, "rendered" => true }.merge(extra.transform_keys(&:to_s))
  end

  def reading(**extra)
    { "collection" => COL, "collection_name" => "Claims policy", "corpus" => { "version" => 41 },
      "query" => { "source" => "auto", "tokens" => 212 },
      "budget" => { "mode" => "auto", "tokens" => 840, "entry" => "short", "cause" => nil },
      "scope" => { "key" => "mission", "value" => "M-42" }, "warnings" => [], "passages" => [passage],
      "omitted" => { "below_min_score" => 0, "over_budget" => 1 }, "pending_items" => 0,
      "search" => { "plan" => "exact", "candidates" => 50, "fallback" => false }, "truncated" => false }.merge(extra.transform_keys(&:to_s))
  end

  # ---- collections

  def test_create_a_knowledge_base_with_a_scope_key
    http = FakeHTTP.new(FakeHTTP.json(201, { "id" => COL, "type" => "text", "scope_key" => "mission" }))
    got = client(http).collections.create(name: "Claims policy", type: "text", scope_key: "mission")
    call = http.calls.first
    assert_equal ["POST", "/v1/collections"], [call.method, path(call)]
    assert_equal({ "type" => "text", "name" => "Claims policy", "scope_key" => "mission" }, call.json)
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, call.headers["Idempotency-Key"])
    assert_equal "mission", got["scope_key"]
  end

  def test_create_checks_the_scope_key
    dn = client(FakeHTTP.new)
    err = assert_raises(DecisionNode::ValidationError) { dn.collections.create(name: "K", type: "text", scope_key: "Mission") }
    assert_equal [{ "type" => "string_pattern_mismatch", "loc" => %w[body scope_key],
                    "msg" => "String should match pattern '^[a-z0-9_]{1,40}$'", "input" => "Mission" }], err.entries
    assert_empty dn.instance_variable_get(:@http).calls
  end

  # ---- documents

  def test_add_markdown_inline_with_every_field_and_wait
    http = FakeHTTP.new(FakeHTTP.json(201, { "id" => ITEM, "status" => "ready" }))
    got = client(http).collections.add_document(
      COL, document: text_doc("Plain.", format: "text"), title: "House rules", reference: "rules-1", pinned: true,
           pin_rank: 2, label: "Rules", metadata: { "mission" => "M-42" }, wait: true
    )
    call = http.calls.first
    assert_equal ["POST", "/v1/collections/#{COL}/items?wait=true"], [call.method, path(call)]
    assert_equal({ "title" => "House rules", "text" => "Plain.", "format" => "text", "reference" => "rules-1",
                   "pinned" => true, "pin_rank" => 2, "label" => "Rules", "metadata" => { "mission" => "M-42" } }, call.json)
    assert_equal 20.0, call.timeout
    assert_equal "ready", got["status"]
  end

  def test_add_sends_format_only_when_given_and_no_wait_by_default
    http = FakeHTTP.new(FakeHTTP.json(202, { "id" => ITEM, "status" => "queued" }))
    client(http).collections.add_document(COL, document: text_doc("# A"), title: "A")
    call = http.calls.first
    assert_equal "/v1/collections/#{COL}/items", path(call)
    assert_equal({ "title" => "A", "text" => "# A" }, call.json)
    assert_equal 10.0, call.timeout
  end

  def test_a_timeout_the_caller_set_is_used_with_wait
    http = FakeHTTP.new(FakeHTTP.json(201, {}))
    client(http, timeout: 3).collections.add_document(COL, document: text_doc, title: "A", wait: true)
    assert_equal 3.0, http.calls.first.timeout
  end

  def test_a_small_markdown_file_goes_inline_titled_by_its_stem
    file = Tempfile.create(["claims-policy-2026", ".md"])
    file.write("# Receipts\n")
    file.close
    http = FakeHTTP.new(FakeHTTP.json(202, {}))
    client(http).collections.add_document(COL, document: DecisionNode::Document.new(path: file.path))
    stem = File.basename(file.path, ".md")
    assert_equal({ "title" => stem, "text" => "# Receipts\n", "format" => "markdown" }, http.calls.first.json)
  ensure
    File.unlink(file.path) if file
  end

  def test_a_pdf_is_uploaded_then_named_by_its_upload_id
    api = FakeAPI.new
    client(api).collections.add_document(COL, document: DecisionNode::Document.new(data: PDF, filename: "claims.pdf"),
                                              reference: "policy-2026")
    presign, put, item = api.calls
    assert_equal({ "files" => [{ "purpose" => "knowledge", "content_type" => "application/pdf", "byte_size" => PDF.bytesize,
                                 "checksum" => [Digest::MD5.digest(PDF)].pack("m0"),
                                 "sha256" => [Digest::SHA256.digest(PDF)].pack("m0"), "filename" => "claims.pdf" }] },
                 presign.json)
    assert_equal ["PUT", "#{STORAGE}/obj/1", PDF, 120.0], [put.method, put.url, put.body, put.timeout]
    assert_equal({ "Content-Type" => "application/pdf" }, put.headers)
    assert_equal({ "upload_id" => format("upl_%032x", 1), "reference" => "policy-2026" }, item.json)
  end

  def test_types_come_from_the_content_type_the_name_or_the_bytes
    api = FakeAPI.new
    dn = client(api)
    png = "\x89PNG\r\n\x1A\n#{'x' * 16}".b
    dn.collections.add_document(COL, document: DecisionNode::Document.new(data: png), title: "Scan")
    dn.collections.add_document(COL, document: DecisionNode::Document.new(
      io: StringIO.new("PK\x03\x04zip".b), content_type: DecisionNode::Document::CONTENT_TYPES[3]
    ), title: "Rules")
    types = api.calls.select { |c| URI(c.url).path == "/v1/uploads" }.map { |c| c.json["files"][0]["content_type"] }
    assert_equal ["image/png", DecisionNode::Document::CONTENT_TYPES[3]], types
    assert_equal({ "upload_id" => format("upl_%032x", 1), "title" => "Scan" },
                 api.api_calls.find { |c| path(c).end_with?("/items") }.json)
  end

  def test_an_upload_id_is_sent_as_given
    http = FakeHTTP.new(FakeHTTP.json(202, {}))
    client(http).collections.add_document(COL, document: DecisionNode::Document.new(upload_id: "upl_1"), title: "T")
    assert_equal({ "upload_id" => "upl_1", "title" => "T" }, http.calls.first.json)
  end

  def test_the_threshold_for_text_files
    api = FakeAPI.new
    dn = client(api, inline_threshold: 8)
    dn.collections.add_document(COL, document: DecisionNode::Document.new(data: "1234567", filename: "a.txt"))
    dn.collections.add_document(COL, document: DecisionNode::Document.new(data: "12345678", filename: "b.txt"))
    dn.collections.add_document(COL, document: DecisionNode::Document.new(data: "\xFF\xFE".b, filename: "c.md"))
    dn.collections.add_document(COL, document: DecisionNode::Document.new(data: "a\0b", filename: "d.md"))
    items = api.api_calls.select { |c| path(c).end_with?("/items") }.map(&:json)
    assert_equal({ "title" => "a", "text" => "1234567", "format" => "text" }, items[0])
    assert_equal [true, true, true], items[1..].map { |b| b.key?("upload_id") && !b.key?("format") }
  end

  def test_replace_and_update
    http = FakeHTTP.new(FakeHTTP.json(202, {}), FakeHTTP.json(200, {}))
    dn = client(http)
    dn.collections.replace_document(COL, ITEM, document: text_doc("New."), title: "T", wait: true)
    dn.collections.update_item(COL, ITEM, pinned: true, pin_rank: 0, title: "Renamed", label: nil)
    put, patch = http.calls
    assert_equal ["PUT", "/v1/collections/#{COL}/items/#{ITEM}?wait=true"], [put.method, path(put)]
    assert_equal({ "title" => "T", "text" => "New." }, put.json)
    assert_equal ["PATCH", { "label" => nil, "pinned" => true, "pin_rank" => 0, "title" => "Renamed" }],
                 [patch.method, patch.json]
    refute_nil put.headers["Idempotency-Key"]
    refute_equal put.headers["Idempotency-Key"], patch.headers["Idempotency-Key"]
  end

  def test_the_reads
    http = FakeHTTP.new(FakeHTTP.json(200, { "id" => ITEM, "text" => "x" }))
    dn = client(http)
    dn.collections.get_item(COL, ITEM, include_text: true)
    dn.collections.get_item(COL, ITEM)
    dn.collections.list_chunks(COL, ITEM, offset: 20, limit: 10)
    dn.collections.list_chunks(COL, ITEM)
    dn.collections.delete_failed_items(COL)
    assert_equal [["GET", "/v1/collections/#{COL}/items/#{ITEM}?include=text"],
                  ["GET", "/v1/collections/#{COL}/items/#{ITEM}"],
                  ["GET", "/v1/collections/#{COL}/items/#{ITEM}/chunks?offset=20&limit=10"],
                  ["GET", "/v1/collections/#{COL}/items/#{ITEM}/chunks"],
                  ["DELETE", "/v1/collections/#{COL}/items?status=failed"]], http.calls.map { |c| [c.method, path(c)] }
    assert(http.calls.none? { |c| c.headers.key?("Idempotency-Key") })
    assert_raises(DecisionNode::BadRequestError) { dn.collections.list_chunks(COL, ITEM, limit: 101) }
  end

  def test_upload_documents
    api = FakeAPI.new
    ids = client(api).upload_documents([DecisionNode::Document.new(data: PDF, filename: "a.pdf"), text_doc("Plain", format: "text")])
    assert_equal [format("upl_%032x", 1), format("upl_%032x", 2)], ids
    files = api.calls.first.json["files"]
    assert_equal [%w[application/pdf a.pdf], ["text/plain", nil]], files.map { |f| f.values_at("content_type", "filename") }
    assert_raises(ArgumentError) { client(api).upload_documents([DecisionNode::Document.new(upload_id: "upl_1")]) }
    err = assert_raises(DecisionNode::BadRequestError) { client(api).upload_documents([]) }
    assert_equal "files: 1 to 16 files, got 0.", err.message
  end

  def test_an_image_upload_never_sends_a_purpose
    api = FakeAPI.new
    png = File.binread(File.join(__dir__, "fixtures", "images", "baseline.jpg"))
    client(api).upload([DecisionNode::Image.new("a", data: png)])
    refute api.calls.first.json["files"][0].key?("purpose")
  end

  # ---- idempotency and stale uploads

  def test_the_idempotency_key_is_the_same_on_every_attempt
    http = FakeHTTP.new(error(503, "api_error"), error(409, "idempotency_in_progress", headers: { "retry-after" => "1" }),
                        FakeHTTP.json(202, {}))
    client(http).collections.add_document(COL, document: text_doc, title: "A")
    assert_equal 3, http.calls.size
    assert_equal 1, http.calls.map { |c| c.headers["Idempotency-Key"] }.uniq.size
  end

  def test_a_stale_upload_is_uploaded_again_once_with_a_new_key
    api = FakeAPI.new { |_call, n| n == 1 ? error(400, "upload_expired") : FakeHTTP.json(202, {}) }
    client(api).collections.add_document(COL, document: DecisionNode::Document.new(data: PDF, filename: "a.pdf"))
    items = api.api_calls.select { |c| path(c).end_with?("/items") }
    assert_equal 2, api.calls.count { |c| c.method == "PUT" }
    assert_equal [format("upl_%032x", 1), format("upl_%032x", 2)], items.map { |c| c.json["upload_id"] }
    refute_equal items[0].headers["Idempotency-Key"], items[1].headers["Idempotency-Key"]

    api = FakeAPI.new { |_call, _n| error(400, "upload_consumed") }
    assert_raises(DecisionNode::BadRequestError) do
      client(api).collections.add_document(COL, document: DecisionNode::Document.new(data: PDF, filename: "a.pdf"))
    end
    assert_equal 2, api.api_calls.count { |c| path(c).end_with?("/items") }
  end

  def test_a_purpose_mismatch_or_a_given_upload_is_never_uploaded_again
    api = FakeAPI.new { |_call, _n| error(400, "upload_purpose_mismatch") }
    assert_raises(DecisionNode::BadRequestError) do
      client(api).collections.add_document(COL, document: DecisionNode::Document.new(data: PDF, filename: "a.pdf"))
    end
    assert_equal 1, api.calls.count { |c| c.method == "PUT" }
    http = FakeHTTP.new(error(400, "upload_expired"))
    assert_raises(DecisionNode::BadRequestError) do
      client(http).collections.add_document(COL, document: DecisionNode::Document.new(upload_id: "upl_1"), title: "T")
    end
    assert_equal 1, http.calls.size
  end

  # ---- local checks

  def assert_local(klass, http = FakeHTTP.new, &block)
    err = assert_raises(klass) { block.call(client(http).collections) }
    assert_nil err.status
    assert_empty http.calls
    err
  end

  def test_the_local_checks_send_nothing
    err = assert_local(DecisionNode::ValidationError) { |c| c.add_document(COL, document: text_doc) }
    assert_equal [{ "type" => "missing", "loc" => %w[body title], "msg" => "Field required", "input" => nil }], err.entries
    err = assert_local(DecisionNode::ValidationError) do |c|
      c.add_document(COL, document: text_doc(format: "html"), title: " #{'t' * 201} ", pin_rank: 1.5, reference: "a b")
    end
    assert_equal [%w[string_too_long title], %w[literal_error format], %w[string_pattern_mismatch reference],
                  %w[int_range pin_rank]], err.entries.map { |e| [e["type"], e["loc"][1]] }
    assert_equal "#{' ' + ('t' * 63)}...", err.entries[0]["input"]
    err = assert_local(DecisionNode::ValidationError) { |c| c.add_document(COL, document: text_doc(""), title: "T") }
    assert_equal [{ "type" => "string_too_short", "loc" => %w[body text], "msg" => "The text is empty", "input" => "" }],
                 err.entries
    err = assert_local(DecisionNode::ValidationError) do |c|
      c.add_document(COL, document: DecisionNode::Document.new(data: "words", content_type: "text/plain"))
    end
    assert_equal "title", err.entries.first["loc"][1]
    err = assert_local(DecisionNode::ValidationError) { |c| c.update_item(COL, ITEM, label: "x" * 129, title: "") }
    assert_equal "A label is 1 to 128 characters with no control or invisible characters", err.entries[0]["msg"]
  end

  def test_the_file_checks_send_nothing
    err = assert_local(DecisionNode::BadRequestError) do |c|
      c.add_document(COL, document: DecisionNode::Document.new(data: "", filename: "a.pdf"))
    end
    assert_equal ["api_usage_error", "files[0].byte_size: must be at least 1."], [err.error_type, err.message]
    err = assert_local(DecisionNode::BadRequestError) do |c|
      c.add_document(COL, document: DecisionNode::Document.new(data: "PK\x03\x04".b), title: "T")
    end
    assert_equal "files[0].content_type: must be one of #{DecisionNode::Document::CONTENT_TYPES.join(', ')}.", err.message
    big = StringIO.new("x" * (DecisionNode::Document::MAX_BYTES + 1))
    err = assert_local(DecisionNode::BadRequestError) do |c|
      c.add_document(COL, document: DecisionNode::Document.new(io: big, filename: "a.pdf"))
    end
    assert_equal "files[0].byte_size: 52428801 is over the limit of 52428800 bytes.", err.message
  end

  # ---- waiting

  def test_wait_until_ready_polls_an_item_with_a_growing_wait
    statuses = %w[queued processing ready]
    http = FakeHTTP.new(->(_c) { FakeHTTP.json(200, { "id" => ITEM, "status" => statuses.shift }) })
    dn = client(http)
    got = dn.collections.wait_until_ready(COL, ITEM)
    assert_equal "ready", got["status"]
    assert_equal [1.0, 1.5], dn.sleeps
    assert_equal ["/v1/collections/#{COL}/items/#{ITEM}"] * 3, http.calls.map { |c| path(c) }
  end

  def test_a_failed_item_is_returned
    http = FakeHTTP.new(FakeHTTP.json(200, { "id" => ITEM, "status" => "failed", "error" => "chunks_limit_reached" }))
    assert_equal "chunks_limit_reached", client(http).collections.wait_until_ready(COL, ITEM)["error"]
  end

  def test_wait_until_ready_on_the_collection_and_its_timeout
    counts = [{ "queued" => 1, "processing" => 0 }, { "queued" => 0, "processing" => 0, "ready" => 3 }]
    http = FakeHTTP.new(->(_c) { FakeHTTP.json(200, { "id" => COL, "status_counts" => counts.shift }) })
    got = client(http).collections.wait_until_ready(COL)
    assert_equal 3, got["status_counts"]["ready"]
    assert_equal ["/v1/collections/#{COL}"] * 2, http.calls.map { |c| path(c) }

    http = FakeHTTP.new(FakeHTTP.json(200, { "id" => ITEM, "status" => "uploading" }))
    assert_raises(DecisionNode::TimeoutError) { client(http).collections.wait_until_ready(COL, ITEM, timeout: 3) }
    assert_raises(ArgumentError) { client(http).collections.wait_until_ready(COL, ITEM, poll_interval: 0.05) }
    assert_raises(ArgumentError) { client(http).collections.wait_until_ready(COL, ITEM, timeout: 0) }
  end

  # ---- search, the booster and the reading

  def test_search_sends_the_options_given_and_returns_a_reading
    http = FakeHTTP.new(FakeHTTP.json(200, reading(passages: [passage(text: "Reject ...", rendered: nil)]).except("truncated")))
    got = client(http).collections.search(COL, query: "receipts", scope: "M-42", top_k: 2, max_tokens: "auto",
                                                match: { "region" => "SE" }, pinned: false)
    assert_equal ["POST", "/v1/collections/#{COL}/search"], [http.calls.first.method, path(http.calls.first)]
    assert_equal({ "query" => "receipts", "scope" => "M-42", "match" => { "region" => "SE" }, "top_k" => 2,
                   "pinned" => false, "max_tokens" => "auto" }, http.calls.first.json)
    assert_kind_of DecisionNode::KnowledgeReading, got
    assert_equal "Reject ...", got.passages.first.text
    assert_nil got.truncated
  end

  def test_the_knowledge_builder
    assert_equal({ "name" => "knowledge", "options" => { "collection" => COL } }, DecisionNode.knowledge(COL).wire)
    every = DecisionNode.knowledge(COL, query: "q", scope: "M-42", match: { "a" => 1 }, filter: { "and" => [] }, top_k: 0,
                                        max_tokens: 256, pinned: false, min_score: 0.4, include_text: true, require: true)
    assert_equal({ "name" => "knowledge", "require" => true,
                   "options" => { "collection" => COL, "query" => "q", "scope" => "M-42", "match" => { "a" => 1 },
                                  "filter" => { "and" => [] }, "top_k" => 0, "max_tokens" => 256, "pinned" => false,
                                  "min_score" => 0.4, "include_text" => true } }, every.wire)
    assert_raises(ArgumentError) { DecisionNode.knowledge(COL, scopes: "x") }
  end

  def test_a_decision_reads_the_knowledge_evidence
    body = truth_body.merge("evidence" => { "knowledge" => { "version" => "knowledge-v1", "status" => "ok",
                                                             "latency_ms" => 141, "billed_calls" => 1,
                                                             "results" => [reading] } })
    http = FakeHTTP.new(FakeHTTP.json(200, body))
    d = client(http).decide(questions: { "q" => DecisionNode.truth("?") }, boosters: [DecisionNode.knowledge(COL)])
    r = d.evidence["knowledge"].results.first
    assert_kind_of DecisionNode::KnowledgeReading, r
    assert_equal [COL, "Claims policy", { "version" => 41 }, 0, false], [r.collection, r.collection_name, r.corpus,
                                                                          r.pending_items, r.truncated]
    p = r.passages.first
    assert_equal [1, true, ITEM, 3, 1840, 2310, nil], [p.n, p.pinned, p.item, p.chunk, p.byte_start, p.byte_end, p.score]
    assert_equal 10.0, http.calls.first.timeout
  end

  def test_a_malformed_reading_or_passage_is_generic
    assert_kind_of DecisionNode::UnknownReading, DecisionNode::Reading.from("knowledge", reading.except("collection"))
    bad = reading(passages: [passage.except("byte_end")])
    assert_kind_of DecisionNode::UnknownReading, DecisionNode::Reading.from("knowledge", bad)
    assert_equal [], DecisionNode::Reading.from("knowledge", reading.except("warnings")).warnings
  end

  def test_knowledge_never_takes_the_ocr_timeout
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(questions: { "q" => DecisionNode.truth("?") }, boosters: ["ocr", DecisionNode.knowledge(COL)])
    assert_equal 10.0, http.calls.first.timeout
  end

  # ---- errors

  def test_the_errors
    http = FakeHTTP.new(FakeHTTP.json(422, { "detail" => { "error_type" => "invalid_text", "message" => "m" } }))
    err = assert_raises(DecisionNode::ValidationError) { client(http, max_retries: 0).collections.add_document(COL, document: text_doc, title: "A") }
    assert_equal [], err.entries
    http = FakeHTTP.new(error(529, "booster_unavailable", details: { "reason" => "ingestion_delayed" },
                                                         headers: { "retry-after" => "60" }))
    err = assert_raises(DecisionNode::OverloadedError) do
      client(http).decide(questions: { "q" => DecisionNode.truth("?") }, boosters: [DecisionNode.knowledge(COL, require: true)])
    end
    assert_equal [1, "ingestion_delayed"], [http.calls.size, err.details["reason"]]
    http = FakeHTTP.new(error(529, "booster_unavailable", headers: { "retry-after" => "5" }), FakeHTTP.json(200, truth_body))
    dn = client(http)
    dn.decide(questions: { "q" => DecisionNode.truth("?") }, boosters: [DecisionNode.knowledge(COL, require: true)])
    assert_equal [5.0], dn.sleeps
    http = FakeHTTP.new(error(409, "knowledge_collection_empty", details: { "items" => 0, "failed" => 0 }))
    err = assert_raises(DecisionNode::DecisionNodeError) do
      client(http).decide(questions: { "q" => DecisionNode.truth("?") }, boosters: [DecisionNode.knowledge(COL, require: true)])
    end
    assert_equal [DecisionNode::DecisionNodeError, 409, { "items" => 0, "failed" => 0 }], [err.class, err.status, err.details]
  end
end
