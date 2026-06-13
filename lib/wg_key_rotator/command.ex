defmodule WgKeyRotator.Command do
  alias WgKeyRotator.Error

  @type runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  def system_runner(command, args, opts) do
    System.cmd(command, args, opts)
  end

  def run(runner, command, args, opts, step) do
    case invoke(runner, command, args, opts) do
      {:ok, output, 0} ->
        {:ok, output}

      {:ok, output, status} ->
        {:error,
         %Error{
           step: step,
           message: "#{command} exited with status #{status}",
           details: output
         }}

      {:error, details} ->
        {:error,
         %Error{
           step: step,
           message: "failed to run #{command}",
           details: details
         }}
    end
  end

  defp invoke(runner, command, args, opts) do
    case runner.(command, args, opts) do
      {output, status} when is_binary(output) and is_integer(status) ->
        {:ok, output, status}

      other ->
        {:error, "runner returned #{inspect(other)}"}
    end
  rescue
    error in [ErlangError, ArgumentError] ->
      {:error, Exception.message(error)}
  catch
    :exit, reason ->
      {:error, inspect(reason)}
  end
end
