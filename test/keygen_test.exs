defmodule WgKeyRotator.KeygenTest do
  use ExUnit.Case, async: true

  alias WgKeyRotator.Keygen

  @private_key Base.encode64(:binary.copy(<<1>>, 32))
  @public_key Base.encode64(:binary.copy(<<2>>, 32))

  test "generates and derives a WireGuard keypair with wg" do
    runner = fn
      "wg", ["genkey"], opts ->
        assert opts[:stderr_to_stdout]
        {@private_key <> "\n", 0}

      "wg", ["pubkey"], opts ->
        assert opts[:input] == @private_key <> "\n"
        {@public_key <> "\n", 0}
    end

    assert {:ok, %{private_key: @private_key, public_key: @public_key}} = Keygen.generate(runner)
  end

  test "rejects malformed generated keys" do
    runner = fn
      "wg", ["genkey"], _opts -> {"not-a-key\n", 0}
    end

    assert {:error, error} = Keygen.generate(runner)
    assert error.step == :private_key
  end
end
