defmodule WgKeyRotator.CommandTest do
  use ExUnit.Case, async: true

  alias WgKeyRotator.Command

  test "system runner returns an error when a command exceeds its timeout" do
    assert {:error, error} =
             Command.run(
               &Command.system_runner/3,
               "sleep",
               ["5"],
               [timeout_ms: 50],
               :timeout_check
             )

    assert error.step == :timeout_check
    assert error.message == "failed to run sleep"
    assert error.details =~ "sleep 5 timed out after 50ms"
  end

  test "system runner preserves command output when the command completes before timeout" do
    assert {:ok, "started"} =
             Command.run(
               &Command.system_runner/3,
               "printf",
               ["started"],
               [timeout_ms: 1_000],
               :output_check
             )
  end
end
