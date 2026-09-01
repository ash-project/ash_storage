defmodule AshStorage.Plug.ResponseMetadata do
  @moduledoc """
  Resolves response metadata for AshStorage serving plugs.

  Storage keys are sometimes opaque or transformed, so blob-aware serving should
  prefer durable blob metadata before falling back to path suffixes. Query
  parameters remain presentation hints for `Content-Disposition`; they are not
  treated as authoritative MIME metadata.
  """

  @generic_content_types [nil, "", "application/octet-stream", "binary/octet-stream"]

  @inline_images ~w(image/png image/jpeg image/gif image/webp)
  @inline_documents @inline_images ++ ~w(application/pdf)

  @doc """
  Resolve the `Content-Type` header for a response.

  Meaningful blob `content_type` values win. Otherwise, blob filename suffixes
  are used when a blob is available, then the storage key/path suffix, then the
  configured fallback.
  """
  def content_type(path, opts \\ []) do
    blob = Keyword.get(opts, :blob)
    fallback = Keyword.get(opts, :fallback, "application/octet-stream")

    cond do
      meaningful_content_type?(blob_content_type(blob)) ->
        blob_content_type(blob)

      content_type = path_content_type(blob_filename(blob)) ->
        content_type

      content_type = path_content_type(path) ->
        content_type

      true ->
        fallback
    end
  end

  @doc """
  Resolve an inline-disposition policy to the set of content types that may be
  served inline.

  Accepts a built-in atom, an explicit list of content types, or an
  already-built `MapSet` (returned as-is, so a route can resolve once at
  `init/1` and reuse it per request):

    * `:none` — nothing inline; every response is `attachment`.
    * `:images` — raster images (`image/png`, `image/jpeg`, `image/gif`,
      `image/webp`). The serving plugs default to this.
    * `:documents` — `:images` plus `application/pdf`.
    * a list, e.g. `["image/png", "application/pdf"]` — exactly those types.

  `image/svg+xml` is deliberately in **no** built-in set: a declared SVG served
  inline executes embedded script in the serving origin, which `nosniff` cannot
  prevent (unlike a PDF, which renders in the browser's sandboxed viewer). A
  route that truly needs inline SVG must list it explicitly and accept the risk.
  """
  def inline_content_types(:none), do: MapSet.new()
  def inline_content_types(:images), do: MapSet.new(@inline_images)
  def inline_content_types(:documents), do: MapSet.new(@inline_documents)
  def inline_content_types(%MapSet{} = set), do: set

  def inline_content_types(types) when is_list(types),
    do: types |> Enum.map(&normalize_content_type/1) |> MapSet.new()

  @doc """
  Add a `Content-Disposition` header, driven by a content-type allowlist.

  A response is served `inline` only when its resolved `:content_type` is in the
  route's inline policy (`:inline` — an atom/list/`MapSet`, see
  `inline_content_types/1`; defaults to `:none`). So a caller-influenced
  `text/html` or `image/svg+xml` is never rendered inline through the
  application origin — a stored-XSS vector — while raster images (and, under
  `:documents`, PDFs) preview as expected.

  The request may narrow toward safety but never widen it: `?disposition=attachment`
  always forces a download (e.g. a "Download" control for an otherwise-inline
  PDF), and `?disposition=inline` is ignored for any type not in the policy. The
  `filename` query parameter is a presentation hint, falling back to
  `blob.filename`.
  """
  def put_content_disposition(conn, opts \\ []) do
    params = Plug.Conn.fetch_query_params(conn).query_params
    inline_types = inline_content_types(Keyword.get(opts, :inline, :none))
    content_type = Keyword.get(opts, :content_type)
    blob = Keyword.get(opts, :blob)
    filename = params["filename"] || blob_filename(blob)

    disposition =
      cond do
        params["disposition"] == "attachment" -> "attachment"
        inline_content_type?(content_type, inline_types) -> "inline"
        true -> "attachment"
      end

    Plug.Conn.put_resp_header(
      conn,
      "content-disposition",
      disposition(disposition, filename)
    )
  end

  defp inline_content_type?(content_type, inline_types) when is_binary(content_type),
    do: MapSet.member?(inline_types, normalize_content_type(content_type))

  defp inline_content_type?(_content_type, _inline_types), do: false

  # content_type may carry parameters (`image/png; charset=binary`) or casing.
  defp normalize_content_type(content_type),
    do: content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

  @doc """
  Set `X-Content-Type-Options: nosniff` so intermediaries/browsers do not
  MIME-sniff a response into an active content type.
  """
  def put_nosniff(conn) do
    Plug.Conn.put_resp_header(conn, "x-content-type-options", "nosniff")
  end

  defp meaningful_content_type?(content_type), do: content_type not in @generic_content_types

  defp path_content_type(path) when is_binary(path) and path != "", do: MIME.from_path(path)
  defp path_content_type(_path), do: nil

  defp blob_content_type(blob) when is_map(blob), do: Map.get(blob, :content_type)
  defp blob_content_type(_blob), do: nil

  defp blob_filename(blob) when is_map(blob), do: Map.get(blob, :filename)
  defp blob_filename(_blob), do: nil

  defp disposition(disposition, filename) when is_binary(filename) and filename != "" do
    ~s(#{disposition}; filename="#{safe_filename(filename)}")
  end

  defp disposition(disposition, _filename), do: disposition

  defp safe_filename(filename) do
    String.replace(filename, ~r/[\r\n"]/, "_")
  end
end
