defmodule AshStorage.Plug.ResponseMetadata do
  @moduledoc false
  # Response headers shared by the serving plugs: the inline policy, content-type
  # resolution, the `Content-Disposition` value (RFC 6266), `nosniff` and the
  # allowed request methods.

  @type inline_policy :: :none | :images | :documents | [String.t()]
  @type inline_types :: [String.t()]
  @type disposition :: :inline | :attachment

  @default_fallback "application/octet-stream"
  @images ["image/png", "image/jpeg", "image/gif", "image/webp"]
  @documents @images ++ ["application/pdf"]
  @generic_types ["application/octet-stream", "binary/octet-stream"]

  @spec init(keyword()) :: %{inline: inline_types(), content_type_fallback: String.t()}
  def init(opts) do
    %{
      inline: inline_types!(Keyword.get(opts, :inline, :none)),
      content_type_fallback:
        content_type_fallback!(Keyword.get(opts, :content_type_fallback, @default_fallback))
    }
  end

  @spec inline_types!(inline_policy()) :: inline_types()
  def inline_types!(:none), do: []
  def inline_types!(:images), do: @images
  def inline_types!(:documents), do: @documents

  def inline_types!(types) when is_list(types) do
    types
    |> Enum.map(fn type ->
      case normalize_media_type(type) do
        {:ok, type} -> type
        :error -> raise_invalid_inline(types)
      end
    end)
    |> Enum.uniq()
  end

  def inline_types!(other), do: raise_invalid_inline(other)

  defp raise_invalid_inline(value) do
    raise ArgumentError,
          "invalid :inline option #{inspect(value)}. Expected :none, :images, :documents " <>
            ~s(or a list of content types such as ["image/png"])
  end

  defp content_type_fallback!(value) do
    case normalize_media_type(value) do
      {:ok, type} ->
        type

      :error ->
        raise ArgumentError,
              "invalid :content_type_fallback option #{inspect(value)}. " <>
                ~s(Expected a content type such as "application/octet-stream")
    end
  end

  defp normalize_media_type(value) when is_binary(value) do
    type = value |> String.trim() |> String.downcase()

    if media_type?(type), do: {:ok, type}, else: :error
  end

  defp normalize_media_type(_value), do: :error

  defp media_type?(type) do
    Regex.match?(~r{\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\z}, type)
  end

  @spec content_type(keyword()) :: String.t()
  def content_type(sources) do
    # The source order is fixed: callers only say which sources they have.
    declared_type(sources[:declared]) ||
      path_type(sources[:filename]) ||
      path_type(sources[:key]) ||
      declared_type(sources[:stored]) ||
      Keyword.get(sources, :fallback, @default_fallback)
  end

  defp declared_type(value) when is_binary(value) do
    type = base_type(value)

    if media_type?(type) and type not in @generic_types, do: type
  end

  defp declared_type(_value), do: nil

  defp path_type(path) when is_binary(path) and path != "" do
    case MIME.from_path(path) do
      type when type in @generic_types -> nil
      type -> type
    end
  end

  defp path_type(_path), do: nil

  defp base_type(content_type) do
    content_type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  @spec disposition(String.t(), inline_types(), :attachment | nil) :: disposition()
  def disposition(_content_type, _inline_types, :attachment), do: :attachment

  def disposition(content_type, inline_types, nil) do
    if base_type(content_type) in inline_types, do: :inline, else: :attachment
  end

  @spec content_disposition(disposition(), term()) :: String.t()
  def content_disposition(disposition, filename) when disposition in [:inline, :attachment] do
    type = Atom.to_string(disposition)

    case sanitize_filename(filename) do
      nil ->
        type

      name ->
        # `%` is replaced too, so the plain `filename` is never read as percent-encoded.
        fallback = String.replace(name, ~r/[^\x20-\x7E]|%/u, "_")
        value = ~s(#{type}; filename="#{fallback}")

        if fallback == name do
          value
        else
          value <> "; filename*=UTF-8''" <> URI.encode(name, &URI.char_unreserved?/1)
        end
    end
  end

  @spec sanitize_filename(term()) :: String.t() | nil
  def sanitize_filename(filename) when is_binary(filename) do
    if String.valid?(filename) do
      filename
      |> String.replace(~r/[\x00-\x1F\x7F-\x{9F}"\\\/]/u, "")
      |> String.slice(0, 255)
      |> String.trim()
      |> case do
        "" -> nil
        name -> name
      end
    end
  end

  def sanitize_filename(_filename), do: nil

  @spec request_overrides(Plug.Conn.t()) :: %{
          disposition: :attachment | nil,
          filename: String.t() | nil
        }
  def request_overrides(conn) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    # Only an exact "attachment" narrows; any other value, including "inline", is ignored.
    %{
      disposition: if(params["disposition"] == "attachment", do: :attachment),
      filename: sanitize_filename(params["filename"])
    }
  end

  @spec put_nosniff(Plug.Conn.t()) :: Plug.Conn.t()
  def put_nosniff(conn) do
    Plug.Conn.put_resp_header(conn, "x-content-type-options", "nosniff")
  end

  # sobelow_skip ["XSS.ContentType"]
  @spec put_file_headers(Plug.Conn.t(), String.t(), inline_types()) :: Plug.Conn.t()
  def put_file_headers(conn, content_type, inline_types) do
    request = request_overrides(conn)
    disposition = disposition(content_type, inline_types, request.disposition)

    conn
    |> put_nosniff()
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.put_resp_header(
      "content-disposition",
      content_disposition(disposition, request.filename)
    )
  end

  @spec allowed_method?(Plug.Conn.t()) :: boolean()
  def allowed_method?(conn), do: conn.method in ["GET", "HEAD"]

  @spec method_not_allowed(Plug.Conn.t()) :: Plug.Conn.t()
  def method_not_allowed(conn) do
    conn
    |> put_nosniff()
    |> Plug.Conn.put_resp_header("allow", "GET, HEAD")
    |> Plug.Conn.send_resp(405, "Method Not Allowed")
    |> Plug.Conn.halt()
  end
end
