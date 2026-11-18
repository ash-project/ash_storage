defmodule AshStorage.Plug.ServingDefaultsTest do
  # Mutates application config; keep it out of the async pool.
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshStorage.Operations
  alias AshStorage.Plug.DiskServe
  alias AshStorage.Test.ConfigurablePost

  @root Path.join(System.tmp_dir!(), "ash_storage_serving_defaults")
  @script "<script>alert(document.domain)</script>"

  setup do
    File.rm_rf!(@root)

    Application.put_env(:ash_storage, ConfigurablePost,
      storage: [service: {AshStorage.Service.Disk, root: @root, base_url: "/files"}]
    )

    on_exit(fn ->
      Application.delete_env(:ash_storage, ConfigurablePost)
      File.rm_rf!(@root)
    end)
  end

  # Uploads a script under the given filename, claiming it is an image, and
  # serves it through the URL the resource hands out.
  defp serve_upload(filename, plug_opts) do
    post =
      ConfigurablePost
      |> Ash.Changeset.for_create(:create, %{title: "upload"})
      |> Ash.create!()

    {:ok, _} =
      Operations.attach(post, :avatar, @script, filename: filename, content_type: "image/png")

    %{avatar_url: "/files" <> path} = Ash.load!(post, :avatar_url)

    conn(:get, path)
    |> DiskServe.call(DiskServe.init([root: @root] ++ plug_opts))
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "an uploaded HTML file is served as a download" do
    conn = serve_upload("evil.html", [])

    assert conn.status == 200
    assert conn.resp_body == @script
    assert header(conn, "content-type") =~ "text/html"
    assert header(conn, "content-disposition") == "attachment"
    assert header(conn, "x-content-type-options") == "nosniff"
  end

  test "an uploaded SVG file is served as a download on an images mount" do
    conn = serve_upload("evil.svg", inline: :images)

    assert conn.status == 200
    assert header(conn, "content-type") =~ "image/svg+xml"
    assert header(conn, "content-disposition") == "attachment"
  end
end
