defmodule AshStorage.LayerTest do
  use ExUnit.Case, async: true

  alias AshStorage.Layer

  defmodule DefaultKeyLayer do
    @behaviour Layer

    @impl true
    # Returns the *default* only; the framework applies any configured override.
    def default_metadata_key(opts), do: Keyword.get(opts, :scope, "default-key")
  end

  describe "layer_metadata_key/1" do
    test "falls back to the layer's default_metadata_key/1 when unconfigured" do
      assert Layer.layer_metadata_key(DefaultKeyLayer) == "default-key"
      assert Layer.layer_metadata_key({DefaultKeyLayer, []}) == "default-key"
    end

    test "a default may be derived from opts" do
      assert Layer.layer_metadata_key({DefaultKeyLayer, scope: "derived"}) == "derived"
    end

    test "a configured :layer_metadata_key always overrides the default" do
      assert Layer.layer_metadata_key({DefaultKeyLayer, layer_metadata_key: "configured"}) ==
               "configured"

      # The override wins even when the default would have derived another value.
      assert Layer.layer_metadata_key(
               {DefaultKeyLayer, scope: "derived", layer_metadata_key: "configured"}
             ) == "configured"
    end

    test "coerces the resolved key to a string" do
      assert Layer.layer_metadata_key({DefaultKeyLayer, layer_metadata_key: :atom_key}) ==
               "atom_key"
    end
  end
end
