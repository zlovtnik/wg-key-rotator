defmodule WgKeyRotator.KeygenTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias WgKeyRotator.Keygen

  @private_key Base.encode64(:binary.copy(<<1>>, 32))
  @public_key Base.encode64(:binary.copy(<<2>>, 32))

  test "generates and derives a WireGuard keypair with wg" do
    test_pid = self()

    runner = fn
      "wg", ["genkey"], opts ->
        assert opts[:stderr_to_stdout]
        {@private_key <> "\n", 0}

      "sh", ["-c", cmd], opts ->
        assert opts[:stderr_to_stdout]
        assert "wg pubkey < '" <> quoted_path = cmd
        assert String.ends_with?(quoted_path, "'")

        path = String.trim_trailing(quoted_path, "'")
        assert Path.basename(path) =~ ~r/^wgk-[A-Za-z0-9_-]+$/
        assert File.read!(path) == @private_key <> "\n"
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        send(test_pid, {:tmp_path, path})

        {@public_key <> "\n", 0}
    end

    assert {:ok, %{private_key: @private_key, public_key: @public_key}} = Keygen.generate(runner)
    assert_receive {:tmp_path, tmp_path}
    refute File.exists?(tmp_path)
  end

  test "rejects malformed generated keys" do
    runner = fn
      "wg", ["genkey"], _opts -> {"not-a-key\n", 0}
    end

    assert {:error, error} = Keygen.generate(runner)
    assert error.step == :private_key
  end
end
