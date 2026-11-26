# frozen_string_literal: true

require "test_helper"

# usage.image_tokens and usage.video_tokens, read from the
# x-decisionnode-image-tokens and x-decisionnode-video-tokens headers.
class TokenSharesTest < Minitest::Test
  include ClientHelpers

  IMAGE = "x-decisionnode-image-tokens"
  VIDEO = "x-decisionnode-video-tokens"
  BODY = { "answers" => {}, "usage" => { "input_tokens" => 1300, "output_tokens" => 0 } }.freeze
  BAD = ["", "   ", "-1", "-0", "+5", "12.0", "1e3", "abc", "12 3", "0x10", "١٢", "²", "7\n",
         "2147483648", "99999999999999999999999"].freeze

  def shares(headers)
    d = DecisionNode::Decision.new(BODY, headers)
    assert_equal 1300, d.usage.input_tokens, "never changed by the shares"
    assert_equal BODY, d.raw, "raw is the body as sent"
    [d.usage.image_tokens, d.usage.video_tokens]
  end

  def one(name, value)
    image, video = shares(name => value)
    if name == IMAGE
      assert_nil video, "#{name}=#{value.inspect}"
      image
    else
      assert_nil image, "#{name}=#{value.inspect}"
      video
    end
  end

  def test_both_headers_present
    assert_equal [1024, 256], shares(IMAGE => "1024", VIDEO => "256")
  end

  def test_both_headers_absent
    assert_equal [nil, nil], shares({})
  end

  def test_whole_numbers_read_and_spaces_are_trimmed
    [IMAGE, VIDEO].each do |name|
      assert_equal 512, one(name, "512")
      assert_equal 0, one(name, "0")
      assert_equal 77, one(name, "  77 ")
      assert_equal 42, one(name, "\t42\t")
      assert_equal 2_147_483_647, one(name, "2147483647")
    end
  end

  def test_anything_else_reads_nil_and_never_fails
    [IMAGE, VIDEO].each do |name|
      BAD.each { |value| assert_nil one(name, value), "#{name}=#{value.inspect}" }
    end
  end

  def test_decide_reads_both_headers
    body = truth_body.merge("usage" => { "input_tokens" => 1400, "output_tokens" => 0 })
    http = FakeHTTP.new(FakeHTTP.json(200, body, IMAGE => "1024", VIDEO => "300"))
    d = client(http).decide(questions: { q: DecisionNode.truth("?") })
    assert_equal 1400, d.usage.input_tokens
    assert_equal [1024, 300], [d.usage.image_tokens, d.usage.video_tokens]
    refute d.raw["usage"].key?("image_tokens")
  end

  def test_decide_without_the_headers_reads_nil
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    d = client(http).decide(questions: { q: DecisionNode.truth("?") })
    assert_equal [nil, nil], [d.usage.image_tokens, d.usage.video_tokens]
  end

  def test_a_batch_line_reads_nil
    line = { "custom_id" => "a", "status" => 200, "headers" => { "X-Request-Id" => "req_1" },
             "body" => { "answers" => {}, "usage" => { "input_tokens" => 5, "output_tokens" => 0 } } }
    d = DecisionNode::BatchResult.new(line, ->(*) { raise "not an error line" }).decision
    assert_equal [nil, nil], [d.usage.image_tokens, d.usage.video_tokens]
  end

  def test_the_struct_keeps_its_positional_members
    usage = DecisionNode::Usage.new(1, 0, nil, nil, nil, nil, nil)
    assert_equal [1, 0, nil, nil], [usage.input_tokens, usage.output_tokens, usage.image_tokens, usage.video_tokens]
  end
end
