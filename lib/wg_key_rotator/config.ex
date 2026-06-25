defmodule WgKeyRotator.Config do
  @moduledoc """
  Loads and validates configuration from environment variables and a
  `.env` file. Builds a `%Config{}` struct with paths, peer list, timeouts,
  and WAHA integration settings.
  """

  alias WgKeyRotator.Error

  @app_root Path.expand("../..", __DIR__)

  defstruct repo_root: nil,
            private_key_path: nil,
            public_key_path: nil,
            state_dir: nil,
            peers: [],
            migration_timeout_secs: 86_400,
            handshake_grace_secs: 600,
            command_timeout_ms: 600_000,
            frontdoor_config_path: nil,
            next_admin_port: 3012,
            health_url: "http://127.0.0.1:3002/health",
            health_timeout_ms: 5_000,
            waha_base_url: nil,
            waha_session: "default",
            waha_chat_id: nil,
            waha_api_key: nil,
            include_public_key: true

  @type t :: %__MODULE__{
          repo_root: String.t(),
          private_key_path: String.t(),
          public_key_path: String.t(),
          state_dir: String.t(),
          peers: [String.t()],
          migration_timeout_secs: pos_integer(),
          handshake_grace_secs: pos_integer(),
          command_timeout_ms: pos_integer(),
          frontdoor_config_path: String.t(),
          next_admin_port: pos_integer(),
          health_url: String.t(),
          health_timeout_ms: pos_integer(),
          waha_base_url: String.t() | nil,
          waha_session: String.t(),
          waha_chat_id: String.t() | nil,
          waha_api_key: String.t() | nil,
          include_public_key: boolean()
        }

  def load(env \\ :system, opts \\ [])

  def load(:system, opts) do
    opts
    |> Keyword.get(:dotenv_path, Path.join(@app_root, ".env"))
    |> dotenv_env()
    |> Map.merge(System.get_env())
    |> load(opts)
  end

  def load(env, opts) when is_map(env) do
    require_waha = Keyword.get(opts, :require_waha, true)

    with {:ok, repo_root} <- repo_root(env, Keyword.get(opts, :cwd, File.cwd!())) do
      config =
        %__MODULE__{
          repo_root: repo_root,
          private_key_path:
            expand_from_root(
              env["ROTATOR_PRIVATE_KEY_PATH"],
              repo_root,
              "config/server/privatekey-server"
            ),
          public_key_path:
            expand_from_root(
              env["ROTATOR_PUBLIC_KEY_PATH"],
              repo_root,
              "config/server/publickey-server"
            ),
          state_dir:
            expand_from_root(
              env["ROTATOR_STATE_DIR"],
              repo_root,
              "secrets/wg-rotation"
            ),
          peers: peers(blank_to_nil(env["ROTATOR_PEERS"]) || env["WG_PEERS"]),
          migration_timeout_secs: positive_integer(env["ROTATOR_MIGRATION_TIMEOUT_SECS"], 86_400),
          handshake_grace_secs: positive_integer(env["ROTATOR_HANDSHAKE_GRACE_SECS"], 600),
          command_timeout_ms: positive_integer(env["ROTATOR_COMMAND_TIMEOUT_MS"], 600_000),
          next_admin_port: positive_integer(env["ROTATOR_NEXT_ADMIN_PORT"], 3_012),
          health_url: blank_to_nil(env["ROTATOR_HEALTH_URL"]) || "http://127.0.0.1:3002/health",
          health_timeout_ms: positive_integer(env["ROTATOR_HEALTH_TIMEOUT_MS"], 5_000),
          waha_base_url: blank_to_nil(env["WAHA_BASE_URL"]) || "http://127.0.0.1:3006",
          waha_session: blank_to_nil(env["WAHA_SESSION"]) || "default",
          waha_chat_id: blank_to_nil(env["WAHA_CHAT_ID"]),
          waha_api_key: secret(env, "WAHA_API_KEY", "WAHA_API_KEY_FILE"),
          include_public_key: boolean(env["ROTATOR_INCLUDE_PUBLIC_KEY"], true)
        }
        |> put_frontdoor_config_path(env)

      validate(config, require_waha)
    end
  end

  defp dotenv_env(path) do
    case File.read(path) do
      {:ok, contents} -> parse_dotenv(contents)
      {:error, _reason} -> %{}
    end
  end

  defp parse_dotenv(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case dotenv_pair(line) do
        {:ok, key, value} -> Map.put(acc, key, value)
        :skip -> acc
      end
    end)
  end

  defp dotenv_pair(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        :skip

      String.starts_with?(line, "#") ->
        :skip

      true ->
        parts =
          line
          |> String.replace_prefix("export ", "")
          |> String.split("=", parts: 2)

        case parts do
          [key, value] -> {:ok, String.trim(key), strip_quotes(value)}
          _ -> :skip
        end
    end
  end

  defp strip_quotes(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end

  defp repo_root(env, cwd) do
    case blank_to_nil(env["ROTATOR_REPO_ROOT"]) do
      nil -> discover_repo_root(cwd)
      path -> {:ok, Path.expand(path)}
    end
  end

  defp discover_repo_root(cwd) do
    cwd
    |> Path.expand()
    |> ancestors()
    |> Enum.find(fn dir ->
      File.exists?(Path.join(dir, "docker-compose.yaml")) and
        File.dir?(Path.join(dir, "config/server"))
    end)
    |> case do
      nil ->
        {:error,
         %Error{
           step: :repo_root,
           message: "could not discover repository root",
           details: "set ROTATOR_REPO_ROOT or run from inside the ssl-proxy checkout"
         }}

      repo_root ->
        {:ok, repo_root}
    end
  end

  defp ancestors(path) do
    parent = Path.dirname(path)

    if parent == path do
      [path]
    else
      [path | ancestors(parent)]
    end
  end

  defp validate(%__MODULE__{} = config, require_waha) do
    with :ok <-
           require_file(
             Path.join(config.repo_root, "docker-compose.yaml"),
             :repo_root,
             "repo root must contain docker-compose.yaml"
           ),
         :ok <- require_valid_peers(config.peers),
         :ok <- require_present(config.waha_base_url, :waha_base_url, require_waha),
         :ok <- require_present(config.waha_chat_id, :waha_chat_id, require_waha) do
      {:ok, config}
    end
  end

  defp require_valid_peers(peers) do
    invalid =
      Enum.find(peers, fn peer ->
        not Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, peer)
      end)

    if invalid do
      {:error,
       %Error{
         step: :peers,
         message: "peer names may contain only letters, numbers, underscore, and dash",
         details: invalid
       }}
    else
      :ok
    end
  end

  defp put_frontdoor_config_path(%__MODULE__{} = config, env) do
    path =
      expand_from_root(
        env["ROTATOR_FRONTDOOR_CONFIG_PATH"],
        config.repo_root,
        Path.relative_to(
          Path.join(config.state_dir, "frontdoor/wg-udp-frontdoor.toml"),
          config.repo_root
        )
      )

    %{config | frontdoor_config_path: path}
  end

  defp peers(nil), do: ["peer1", "peer2"]
  defp peers(""), do: ["peer1", "peer2"]

  defp peers(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["peer1", "peer2"]
      peers -> peers
    end
  end

  defp secret(env, value_var, file_var) do
    case blank_to_nil(env[value_var]) do
      nil -> file_secret(env[file_var])
      value -> value
    end
  end

  defp file_secret(nil), do: nil
  defp file_secret(""), do: nil

  defp file_secret(path) do
    path
    |> Path.expand()
    |> File.read()
    |> case do
      {:ok, value} -> blank_to_nil(value)
      {:error, _reason} -> nil
    end
  end

  defp require_file(path, step, message) do
    if File.exists?(path) do
      :ok
    else
      {:error, %Error{step: step, message: message, details: path}}
    end
  end

  defp require_present(_value, _step, false), do: :ok

  defp require_present(value, step, true) when value in [nil, ""] do
    {:error, %Error{step: step, message: "required environment variable is missing"}}
  end

  defp require_present(_value, _step, true), do: :ok

  defp expand_from_root(nil, repo_root, default), do: Path.join(repo_root, default)
  defp expand_from_root("", repo_root, default), do: Path.join(repo_root, default)

  defp expand_from_root(path, repo_root, _default) do
    if Path.type(path) == :absolute, do: path, else: Path.join(repo_root, path)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp boolean(nil, default), do: default

  defp boolean(value, _default) do
    case String.downcase(String.trim(value)) do
      value when value in ["1", "true", "yes", "on"] -> true
      value when value in ["0", "false", "no", "off"] -> false
      _ -> true
    end
  end

  defp positive_integer(nil, default), do: default

  defp positive_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end
end
