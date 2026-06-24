defmodule WgKeyRotator.CLI do
  @moduledoc """
  Command-line interface for the wg-key-rotator application. Defines
  top-level commands (`rotate`, `stage`, `status`, etc.) called from
  `escript` or Mix run.
  """

  alias WgKeyRotator.{Config, Error, Rotation, Secrets}

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
  def run(["rotate", "--scheduled"]), do: run_rotation_command(:scheduled)
  def run(["rotate", "--dry-run"]), do: run_dry()
  def run(["stage"]), do: run_rotation_command(:stage)
  def run(["start-next"]), do: run_rotation_command(:start_next)
  def run(["status"]), do: run_rotation_command(:status)
  def run(["promote"]), do: run_rotation_command(:promote)
  def run(["rollback"]), do: run_rotation_command(:rollback)
  def run(["secrets", "generate" | args]), do: run_secrets_generate(args)
  def run(["secrets", "check"]), do: run_secrets_command(:check)
  def run(["secrets", "repair"]), do: run_secrets_command(:repair)
  def run(["secrets", "env"]), do: run_secrets_command(:env)
  def run(["secrets" | _argv]), do: {:halt, 64, usage()}
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

  defp run_rotation_command(command) do
    with {:ok, config} <- Config.load(:system, require_waha: false) do
      result =
        case command do
          :stage -> Rotation.stage(config)
          :start_next -> Rotation.start_next(config)
          :status -> Rotation.status(config)
          :promote -> Rotation.promote(config)
          :rollback -> Rotation.rollback(config)
          :scheduled -> Rotation.scheduled(config)
        end

      case result do
        {:ok, result} -> {:ok, Rotation.render_result(result)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp run_secrets_generate(args) do
    with {:ok, opts} <- parse_secret_generate_args(args),
         {:ok, repo_root} <- Secrets.repo_root() do
      Secrets.generate(repo_root, opts)
    else
      {:error, %Error{} = error} -> {:error, error}
      :error -> {:halt, 64, usage()}
    end
  end

  defp run_secrets_command(command) do
    with {:ok, repo_root} <- Secrets.repo_root() do
      case command do
        :check -> Secrets.check(repo_root)
        :repair -> Secrets.repair(repo_root)
        :env -> Secrets.env(repo_root)
      end
    end
  end

  defp parse_secret_generate_args(args) do
    Enum.reduce_while(args, {:ok, []}, fn
      "--force", {:ok, opts} ->
        {:cont, {:ok, Keyword.put(opts, :force, true)}}

      "--dry-run", {:ok, opts} ->
        {:cont, {:ok, Keyword.put(opts, :dry_run, true)}}

      _arg, {:ok, _opts} ->
        {:halt, :error}
    end)
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
          "WAHA_BASE_URL" => "http://127.0.0.1:3006"
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
      wg_key_rotator rotate --scheduled
      wg_key_rotator rotate --dry-run
      wg_key_rotator stage
      wg_key_rotator start-next
      wg_key_rotator status
      wg_key_rotator promote
      wg_key_rotator rollback
      wg_key_rotator secrets generate [--force] [--dry-run]
      wg_key_rotator secrets check
      wg_key_rotator secrets repair
      wg_key_rotator secrets env

    required environment for legacy rotate:
      WAHA_CHAT_ID

    staged rotation commands:
      rotate --scheduled, stage, start-next, status, promote, rollback
      WAHA settings are optional; notifications are sent only when configured.

    optional environment:
      ROTATOR_REPO_ROOT (auto-discovered when run inside the repo)
      WAHA_BASE_URL (default: http://127.0.0.1:3006)
      WAHA_SESSION
      WAHA_API_KEY
      ROTATOR_INCLUDE_PUBLIC_KEY
      ROTATOR_HEALTH_URL
      ROTATOR_STATE_DIR
      WG_PEERS
      ROTATOR_PEERS
      ROTATOR_MIGRATION_TIMEOUT_SECS
      ROTATOR_HANDSHAKE_GRACE_SECS
      ROTATOR_COMMAND_TIMEOUT_MS
      ROTATOR_FRONTDOOR_CONFIG_PATH
      ROTATOR_NEXT_ADMIN_PORT
    """
    |> String.trim()
  end
end
