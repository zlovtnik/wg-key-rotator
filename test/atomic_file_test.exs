defmodule WgKeyRotator.AtomicFileTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias WgKeyRotator.AtomicFile

  test "writes files atomically with requested permissions" do
    root = tmp_dir()
    on_exit(fn -> File.rm_rf(root) end)

    path = Path.join(root, "config/server/privatekey-server")

    assert :ok = AtomicFile.write(path, "secret\n", 0o600)
    assert File.read!(path) == "secret\n"
    assert (File.stat!(path).mode &&& 0o777) == 0o600

    assert :ok = AtomicFile.write(path, "replacement\n", 0o644)
    assert File.read!(path) == "replacement\n"
    assert (File.stat!(path).mode &&& 0o777) == 0o644
  end

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "wg-key-rotator-#{System.unique_integer([:positive])}")
  end
end
