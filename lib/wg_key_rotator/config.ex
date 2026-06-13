defmodule WgKeyRotator.Config do
  alias WgKeyRotator.Error

  @app_root Path.expand("../..", __DIR__)
  @source_repo_root Path.expand("../../../../", __DIR__)

  defstruct repo_root: nil,
            private_key_path: nil,
            public_key_path: nil,
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
    repo_root = repo_root(env, Keyword.get(opts, :cwd, File.cwd!()))

    config = %__MODULE__{
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
      health_url: blank_to_nil(env["ROTATOR_HEALTH_URL"]) || "http://127.0.0.1:3002/health",
      health_timeout_ms: positive_integer(env["ROTATOR_HEALTH_TIMEOUT_MS"], 5_000),
      waha_base_url: blank_to_nil(env["WAHA_BASE_URL"]),
      waha_session: blank_to_nil(env["WAHA_SESSION"]) || "default",
      waha_chat_id: blank_to_nil(env["WAHA_CHAT_ID"]),
      waha_api_key: blank_to_nil(env["WAHA_API_KEY"]),
      include_public_key: boolean(env["ROTATOR_INCLUDE_PUBLIC_KEY"], true)
    }

    validate(config, require_waha)
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
      nil -> discover_repo_root(cwd) || @source_repo_root
      path -> Path.expand(path)
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
             "missing docker-compose.yaml"
           ),
         :ok <- require_present(config.waha_base_url, :waha_base_url, require_waha),
         :ok <- require_present(config.waha_chat_id, :waha_chat_id, require_waha) do
      {:ok, config}
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
