Logger.configure(level: :info)

# -- Start MinIO via Docker --

minio_port = 19_000
minio_container = "ash_storage_dev_minio"
minio_bucket = "ash-storage-dev"

docker =
  System.find_executable("docker") ||
    raise """
    Docker is required for the dev server (MinIO for S3).
    Install Docker or make sure it's on your PATH.
    """

# Stop any leftover container
System.cmd(docker, ["rm", "-f", minio_container], stderr_to_stdout: true)

# Start MinIO
{_, 0} =
  System.cmd(docker, [
    "run", "-d",
    "--name", minio_container,
    "-p", "#{minio_port}:9000",
    "-p", "19001:9001",
    "-e", "MINIO_ROOT_USER=minioadmin",
    "-e", "MINIO_ROOT_PASSWORD=minioadmin",
    "minio/minio", "server", "/data", "--console-address", ":9001"
  ])

# Wait for MinIO to be ready
minio_url = "http://localhost:#{minio_port}"

Enum.reduce_while(1..30, nil, fn _, _ ->
  case Req.get("#{minio_url}/minio/health/ready") do
    {:ok, %{status: 200}} -> {:halt, :ok}
    _ -> Process.sleep(1000); {:cont, nil}
  end
end) || raise "MinIO failed to start"

# Create the bucket
sigv4_opts = [
  service: :s3,
  region: "us-east-1",
  access_key_id: "minioadmin",
  secret_access_key: "minioadmin"
]

case Req.put("#{minio_url}/#{minio_bucket}", aws_sigv4: sigv4_opts, body: "") do
  {:ok, %{status: status}} when status in [200, 409] -> :ok
  other -> raise "Failed to create bucket: #{inspect(other)}"
end

IO.puts("MinIO started at #{minio_url} with bucket '#{minio_bucket}'")

# -- Phoenix config --

Application.put_env(:ash_storage, DemoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4002],
  server: true,
  live_view: [signing_salt: "aaaaaaaaaaaaaaaa"],
  secret_key_base: String.duplicate("a", 64),
  debug_errors: true,
  check_origin: false,
  pubsub_server: Demo.PubSub,
  watchers: [],
  live_reload: [
    patterns: [~r"dev/.*(ex)$", ~r"lib/.*(ex)$"]
  ]
)

defmodule DemoWeb.Layouts do
  use Phoenix.Component

  def render("root.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>AshStorage Demo</title>
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <script src="https://cdn.tailwindcss.com">
        </script>
        <script src="/assets/phoenix/phoenix.min.js">
        </script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {params: {_csrf_token: csrfToken}})
          liveSocket.connect()
        </script>
      </head>
      <body class="bg-gray-50 min-h-screen">
        {@inner_content}
      </body>
    </html>
    """
  end

  def render("app.html", assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4">
      <h1 class="text-3xl font-bold text-gray-900 mb-2">AshStorage Demo</h1>
      <p class="text-gray-500 mb-8">File attachments with Ash Framework</p>
      <.live_flash_group flash={@flash} />
      {@inner_content}
    </div>
    """
  end

  attr :flash, :map, required: true

  defp live_flash_group(assigns) do
    ~H"""
    <div :for={{kind, msg} <- @flash} class={"mb-4 p-3 rounded #{flash_class(kind)}"}>
      {msg}
    </div>
    """
  end

  defp flash_class("info"), do: "bg-blue-100 text-blue-800"
  defp flash_class("error"), do: "bg-red-100 text-red-800"
  defp flash_class(_), do: "bg-gray-100 text-gray-800"
end

defmodule DemoWeb.HomeLive do
  use Phoenix.LiveView, layout: {DemoWeb.Layouts, :app}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Demo.PubSub, "blob_analysis")
    end

    socket =
      socket
      |> assign(
        posts: load_records(Demo.Post),
        pages: load_records(Demo.Page),
        post_form: AshPhoenix.Form.for_create(Demo.Post, :create) |> to_form(),
        page_form: AshPhoenix.Form.for_create(Demo.Page, :create) |> to_form()
      )
      |> allow_upload(:post_cover, accept: :any, max_entries: 1)
      |> allow_upload(:post_docs, accept: :any, max_entries: 5)
      |> allow_upload(:page_cover, accept: :any, max_entries: 1)
      |> allow_upload(:page_docs, accept: :any, max_entries: 5)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
      <%!-- S3 (MinIO) Column --%>
      <div class="space-y-6">
        <div class="bg-blue-50 border border-blue-200 rounded-lg p-3">
          <h2 class="text-lg font-bold text-blue-900">S3 Service (MinIO)</h2>
          <p class="text-xs text-blue-600">Files stored in MinIO S3 bucket &middot; Presigned URLs</p>
          <p class="text-xs text-blue-500 mt-1">Analyzers: FileInfo + ImageDimensions (both eager)</p>
        </div>

        <.create_form
          form={@post_form}
          cover_upload={@uploads.post_cover}
          docs_upload={@uploads.post_docs}
          submit_event="create_post"
          validate_event="validate_post"
          cancel_prefix="post"
        />

        <.record_list
          records={@posts}
          kind="post"
          empty_msg="No S3 posts yet."
        />
      </div>

      <%!-- Disk Column --%>
      <div class="space-y-6">
        <div class="bg-green-50 border border-green-200 rounded-lg p-3">
          <h2 class="text-lg font-bold text-green-900">Disk Service</h2>
          <p class="text-xs text-green-600">Files stored on local filesystem &middot; Signed URLs</p>
          <p class="text-xs text-green-500 mt-1">Analyzers: FileInfo (eager) + ImageDimensions (oban)</p>
        </div>

        <.create_form
          form={@page_form}
          cover_upload={@uploads.page_cover}
          docs_upload={@uploads.page_docs}
          submit_event="create_page"
          validate_event="validate_page"
          cancel_prefix="page"
        />

        <.record_list
          records={@pages}
          kind="page"
          empty_msg="No Disk pages yet."
        />
      </div>
    </div>
    """
  end

  # -- PubSub --

  @impl true
  def handle_info({:analysis_complete, _blob}, socket) do
    {:noreply,
     socket
     |> assign(posts: load_records(Demo.Post), pages: load_records(Demo.Page))
     |> put_flash(:info, "Background analysis completed!")}
  end

  # -- Components --

  attr :form, :any, required: true
  attr :cover_upload, :any, required: true
  attr :docs_upload, :any, required: true
  attr :submit_event, :string, required: true
  attr :validate_event, :string, required: true
  attr :cancel_prefix, :string, required: true

  defp create_form(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <.form for={@form} phx-submit={@submit_event} phx-change={@validate_event} class="space-y-3">
        <div>
          <label class="block text-sm font-medium text-gray-700">Title</label>
          <input
            type="text"
            name={@form[:title].name}
            value={@form[:title].value}
            class="mt-1 block w-full rounded border-gray-300 shadow-sm px-3 py-2 border text-sm"
          />
          <.errors field={@form[:title]} />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Cover Image</label>
          <.live_file_input upload={@cover_upload} class="block w-full text-xs file:mr-2 file:py-1 file:px-3 file:rounded file:border-0 file:text-xs file:font-semibold file:bg-blue-50 file:text-blue-700" />
          <div :for={entry <- @cover_upload.entries} class="mt-1 text-xs text-gray-600 flex items-center gap-2">
            <.live_img_preview entry={entry} class="h-12 rounded" />
            <span>{entry.client_name}</span>
            <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref} phx-value-upload={"#{@cancel_prefix}_cover"} class="text-red-500">&times;</button>
          </div>
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Documents</label>
          <.live_file_input upload={@docs_upload} class="block w-full text-xs file:mr-2 file:py-1 file:px-3 file:rounded file:border-0 file:text-xs file:font-semibold file:bg-blue-50 file:text-blue-700" />
          <div :for={entry <- @docs_upload.entries} class="mt-1 text-xs text-gray-600 flex items-center gap-2">
            <span>{entry.client_name}</span>
            <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref} phx-value-upload={"#{@cancel_prefix}_docs"} class="text-red-500">&times;</button>
          </div>
        </div>

        <button type="submit" class="bg-green-600 text-white px-3 py-1.5 rounded text-sm hover:bg-green-700">
          Create
        </button>
      </.form>
    </div>
    """
  end

  attr :records, :list, required: true
  attr :kind, :string, required: true
  attr :empty_msg, :string, required: true

  defp record_list(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <div :if={@records == []} class="text-gray-400 text-center py-4 text-sm">
        {@empty_msg}
      </div>

      <div :for={record <- @records} class="border rounded p-3 mb-3 last:mb-0">
        <div class="flex items-start justify-between">
          <div>
            <h3 class="font-medium text-sm">{record.title}</h3>
            <p class="text-[10px] text-gray-400 font-mono">{record.id}</p>
          </div>
          <button phx-click={"delete_#{@kind}"} phx-value-id={record.id} class="text-red-500 hover:text-red-700 text-xs">
            Delete
          </button>
        </div>

        <div class="mt-2">
          <span class="text-xs font-medium text-gray-500">Cover Image</span>
          <div :if={record.cover_image} class="mt-1">
            <div class="flex items-center gap-2">
              <a href={record.cover_image_url} target="_blank" class="text-blue-600 hover:underline text-xs">
                {record.cover_image.blob.filename}
              </a>
              <span class="text-[10px] text-gray-400">
                {record.cover_image.blob.content_type} &middot; {format_bytes(record.cover_image.blob.byte_size)}
              </span>
              <button phx-click={"purge_#{@kind}"} phx-value-id={record.id} phx-value-attachment="cover_image" class="text-red-400 hover:text-red-600 text-[10px]">
                Remove
              </button>
            </div>
            <div :if={String.starts_with?(record.cover_image.blob.content_type || "", "image/")} class="mt-1">
              <img src={record.cover_image_url} class="h-24 rounded shadow" />
            </div>
            <.blob_analysis blob={record.cover_image.blob} />
          </div>
          <p :if={is_nil(record.cover_image)} class="text-[10px] text-gray-400 mt-1">None</p>
        </div>

        <div class="mt-2">
          <span class="text-xs font-medium text-gray-500">Documents</span>
          <ul :if={record.documents != []} class="mt-1 space-y-1">
            <li :for={doc <- record.documents}>
              <div class="flex items-center gap-2">
                <a href={url_for(record, doc)} target="_blank" class="text-blue-600 hover:underline text-xs">
                  {doc.blob.filename}
                </a>
                <span class="text-[10px] text-gray-400">
                  {format_bytes(doc.blob.byte_size)}
                </span>
                <button
                  phx-click={"purge_#{@kind}_doc"}
                  phx-value-record-id={record.id}
                  phx-value-blob-id={doc.blob_id}
                  class="text-red-400 hover:text-red-600 text-[10px]"
                >
                  Remove
                </button>
              </div>
              <.blob_analysis blob={doc.blob} />
            </li>
          </ul>
          <p :if={record.documents == []} class="text-[10px] text-gray-400 mt-1">None</p>
        </div>
      </div>
    </div>
    """
  end

  attr :blob, :any, required: true

  defp blob_analysis(assigns) do
    ~H"""
    <div :if={@blob.metadata != %{} or @blob.analyzers != %{}} class="mt-1 ml-2 p-2 bg-gray-50 rounded text-[10px]">
      <%!-- Metadata --%>
      <div :if={@blob.metadata != %{}} class="mb-1">
        <span class="font-semibold text-gray-600">Metadata:</span>
        <span :for={{k, v} <- @blob.metadata} class="ml-1 inline-block bg-white border rounded px-1">
          {k}={inspect(v)}
        </span>
      </div>
      <%!-- Analyzer statuses --%>
      <div :if={@blob.analyzers != %{}}>
        <span class="font-semibold text-gray-600">Analyzers:</span>
        <div :for={{mod, info} <- @blob.analyzers} class="ml-1 mt-0.5 flex items-center gap-1">
          <span class={"inline-block w-2 h-2 rounded-full #{status_color(info["status"])}"} />
          <span class="font-mono">{short_module(mod)}</span>
          <span class="text-gray-400">{info["status"]}</span>
          <span :if={info["status"] == "pending"} class="text-yellow-600 animate-pulse">analyzing...</span>
        </div>
      </div>
    </div>
    """
  end

  defp status_color("complete"), do: "bg-green-500"
  defp status_color("pending"), do: "bg-yellow-400"
  defp status_color("error"), do: "bg-red-500"
  defp status_color("skipped"), do: "bg-gray-400"
  defp status_color(_), do: "bg-gray-300"

  defp errors(assigns) do
    ~H"""
    <div :for={error <- @field.errors} class="text-red-600 text-xs mt-1">
      {translate_error(error)}
    </div>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  # -- Events --

  @impl true
  def handle_event("validate_post", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.post_form.source, params) |> to_form()
    {:noreply, assign(socket, post_form: form)}
  end

  def handle_event("validate_page", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.page_form.source, params) |> to_form()
    {:noreply, assign(socket, page_form: form)}
  end

  def handle_event("cancel_upload", %{"ref" => ref, "upload" => upload}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}
  end

  def handle_event("create_post", %{"form" => params}, socket) do
    handle_create(socket, :post_form, Demo.Post, params, :post_cover, :post_docs)
  end

  def handle_event("create_page", %{"form" => params}, socket) do
    handle_create(socket, :page_form, Demo.Page, params, :page_cover, :page_docs)
  end

  def handle_event("delete_post", %{"id" => id}, socket) do
    Ash.get!(Demo.Post, id) |> Ash.destroy!()
    {:noreply, socket |> assign(posts: load_records(Demo.Post)) |> put_flash(:info, "Post deleted")}
  end

  def handle_event("delete_page", %{"id" => id}, socket) do
    Ash.get!(Demo.Page, id) |> Ash.destroy!()
    {:noreply, socket |> assign(pages: load_records(Demo.Page)) |> put_flash(:info, "Page deleted")}
  end

  def handle_event("purge_post", %{"id" => id, "attachment" => name}, socket) do
    handle_purge(socket, Demo.Post, id, String.to_existing_atom(name), :posts)
  end

  def handle_event("purge_page", %{"id" => id, "attachment" => name}, socket) do
    handle_purge(socket, Demo.Page, id, String.to_existing_atom(name), :pages)
  end

  def handle_event("purge_post_doc", %{"record-id" => id, "blob-id" => blob_id}, socket) do
    handle_purge_doc(socket, Demo.Post, id, blob_id, :posts)
  end

  def handle_event("purge_page_doc", %{"record-id" => id, "blob-id" => blob_id}, socket) do
    handle_purge_doc(socket, Demo.Page, id, blob_id, :pages)
  end

  # -- Helpers --

  defp handle_create(socket, form_key, resource, params, cover_upload, docs_upload) do
    case AshPhoenix.Form.submit(socket.assigns[form_key].source, params: params) do
      {:ok, record} ->
        consume_uploaded_entries(socket, cover_upload, fn %{path: path}, entry ->
          data = File.read!(path)
          AshStorage.Operations.attach(record, :cover_image, data,
            filename: entry.client_name, content_type: entry.client_type)
        end)

        consume_uploaded_entries(socket, docs_upload, fn %{path: path}, entry ->
          data = File.read!(path)
          AshStorage.Operations.attach(record, :documents, data,
            filename: entry.client_name, content_type: entry.client_type)
        end)

        new_form = AshPhoenix.Form.for_create(resource, :create) |> to_form()
        assign_key = if resource == Demo.Post, do: :posts, else: :pages

        {:noreply,
         socket
         |> assign([{form_key, new_form}, {assign_key, load_records(resource)}])
         |> put_flash(:info, "#{inspect(resource)} created!")}

      {:error, form} ->
        {:noreply, assign(socket, [{form_key, to_form(form)}])}
    end
  end

  defp handle_purge(socket, resource, id, attachment_name, assign_key) do
    record = Ash.get!(resource, id)
    AshStorage.Operations.purge(record, attachment_name)

    {:noreply,
     socket
     |> assign([{assign_key, load_records(resource)}])
     |> put_flash(:info, "Attachment removed")}
  end

  defp handle_purge_doc(socket, resource, id, blob_id, assign_key) do
    record = Ash.get!(resource, id)
    AshStorage.Operations.purge(record, :documents, blob_id: blob_id)

    {:noreply,
     socket
     |> assign([{assign_key, load_records(resource)}])
     |> put_flash(:info, "Document removed")}
  end

  defp short_module(mod_string) do
    mod_string
    |> String.replace("Elixir.", "")
    |> String.split(".")
    |> List.last()
  end

  defp load_records(resource) do
    resource
    |> Ash.read!()
    |> Ash.load!([
      :cover_image_url,
      :documents_urls,
      cover_image: :blob,
      documents: :blob
    ])
  end

  defp url_for(record, doc) do
    urls = record.documents_urls || []
    docs = record.documents || []
    idx = Enum.find_index(docs, &(&1.id == doc.id))
    if idx, do: Enum.at(urls, idx), else: "#"
  end

  defp format_bytes(nil), do: "?"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end

defmodule DemoWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser

    live "/", DemoWeb.HomeLive
  end

  forward "/s3_files", AshStorage.Plug.Proxy,
    service:
      {AshStorage.Service.S3,
       bucket: "ash-storage-dev",
       region: "us-east-1",
       access_key_id: "minioadmin",
       secret_access_key: "minioadmin",
       endpoint_url: "http://localhost:19000"}

  forward "/disk_files", AshStorage.Plug.DiskServe,
    root: "tmp/dev_storage",
    secret: "dev-secret-key-for-signed-urls!!",
    inline: :images
end

defmodule DemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ash_storage

  socket "/live", Phoenix.LiveView.Socket

  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"}

  plug Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"}

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.Session,
    store: :cookie,
    key: "_ash_storage_dev",
    signing_salt: "aaaaaaaaaaaaaaaa"

  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], json_decoder: Jason
  plug Plug.MethodOverride
  plug Plug.Head
  plug DemoWeb.Router
end

File.mkdir_p!("tmp/dev_storage")

Application.put_env(:phoenix, :serve_endpoints, true)

Task.start(fn ->
  oban_config =
    AshOban.config([Demo.Domain], Application.fetch_env!(:ash_storage, :oban))

  children = [
    Demo.Repo,
    {Oban, oban_config},
    {Phoenix.PubSub, name: Demo.PubSub},
    DemoWeb.Endpoint
  ]

  {:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)
  Process.sleep(:infinity)
end)

# Clean up MinIO on shutdown
System.at_exit(fn _ ->
  docker = System.find_executable("docker")
  if docker, do: System.cmd(docker, ["rm", "-f", minio_container], stderr_to_stdout: true)
end)
