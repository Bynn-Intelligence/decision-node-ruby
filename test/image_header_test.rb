# frozen_string_literal: true

require_relative "test_helper"

class ImageHeaderTest < Minitest::Test
  FIXTURES = File.join(__dir__, "fixtures", "images")

  def fixture(name)
    File.binread(File.join(FIXTURES, name))
  end

  def dims(name)
    bytes = fixture(name)
    DecisionNode::ImageHeader.dimensions(bytes, DecisionNode::ImageHeader.media_type(bytes))
  end

  def test_media_type_from_magic_bytes
    assert_equal "image/jpeg", DecisionNode::ImageHeader.media_type(fixture("baseline.jpg"))
    assert_equal "image/png", DecisionNode::ImageHeader.media_type(fixture("image.png"))
    assert_equal "image/webp", DecisionNode::ImageHeader.media_type(fixture("lossy.webp"))
    assert_nil DecisionNode::ImageHeader.media_type("GIF89a\x01\x00\x01\x00".b)
    assert_nil DecisionNode::ImageHeader.media_type("".b)
  end

  def test_jpeg_baseline_after_an_exif_segment
    assert_equal [3, 2], dims("baseline.jpg")
  end

  def test_jpeg_progressive
    assert_equal [5, 4], dims("progressive.jpg")
  end

  def test_png_ihdr
    assert_equal [7, 3], dims("image.png")
  end

  def test_webp_lossy_vp8
    assert_equal [9, 5], dims("lossy.webp")
  end

  def test_webp_lossless_vp8l
    assert_equal [11, 6], dims("lossless.webp")
  end

  def test_webp_extended_vp8x
    assert_equal [13, 7], dims("extended.webp")
  end

  def test_jpeg_fill_bytes_before_a_marker
    bytes = fixture("progressive.jpg")
    padded = bytes.byteslice(0, 2) + "\xFF\xFF".b + bytes.byteslice(2..)
    assert_equal [5, 4], DecisionNode::ImageHeader.jpeg(padded)
  end

  def test_truncated_headers_read_as_nil
    %w[baseline.jpg progressive.jpg image.png lossy.webp lossless.webp extended.webp].each do |name|
      bytes = fixture(name)
      type = DecisionNode::ImageHeader.media_type(bytes)
      assert_nil DecisionNode::ImageHeader.dimensions(bytes.byteslice(0, 14), type), name
    end
    # A scan before any frame header is not a readable JPEG.
    assert_nil DecisionNode::ImageHeader.jpeg("\xFF\xD8\xFF\xDA\x00\x02".b)
    # A PNG whose first chunk is not IHDR.
    assert_nil DecisionNode::ImageHeader.png("\x89PNG\r\n\x1A\n\x00\x00\x00\x0DIDAT\x00\x00\x00\x01\x00\x00\x00\x01".b)
  end
end
