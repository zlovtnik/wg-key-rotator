defmodule WgKeyRotator.AtomicFile do
  @moduledoc """
  Writes files atomically by writing to a temporary file in the same
  directory and then renaming.
  """

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

    handle_write_result(result, tmp_path, path)
  end

  defp handle_write_result(:ok, _tmp_path, _path), do: :ok

  defp handle_write_result({:error, reason}, tmp_path, path) do
    File.rm(tmp_path)

    {:error,
     %Error{
       step: :write_key_file,
       message: "failed to write #{path}",
       details: inspect(reason)
     }}
  end

  defp write_temp(path, contents, mode) do
    case File.open(path, [:write, :exclusive, :binary], fn io ->
           case File.chmod(path, mode) do
             :ok -> IO.binwrite(io, contents)
             error -> error
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
