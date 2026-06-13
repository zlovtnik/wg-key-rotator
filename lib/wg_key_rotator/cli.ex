defmodule WgKeyRotator.CLI do
  alias WgKeyRotator.{Config, Error}

  def main(argv) do
    case run(argv) do
      {:ok, output} ->
        IO.puts(output)

      {:error, %Error{} = error} ->
        IO.puts(:stderr, Error.format(error))
        System.halt(1)

      {:halt, status, output} ->
        IO.puts(output)
        System.halt(status)
    end
  end

  def rotate do
    case WgKeyRotator.rotate() do
      {:ok, result} ->
        IO.puts(success_output(result))

      {:error, %Error{} = error} ->
        IO.puts(:stderr, Error.format(error))
        System.halt(1)
    end
  end

  def run(["rotate"]), do: run_rotate()
  def run(["rotate", "--dry-run"]), do: run_dry()
  def run(["--help"]), do: {:halt, 0, usage()}
  def run(["help"]), do: {:halt, 0, usage()}
  def run([]), do: {:halt, 64, usage()}
  def run(_argv), do: {:halt, 64, usage()}

  defp run_rotate do
    case WgKeyRotator.rotate() do
      {:ok, result} -> {:ok, success_output(result)}
      {:error, error} -> {:error, error}
    end
  end

  defp run_dry do
    dry_root =
      Path.join(System.tmp_dir!(), "wg-key-rotator-dry-run-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dry_root, "config/server"))
    File.touch!(Path.join(dry_root, "docker-compose.yaml"))

    {:ok, config} =
      Config.load(
        %{
          "ROTATOR_REPO_ROOT" => dry_root,
          "WAHA_SESSION" => "default",
          "WAHA_CHAT_ID" => "dry-run@c.us",
          "WAHA_BASE_URL" => "http://127.0.0.1:3000"
        },
        require_waha: false
      )

    deploy_fun = fn _config ->
      {:ok,
       %{
         deploy_output: "dry-run",
         ps_output: "ssl-proxy dry-run",
         health: %{status: 200, body: "dry-run"}
       }}
    end

    notify_fun = fn _config, _text -> {:ok, %{status: 200, body: "dry-run"}} end

    case WgKeyRotator.rotate(config, deploy_fun: deploy_fun, notify_fun: notify_fun) do
      {:ok, result} ->
        {:ok,
         success_output(result) <> "\ndry-run key dir: #{Path.join(dry_root, "config/server")}"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp success_output(result) do
    "rotation complete\nserver public key: #{result.public_key}"
  end

  defp usage do
    """
    usage:
      wg_key_rotator rotate
      wg_key_rotator rotate --dry-run

    required environment for rotate:
      ROTATOR_REPO_ROOT
      WAHA_BASE_URL
      WAHA_CHAT_ID

    optional environment:
      WAHA_SESSION
      WAHA_API_KEY
      ROTATOR_INCLUDE_PUBLIC_KEY
      ROTATOR_HEALTH_URL
    """
    |> String.trim()
  end
end
