defmodule WgKeyRotator.AtomicFile do
  alias WgKeyRotator.Error

  def write(path, contents, mode)
      when is_binary(path) and is_binary(contents) and is_integer(mode) do
    dir = Path.dirname(path)
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    result =
      with :ok <- File.mkdir_p(dir),
           :ok <- write_temp(tmp_path, contents, mode),
           :ok <- File.rename(tmp_path, path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp_path)

        {:error,
         %Error{
           step: :write_key_file,
           message: "failed to write #{path}",
           details: inspect(reason)
         }}
    end
  end

  defp write_temp(path, contents, mode) do
    case File.open(path, [:write, :exclusive, :binary], fn io ->
           with :ok <- File.chmod(path, mode) do
             IO.binwrite(io, contents)
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
