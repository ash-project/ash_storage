defmodule AshStorage.PolymorphicRecordTypeTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshStorage.Operations
  alias AshStorage.Test.{ExtraAttrsPost, NoHeadPost, PolymorphicAttachment}

  defmodule Domain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshStorage.PolymorphicRecordTypeTest.Article
      resource AshStorage.PolymorphicRecordTypeTest.Profile
    end
  end

  defmodule Article do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.PolymorphicRecordTypeTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)

      has_one_attached :image do
        variant(:uppercase, AshStorage.Test.UppercaseVariant)
      end

      has_many_attached :files do
        sort blob_id: :asc
        variant(:uppercase, AshStorage.Test.UppercaseVariant)
      end
    end

    attributes do
      uuid_primary_key :id, writable?: true
    end

    aggregates do
      count :files_count, :files
    end

    actions do
      defaults [:read, :destroy, create: [:id], update: []]
    end
  end

  defmodule Profile do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.PolymorphicRecordTypeTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)

      has_one_attached :image do
        variant(:uppercase, AshStorage.Test.UppercaseVariant)
      end

      has_many_attached :files do
        sort blob_id: :asc
        variant(:uppercase, AshStorage.Test.UppercaseVariant)
      end
    end

    attributes do
      uuid_primary_key :id, writable?: true
    end

    aggregates do
      count :files_count, :files
    end

    actions do
      defaults [:read, :destroy, create: [:id], update: []]
    end
  end

  setup do
    AshStorage.Service.Test.reset!()
    id = Ash.UUID.generate()
    article = Ash.create!(Article, %{id: id})
    profile = Ash.create!(Profile, %{id: id})
    %{id: id, article: article, profile: profile}
  end

  defp text(opts), do: Keyword.merge([content_type: "text/plain"], opts)

  describe "record_type/1" do
    test "is the module name as a string" do
      assert AshStorage.Info.record_type(Article) ==
               "Elixir.AshStorage.PolymorphicRecordTypeTest.Article"
    end

    test "matches what attach writes", %{profile: profile} do
      {:ok, %{attachment: attachment}} =
        Operations.attach(profile, :image, "p", text(filename: "p.txt"))

      assert attachment.record_type == AshStorage.Info.record_type(Profile)
    end
  end

  describe "generated relationship" do
    test "polymorphic mode filters on name and record_type" do
      for {resource, name} <- [{Article, :image}, {Article, :files}, {NoHeadPost, :cover_image}] do
        rel = Ash.Resource.Info.relationship(resource, name)
        assert length(rel.filters) == 2

        assert inspect(rel.filter) =~
                 ~s(record_type == "#{AshStorage.Info.record_type(resource)}")

        assert inspect(rel.filter) =~ ~s(name == "#{name}")
      end
    end

    test "belongs_to_resource mode filters on name only" do
      for {resource, name} <- [
            {AshStorage.Test.Post, :cover_image},
            {AshStorage.Test.Post, :documents}
          ] do
        rel = Ash.Resource.Info.relationship(resource, name)
        assert length(rel.filters) == 1
        assert inspect(rel.filter) == ~s(name == "#{name}")
      end
    end

    test "keeps the sort option" do
      assert Ash.Resource.Info.relationship(Article, :files).sort == [blob_id: :asc]
    end
  end

  describe "two hosts sharing an attachment resource, with equal ids" do
    test "has_one: a file of one host is not loaded for the other", %{
      article: article,
      profile: profile
    } do
      {:ok, %{blob: blob}} =
        Operations.attach(profile, :image, "profile's", text(filename: "p.txt"))

      article = Ash.load!(article, [:image_url, image: :blob])
      assert article.image == nil
      assert article.image_url == nil

      profile = Ash.load!(profile, [:image_url, image: :blob])
      assert profile.image.blob.id == blob.id
      assert profile.image_url == "http://test.local/storage/#{blob.key}"
    end

    test "has_one: each host loads its own file", %{article: article, profile: profile} do
      {:ok, %{blob: a_blob}} = Operations.attach(article, :image, "a", text(filename: "a.txt"))
      {:ok, %{blob: p_blob}} = Operations.attach(profile, :image, "p", text(filename: "p.txt"))

      assert Ash.load!(article, image: :blob).image.blob.id == a_blob.id
      assert Ash.load!(profile, image: :blob).image.blob.id == p_blob.id
      assert Ash.load!(article, :image_url).image_url == "http://test.local/storage/#{a_blob.key}"
      assert Ash.load!(profile, :image_url).image_url == "http://test.local/storage/#{p_blob.key}"
    end

    test "has_many: files and urls stay with their host", %{article: article, profile: profile} do
      {:ok, %{blob: a1}} = Operations.attach(article, :files, "a1", text(filename: "a1.txt"))
      {:ok, %{blob: p1}} = Operations.attach(profile, :files, "p1", text(filename: "p1.txt"))
      {:ok, %{blob: p2}} = Operations.attach(profile, :files, "p2", text(filename: "p2.txt"))

      article = Ash.load!(article, [:files_urls, :files_count, files: :blob])
      assert Enum.map(article.files, & &1.blob_id) == [a1.id]
      assert article.files_urls == ["http://test.local/storage/#{a1.key}"]
      assert article.files_count == 1

      profile = Ash.load!(profile, [:files_urls, :files_count, files: :blob])
      assert Enum.map(profile.files, & &1.blob_id) == Enum.sort([p1.id, p2.id])
      assert length(profile.files_urls) == 2
      assert profile.files_count == 2
    end

    test "variant urls do not reach the other host's file", %{article: article, profile: profile} do
      {:ok, %{blob: blob}} =
        Operations.attach(profile, :image, "profile's", text(filename: "p.txt"))

      {:ok, _} = Operations.attach(profile, :files, "profile's", text(filename: "f.txt"))

      article = Ash.load!(article, [:image_uppercase_url, :files_uppercase_urls])
      assert article.image_uppercase_url == nil
      assert article.files_uppercase_urls == []

      # reading through the other host generated no variant of the file
      assert Ash.load!(blob, :variants).variants == []

      profile = Ash.load!(profile, [:image_uppercase_url, :files_uppercase_urls])
      assert is_binary(profile.image_uppercase_url)
      assert [url] = profile.files_uppercase_urls
      assert is_binary(url)
    end

    test "filtering through the relationship", %{id: id, profile: profile} do
      {:ok, _} = Operations.attach(profile, :image, "profile's", text(filename: "p.txt"))

      assert [] = Article |> Ash.Query.filter(id == ^id and exists(image, true)) |> Ash.read!()
      assert [_] = Profile |> Ash.Query.filter(id == ^id and exists(image, true)) |> Ash.read!()
    end

    test "the attachment url calculation still resolves the host", %{profile: profile} do
      {:ok, %{blob: blob}} = Operations.attach(profile, :image, "p", text(filename: "p.txt"))
      profile = Ash.load!(profile, image: [:url])
      assert profile.image.url == "http://test.local/storage/#{blob.key}"
    end

    test "purging one host's file leaves the other's", %{article: article, profile: profile} do
      {:ok, %{blob: a_blob}} = Operations.attach(article, :image, "a", text(filename: "a.txt"))
      {:ok, _} = Operations.attach(profile, :image, "p", text(filename: "p.txt"))

      {:ok, _} = Operations.purge(profile, :image)

      assert Ash.load!(profile, :image).image == nil
      assert Ash.load!(article, image: :blob).image.blob.id == a_blob.id
    end
  end

  describe "existing support resources (the reported case)" do
    test "ExtraAttrsPost does not load NoHeadPost's cover_image" do
      id = Ash.UUID.generate()
      post = Ash.Seed.seed!(ExtraAttrsPost, %{id: id, title: "a"})
      other = Ash.Seed.seed!(NoHeadPost, %{id: id, title: "b"})

      {:ok, %{blob: blob}} = Operations.attach(other, :cover_image, "other's", filename: "o.txt")

      post = Ash.load!(post, [:cover_image_url, cover_image: :blob])
      assert post.cover_image == nil
      assert post.cover_image_url == nil

      other = Ash.load!(other, [:cover_image_url, cover_image: :blob])
      assert other.cover_image.record_type == "Elixir.AshStorage.Test.NoHeadPost"
      assert other.cover_image.blob.id == blob.id
      assert is_binary(other.cover_image_url)
    end
  end

  describe "rows stored under another record_type" do
    test "are not loaded", %{article: article} do
      {:ok, %{blob: blob}} = Operations.attach(article, :image, "a", text(filename: "a.txt"))
      [attachment] = Ash.read!(PolymorphicAttachment |> Ash.Query.filter(blob_id == ^blob.id))

      stale = Ash.Seed.update!(attachment, %{record_type: "Elixir.MyApp.RenamedArticle"})

      loaded = Ash.load!(article, [:image, :image_url])
      assert loaded.image == nil
      assert loaded.image_url == nil

      Ash.Seed.update!(stale, %{record_type: AshStorage.Info.record_type(Article)})
      assert Ash.load!(article, :image).image.id == attachment.id
    end
  end
end
