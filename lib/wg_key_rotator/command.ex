defmodule WgKeyRotator.Command do
  @moduledoc """
  Runs external commands with optional timeout support using Erlang
  ports. Provides a `system_runner/3` function suitable as the default
  runner across the application.
  """

  alias WgKeyRotator.Error

  @type runner ::
          (String.t(), [String.t()], keyword() ->
             {String.t(), non_neg_integer()} | {:error, String.t()})

  def system_runner(command, args, opts) do
    case Keyword.pop(opts, :timeout_ms) do
      {nil, cmd_opts} ->
        System.cmd(command, args, cmd_opts)

      {timeout_ms, cmd_opts} when is_integer(timeout_ms) and timeout_ms > 0 ->
        run_with_timeout(command, args, cmd_opts, timeout_ms)
    end
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

      {:error, details} when is_binary(details) ->
        {:error, details}

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

  defp run_with_timeout(command, args, opts, timeout_ms) do
    with {:ok, executable} <- executable_path(command),
         {:ok, port} <- open_port(executable, args, opts) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      collect_port(port, [], deadline, command, args, timeout_ms)
    end
  end

  defp executable_path(command) do
    case System.find_executable(command) do
      nil -> {:error, "executable not found: #{command}"}
      path -> {:ok, path}
    end
  end

  defp open_port(executable, args, opts) do
    port_opts =
      [:binary, :exit_status, {:args, args}]
      |> maybe_put(:stderr_to_stdout, Keyword.get(opts, :stderr_to_stdout, false))
      |> maybe_put_keyword(opts, :cd)
      |> maybe_put_keyword(opts, :env)

    {:ok, Port.open({:spawn_executable, executable}, port_opts)}
  catch
    :error, reason ->
      {:error, exception_message(reason, __STACKTRACE__)}
  end

  defp exception_message(reason, stacktrace) do
    reason
    |> Exception.normalize(:error, stacktrace)
    |> Exception.message()
  end

  defp maybe_put(opts, _option, false), do: opts
  defp maybe_put(opts, option, true), do: [option | opts]

  defp maybe_put_keyword(port_opts, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> [{key, value} | port_opts]
      :error -> port_opts
    end
  end

  defp collect_port(port, output, deadline, command, args, timeout_ms) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_port(port, [data | output], deadline, command, args, timeout_ms)

      {^port, {:exit_status, status}} ->
        {output |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining_ms ->
        terminate_port(port)

        details =
          [
            Enum.join([command | args], " "),
            " timed out after ",
            Integer.to_string(timeout_ms),
            "ms",
            timeout_output(output)
          ]
          |> IO.iodata_to_binary()

        {:error, details}
    end
  end

  defp terminate_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        signal_pid(pid, "TERM")
        Process.sleep(500)
        signal_pid(pid, "KILL")

      _ ->
        :ok
    end

    Port.close(port)
  rescue
    _error -> :ok
  end

  defp signal_pid(pid, signal) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp timeout_output([]), do: ""

  defp timeout_output(output) do
    ["\n\npartial output:\n", output |> Enum.reverse() |> IO.iodata_to_binary()]
  end
end
