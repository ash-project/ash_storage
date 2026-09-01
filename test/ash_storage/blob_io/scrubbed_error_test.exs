defmodule AshStorage.Encryption.ScrubbedErrorTest do
  use ExUnit.Case, async: true

  alias AshStorage.Encryption.ScrubbedError

  test "captures the exception module + code position, never the message" do
    {exception, stacktrace} =
      try do
        raise ArgumentError, "vault said: token=s3cr3t-do-not-leak"
      rescue
        e -> {e, __STACKTRACE__}
      end

    scrubbed = ScrubbedError.scrub(exception, stacktrace)

    assert scrubbed.module == ArgumentError
    assert %{module: _, function: _, arity: arity, file: file, line: line} = scrubbed.at
    assert is_integer(arity)
    assert is_binary(file)
    assert is_integer(line)

    # The sensitive message must not appear anywhere in the scrubbed term.
    refute inspect(scrubbed) =~ "s3cr3t"
  end

  test "a top frame carrying args is reduced to arity so values never leak" do
    # Some errors (e.g. FunctionClauseError) capture the actual args in the frame.
    frame = {SomeModule, :unwrap, ["secret-key-material"], [file: ~c"km.ex", line: 7]}

    scrubbed = ScrubbedError.scrub(%RuntimeError{message: "boom"}, [frame])

    assert scrubbed.at.arity == 1
    refute inspect(scrubbed) =~ "secret-key-material"
  end

  test "passes non-exception terms through unchanged" do
    assert ScrubbedError.scrub({:already, :safe}, []) == {:already, :safe}
  end
end
