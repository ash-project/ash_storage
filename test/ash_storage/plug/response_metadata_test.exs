defmodule AshStorage.Plug.ResponseMetadataTest do
  use ExUnit.Case, async: true

  alias AshStorage.Plug.ResponseMetadata, as: RM

  describe "inline_content_types/1" do
    test ":none is empty" do
      assert MapSet.equal?(RM.inline_content_types(:none), MapSet.new())
    end

    test ":images is raster only, no SVG" do
      set = RM.inline_content_types(:images)
      assert MapSet.member?(set, "image/png")
      assert MapSet.member?(set, "image/webp")
      refute MapSet.member?(set, "image/svg+xml")
      refute MapSet.member?(set, "application/pdf")
    end

    test ":documents adds application/pdf to the images set" do
      set = RM.inline_content_types(:documents)
      assert MapSet.member?(set, "application/pdf")
      assert MapSet.member?(set, "image/png")
      refute MapSet.member?(set, "image/svg+xml")
    end

    test "a list is taken verbatim (normalized)" do
      set = RM.inline_content_types(["Image/PNG", "application/pdf; x=1"])
      assert MapSet.member?(set, "image/png")
      assert MapSet.member?(set, "application/pdf")
    end

    test "a MapSet passes through unchanged (resolve-once-at-init)" do
      set = MapSet.new(["image/png"])
      assert RM.inline_content_types(set) == set
    end
  end
end
