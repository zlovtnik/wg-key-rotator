defmodule WgKeyRotator.Keygen do
  alias WgKeyRotator.{Command, Error}

  @key_bytes 32

  def generate(runner \\ &Command.system_runner/3) do
    with {:ok, private_key} <- genkey(runner),
         :ok <- validate_key(private_key, :private_key),
         {:ok, public_key} <- pubkey(runner, private_key),
         :ok <- validate_key(public_key, :public_key) do
      {:ok, %{private_key: private_key, public_key: public_key}}
    end
  end

  def generate_psk(runner \\ &Command.system_runner/3) do
    runner
    |> Command.run("wg", ["genpsk"], [stderr_to_stdout: true], :preshared_key_generation)
    |> trim_output()
    |> case do
      {:ok, preshared_key} ->
        with :ok <- validate_key(preshared_key, :preshared_key) do
          {:ok, preshared_key}
        end

      error ->
        error
    end
  end

  def random_secret(bytes \\ 32, encoding \\ :url_base64)

  def random_secret(bytes, :url_base64) when is_integer(bytes) and bytes > 0 do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def random_secret(bytes, :base64) when is_integer(bytes) and bytes > 0 do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode64()
  end

  defp genkey(runner) do
    runner
    |> Command.run("wg", ["genkey"], [stderr_to_stdout: true], :key_generation)
    |> trim_output()
  end

  defp pubkey(runner, private_key) do
    runner
    |> Command.run(
      "wg",
      ["pubkey"],
      [input: private_key <> "\n", stderr_to_stdout: true],
      :public_key_derivation
    )
    |> trim_output()
  end

  defp trim_output({:ok, output}), do: {:ok, String.trim(output)}
  defp trim_output(error), do: error

  defp validate_key(key, step) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == @key_bytes ->
        :ok

      _ ->
        {:error,
         %Error{
           step: step,
           message: "generated WireGuard key is not a 32-byte base64 value"
         }}
    end
  end
end
