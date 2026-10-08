# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# An Image's own checks, run before any request.
class ImageTest < Minitest::Test
  FIXTURES = File.join(__dir__, "fixtures", "images")

  def fixture(name)
    File.binread(File.join(FIXTURES, name))
  end

  def png_header(width, height)
    "\x89PNG\r\n\x1A\n\x00\x00\x00\x0DIHDR".b + [width, height].pack("NN") + "\x08\x02\x00\x00\x00".b
  end

  def test_pixel_cap_from_the_header_alone
    assert_equal [8000, 6000], DecisionNode::ImageHeader.png(png_header(8000, 6000))
    image = DecisionNode::Image.new("huge", data: png_header(8000, 6000))
    error = assert_raises(DecisionNode::BadRequestError) { image.validate! }
    assert_match(/8000x6000 pixels, over 40 megapixels/, error.message)
    assert_nil error.status
    DecisionNode::Image.new("ok", data: png_header(8000, 5000)).validate!
  end

  def test_size_cap
    big = fixture("image.png") + ("\0".b * (DecisionNode::Image::MAX_BYTES - 76))
    assert_operator big.bytesize, :>, DecisionNode::Image::MAX_BYTES
    assert_raises(DecisionNode::BadRequestError) { DecisionNode::Image.new("big", data: big).validate! }
    exact = big.byteslice(0, DecisionNode::Image::MAX_BYTES)
    DecisionNode::Image.new("exact", data: exact).validate!
  end

  def url_fault(url)
    DecisionNode::Checks.image_url!("u", url)
    nil
  rescue DecisionNode::BadRequestError => e
    e.error_type
  end

  def test_url_checks
    assert_nil url_fault("https://example.com/a.png")
    assert_nil url_fault("https://example.com:443/a.png")
    assert_nil url_fault("https://8.8.8.8/a.png")
    assert_nil url_fault("https://example.com/#{'a' * (2048 - 20)}")
    assert_equal "api_usage_error", url_fault("http://example.com/a.png")
    assert_equal "api_usage_error", url_fault("ftp://example.com/a.png")
    %w[https:// https://user:pw@example.com/a https://example.com:8443/a https://10.1.2.3/a https://169.254.169.254/latest
       https://[::1]/a https://[::ffff:192.168.0.1]/a https://[64:ff9b::a00:1]/a https://[fe80::1]:443/a].each do |url|
      assert_equal "image_url_refused", url_fault(url), url
    end
    assert_equal "image_url_refused", url_fault("https://example.com/#{'a' * 2048}")
  end

  def test_base64_io_and_bytes_give_the_same_image
    bytes = fixture("lossy.webp")
    from_base64 = DecisionNode::Image.new("a", base64: [bytes].pack("m0"))
    from_data_text = DecisionNode::Image.new("a", data: [bytes].pack("m"))
    from_io = DecisionNode::Image.new("a", data: StringIO.new(bytes))
    [from_base64, from_data_text, from_io].each do |img|
      assert_equal bytes, img.data
      assert_equal "image/webp", img.media_type
      assert_equal [9, 5], img.dimensions
    end
    assert_raises(ArgumentError) { DecisionNode::Image.new("a", base64: "not base64!") }
  end

  def test_request_level_image_checks
    png = DecisionNode::Image.new("a", data: fixture("image.png"))
    error = assert_raises(DecisionNode::BadRequestError) do
      DecisionNode::Checks.images!(Array.new(17) { |i| DecisionNode::Image.new("i#{i}", data: fixture("image.png")) })
    end
    assert_equal "Too many images: 17, the limit is 16.", error.message
    assert_nil DecisionNode::Checks.images!(Array.new(16) { |i| DecisionNode::Image.new("i#{i}", data: fixture("image.png")) })
    held = assert_raises(DecisionNode::BadRequestError) do
      DecisionNode::Checks.images!([png, DecisionNode::Image.new("b", data: fixture("image.png"))], limits: { "images" => { "max_images" => 1 } })
    end
    assert_equal "Too many images: 2, the limit is 1.", held.message
    assert_raises(DecisionNode::BadRequestError) do
      DecisionNode::Checks.images!([png, DecisionNode::Image.new("a", url: "https://example.com/a.png")])
    end
  end
end
