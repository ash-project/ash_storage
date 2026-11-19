defmodule AshStorage.Key do
  @moduledoc """
  A storage key uniquely names a file managed by a storage service.

  This module implements the rules a storage key must follow, and provides APIs for validating them.

  The `validate/1` API is what determines whether a key may be stored. It runs after the key for
  an attachment or variant has been resolved, before anything is uploaded and before a blob record
  is created.

  A key is made of segments separated by `/`, and a segment may contain only ASCII letters, digits,
  `.`, `_` and `-`, and must not end with `.`.

  A valid key also:

  - is between 1 and 1024 bytes long;
  - is relative: it does not start or end with `/`;
  - has no empty segment (`a//b`), no `.` segment and no `..` segment.

  A key is never rewritten: one that breaks a rule is rejected.

  Use `validate/1` in a test to check what an attachment's `path` function returns. See
  [Storage keys](storage-keys.md).
  """

  @max_bytes 1024

  @typedoc "Why a key was rejected."
  @type reason ::
          :not_a_binary
          | :empty
          | :too_long
          | :invalid_character
          | :absolute
          | :trailing_slash
          | :parent_segment
          | :empty_segment
          | :dot_segment
          | :trailing_dot

  @typedoc """
  The error term. The last element is the rejected value. When the tenant
  that would prefix a key is rejected, the reason is `{:tenant, reason}` and
  the value is the tenant.
  """
  @type error ::
          {:invalid_storage_key, reason() | {:tenant, reason() | :separator}, term()}

  @doc """
  Checks a key that is about to be stored.

      iex> AshStorage.Key.validate("org-1/covers/3f9a")
      :ok

      iex> AshStorage.Key.validate("../etc/passwd")
      {:error, {:invalid_storage_key, :parent_segment, "../etc/passwd"}}

      iex> AshStorage.Key.validate("/covers/3f9a")
      {:error, {:invalid_storage_key, :absolute, "/covers/3f9a"}}

      iex> AshStorage.Key.validate("covers/my photo.png")
      {:error, {:invalid_storage_key, :invalid_character, "covers/my photo.png"}}
  """
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(key), do: result(check(key), key)

  # The check the serving plugs apply to a key taken from a request. It only
  # refuses what could reach outside the store: an empty key, an ASCII control
  # character, an absolute path, and a `..` segment, with `\` counted as a
  # separator as well. Everything else, including characters outside the set
  # that `validate/1` allows, is left to the service, so that files stored
  # before `validate/1` existed can still be served.
  @doc false
  @spec validate_lookup(term()) :: :ok | {:error, error()}
  def validate_lookup(key), do: result(check_lookup(key), key)

  # A tenant becomes the first segment of a key, so it has to be one valid segment.
  @doc false
  @spec validate_tenant(term()) :: :ok | {:error, error()}
  def validate_tenant(tenant) do
    reason =
      if is_binary(tenant) and String.contains?(tenant, "/"),
        do: :separator,
        else: check(tenant)

    case reason do
      :ok -> :ok
      reason -> {:error, {:invalid_storage_key, {:tenant, reason}, tenant}}
    end
  end

  defp result(:ok, _key), do: :ok
  defp result(reason, key), do: {:error, {:invalid_storage_key, reason, key}}

  defp check(key) when not is_binary(key), do: :not_a_binary
  defp check(""), do: :empty
  defp check(key) when byte_size(key) > @max_bytes, do: :too_long

  defp check(key) do
    cond do
      # Works on bytes: every byte of a non-ASCII character is outside the set.
      not String.match?(key, ~r/\A[A-Za-z0-9._\/-]+\z/) -> :invalid_character
      String.starts_with?(key, "/") -> :absolute
      String.ends_with?(key, "/") -> :trailing_slash
      true -> check_segments(String.split(key, "/"))
    end
  end

  defp check_segments(segments) do
    cond do
      ".." in segments -> :parent_segment
      "" in segments -> :empty_segment
      "." in segments -> :dot_segment
      Enum.any?(segments, &String.ends_with?(&1, ".")) -> :trailing_dot
      true -> :ok
    end
  end

  defp check_lookup(key) when not is_binary(key), do: :not_a_binary
  defp check_lookup(""), do: :empty

  defp check_lookup(key) do
    cond do
      String.match?(key, ~r/[\x00-\x1F\x7F]/) -> :invalid_character
      String.starts_with?(key, ["/", "\\"]) -> :absolute
      ".." in String.split(key, ["/", "\\"]) -> :parent_segment
      true -> :ok
    end
  end
end
