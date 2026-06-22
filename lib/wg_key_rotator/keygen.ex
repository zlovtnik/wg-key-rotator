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
    # Write the private key to a temp file and pipe it into wg pubkey.
    # We avoid System.cmd's :input option because it requires OTP 26+.
    case write_temp_private_key(private_key) do
      {:ok, tmp_path} ->
        result =
          runner
          |> Command.run(
            "sh",
            ["-c", "wg pubkey < #{shell_quote(tmp_path)}"],
            [stderr_to_stdout: true],
            :public_key_derivation
          )
          |> trim_output()

        _ = File.rm(tmp_path)
        result

      {:error, reason} ->
        {:error,
         %Error{
           step: :public_key_derivation,
           message: "failed to write temp key file",
           details: inspect(reason)
         }}
    end
  end

  defp write_temp_private_key(private_key, attempts \\ 10)
  defp write_temp_private_key(_private_key, 0), do: {:error, :eexist}

  defp write_temp_private_key(private_key, attempts) do
    tmp_path = temp_path()

    case File.open(tmp_path, [:write, :exclusive, :binary], fn io ->
           with :ok <- File.chmod(tmp_path, 0o600) do
             IO.binwrite(io, private_key <> "\n")
           end
         end) do
      {:ok, :ok} -> {:ok, tmp_path}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :eexist} -> write_temp_private_key(private_key, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp temp_path do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "wgk-#{random}")
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
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
