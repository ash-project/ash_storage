defmodule AshStorage.Plug.ResponseMetadataTest do
  use ExUnit.Case, async: true

  alias AshStorage.Plug.ResponseMetadata

  @images ["image/png", "image/jpeg", "image/gif", "image/webp"]

  describe "init/1" do
    test "defaults to no inline types and an octet-stream fallback" do
      assert ResponseMetadata.init([]) ==
               %{inline: [], content_type_fallback: "application/octet-stream"}
    end

    test "resolves the built-in sets, which contain no active types" do
      assert ResponseMetadata.init(inline: :images).inline == @images
      assert ResponseMetadata.init(inline: :documents).inline == @images ++ ["application/pdf"]

      for policy <- [:images, :documents], type <- ["image/svg+xml", "text/html"] do
        refute type in ResponseMetadata.init(inline: policy).inline
      end
    end

    test "normalises an explicit list and the fallback" do
      assert ResponseMetadata.init(inline: [" Image/PNG ", "image/svg+xml", "image/png"]).inline ==
               ["image/png", "image/svg+xml"]

      assert ResponseMetadata.init(content_type_fallback: "Text/Plain").content_type_fallback ==
               "text/plain"
    end

    test "raises on an invalid :inline option" do
      for value <- [:all, "image/png", ["image/*"], [:images], ["image/png; q=1"], nil] do
        assert_raise ArgumentError, ~r/invalid :inline option/, fn ->
          ResponseMetadata.init(inline: value)
        end
      end
    end

    test "raises on an invalid :content_type_fallback option" do
      for value <- [nil, "plain", :text, "text/plain; charset=utf-8"] do
        assert_raise ArgumentError, ~r/invalid :content_type_fallback option/, fn ->
          ResponseMetadata.init(content_type_fallback: value)
        end
      end
    end
  end

  describe "content_type/1" do
    test "uses the fallback when nothing else gives a type" do
      assert ResponseMetadata.content_type(key: "abc123") == "application/octet-stream"
      assert ResponseMetadata.content_type(key: "abc123", fallback: "text/plain") == "text/plain"
    end

    test "prefers the filename over the key" do
      assert ResponseMetadata.content_type(key: "abc.png", filename: "evil.html") == "text/html"
      assert ResponseMetadata.content_type(key: "abc.png", filename: "noext") == "image/png"
    end

    test "prefers a declared type, ignoring generic and malformed ones" do
      assert ResponseMetadata.content_type(
               declared: "Image/PNG; charset=binary",
               filename: "evil.html",
               key: "k"
             ) == "image/png"

      assert ResponseMetadata.content_type(
               declared: "application/octet-stream",
               filename: "a.gif",
               key: "k"
             ) == "image/gif"

      assert ResponseMetadata.content_type(
               declared: "garbage",
               key: "k",
               stored: "application/pdf",
               fallback: "x/y"
             ) == "application/pdf"

      assert ResponseMetadata.content_type(
               declared: "",
               key: "k",
               stored: "binary/octet-stream",
               fallback: "x/y"
             ) == "x/y"
    end
  end

  describe "disposition/3" do
    test "is inline only for allowlisted types and never when attachment is requested" do
      images = ResponseMetadata.inline_types!(:images)
      documents = ResponseMetadata.inline_types!(:documents)

      assert ResponseMetadata.disposition("text/html", images, nil) == :attachment
      assert ResponseMetadata.disposition("image/png", images, nil) == :inline
      assert ResponseMetadata.disposition("image/png", images, :attachment) == :attachment
      assert ResponseMetadata.disposition("image/png", [], nil) == :attachment
      assert ResponseMetadata.disposition("image/svg+xml", documents, nil) == :attachment
      assert ResponseMetadata.disposition("application/pdf", documents, nil) == :inline
      assert ResponseMetadata.disposition("IMAGE/PNG; x=1", images, nil) == :inline
    end
  end

  describe "content_disposition/2" do
    test "omits unusable filenames" do
      for name <- [nil, "", ["a"], <<255, 254>>, "\"\\/"] do
        assert ResponseMetadata.content_disposition(:attachment, name) == "attachment"
      end
    end

    test "encodes filenames per RFC 6266" do
      cases = [
        {"download.txt", ~s(attachment; filename="download.txt")},
        {~s(a.txt"; x="y), ~s(attachment; filename="a.txt; x=y")},
        {"back\\slash.txt", ~s(attachment; filename="backslash.txt")},
        {"../../etc/passwd", ~s(attachment; filename="....etcpasswd")},
        {"a\r\nb\tc\0d\x7Fe\u0085f.txt", ~s(attachment; filename="abcdef.txt")},
        {"  spaced name.txt  ", ~s(attachment; filename="spaced name.txt")},
        {"résumé.pdf",
         ~s(attachment; filename="r_sum_.pdf"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf)},
        {"日本語.pdf",
         ~s(attachment; filename="___.pdf"; filename*=UTF-8''%E6%97%A5%E6%9C%AC%E8%AA%9E.pdf)},
        {"100%.txt", ~s(attachment; filename="100_.txt"; filename*=UTF-8''100%25.txt)},
        {String.duplicate("a", 300), ~s(attachment; filename="#{String.duplicate("a", 255)}")}
      ]

      for {name, expected} <- cases do
        assert ResponseMetadata.content_disposition(:attachment, name) == expected
      end
    end

    test "caps the filename before trimming it" do
      name = String.duplicate("a", 254) <> " b"
      capped = String.duplicate("a", 254)

      assert ResponseMetadata.sanitize_filename(name) == capped

      assert ResponseMetadata.sanitize_filename(ResponseMetadata.sanitize_filename(name)) ==
               capped
    end

    test "adds the filename to inline responses" do
      assert ResponseMetadata.content_disposition(:inline, "photo.png") ==
               ~s(inline; filename="photo.png")
    end
  end

  describe "request_params/2" do
    defp params(query, access \\ :unsigned),
      do: ResponseMetadata.request_params(Plug.Test.conn(:get, query), access)

    test "reads the query on an unsigned mount, where only an exact attachment narrows" do
      assert params("/k?disposition=attachment&filename=a%22b.png") ==
               %{disposition: :attachment, filename: "ab.png", content_type: nil}

      for query <- ["?disposition=inline", "?disposition=ATTACHMENT", "?disposition[a]=b", ""] do
        assert params("/k" <> query).disposition == nil
      end
    end

    test "ignores non-string query values" do
      assert params("/k?filename[]=a").filename == nil
    end

    test "reads the claims on a signed mount and ignores the query" do
      claims = %{"s" => "k", "d" => "attachment", "f" => "a\"/b.png", "t" => "image/png"}

      assert params("/k?filename=evil.html", claims) ==
               %{disposition: :attachment, filename: "ab.png", content_type: "image/png"}

      assert params("/k?disposition=attachment&filename=evil.html", %{"s" => "k"}) ==
               %{disposition: nil, filename: nil, content_type: nil}
    end

    test "ignores claim values of the wrong type" do
      claims = %{"s" => "k", "d" => true, "f" => 1, "t" => ["image/png"]}

      assert params("/k", claims) == %{disposition: nil, filename: nil, content_type: nil}
    end
  end
end
