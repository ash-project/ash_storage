defmodule AshStorage.Encryption.ScrubbedError do
  @moduledoc false
  # Key-manager / vault exceptions can carry request context or partial
  # secret material in their message or captured arguments. When invocation of a
  # key manager or vault raises, we surface ONLY the exception module plus a
  # normalized code position (module/function/arity/file/line) from the top
  # stack frame. The message is never included, and any captured argument LIST
  # is reduced to its length so argument values never leak.

  @type t :: %{
          module: module(),
          at:
            %{
              module: module(),
              function: atom(),
              arity: non_neg_integer(),
              file: String.t() | nil,
              line: non_neg_integer() | nil
            }
            | nil
        }

  @doc """
  Reduce an exception + stacktrace to a non-sensitive, position-only descriptor.

  Non-exception terms are returned unchanged (callers may already pass a safe value).
  """
  def scrub(exception, stacktrace) when is_exception(exception) do
    %{module: exception.__struct__, at: location(stacktrace)}
  end

  def scrub(other, _stacktrace), do: other

  @doc """
  Reduce an arbitrary term to a non-sensitive *shape* descriptor.

  Used for malformed key-manager / vault return values, which are *returned*
  (not raised) and so never pass through `scrub/2`. A near-miss return shape
  (e.g. `{:ok, dek, meta}` instead of `{:ok, dek}`) can carry a raw DEK, wrapped
  DEK, or plaintext; embedding it verbatim in an error tuple leaks it to any
  caller/logger. This keeps the shape (for debugging) while dropping the bytes:
  binaries collapse to `{:binary, size}`, maps to `{:map, size}`, tuples/lists
  recurse. Atoms/integers/floats are retained as non-secret structural hints.
  """
  def describe_term(term) when is_tuple(term),
    do: {:tuple, term |> Tuple.to_list() |> Enum.map(&describe_term/1)}

  def describe_term(%mod{}), do: {:struct, mod}
  def describe_term(term) when is_map(term), do: {:map, map_size(term)}
  def describe_term(term) when is_list(term), do: {:list, length(term)}
  def describe_term(term) when is_binary(term), do: {:binary, byte_size(term)}
  def describe_term(term) when is_bitstring(term), do: {:bitstring, bit_size(term)}
  def describe_term(term) when is_atom(term), do: term
  def describe_term(term) when is_integer(term), do: term
  def describe_term(term) when is_float(term), do: :float
  def describe_term(_term), do: :term

  defp location([{module, function, arity_or_args, loc} | _]) do
    %{
      module: module,
      function: function,
      arity: if(is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args),
      file: loc |> Keyword.get(:file) |> normalize_file(),
      line: Keyword.get(loc, :line)
    }
  end

  defp location(_stacktrace), do: nil

  defp normalize_file(nil), do: nil
  defp normalize_file(file), do: to_string(file)
end
