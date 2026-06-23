defmodule WgKeyRotator.Secrets do
  @moduledoc false

  import Bitwise

  alias WgKeyRotator.{AtomicFile, Error}

  @secret_dir "secrets"
  @env_file ".env"
  @one_time_tokens "ONE_TIME_TOKENS"
  @default_image_tag "latest"

  @secret_specs [
    %{
      path: "postgres.key",
      bytes: 32,
      kind: :secret,
      env: "POSTGRES_PASSWORD",
      mode: 0o600
    },
    %{
      path: "minio_access_key.key",
      bytes: 24,
      kind: :secret,
      env: "MINIO_ACCESS_KEY_ID",
      mode: 0o600
    },
    %{
      path: "minio_secret_key.key",
      bytes: 32,
      kind: :secret,
      env: "MINIO_SECRET_ACCESS_KEY",
      mode: 0o600
    },
    %{
      path: "wg_obfuscation_key",
      bytes: 32,
      kind: :secret,
      mode: 0o400
    },
    %{
      path: "admin_api_key",
      bytes: 48,
      kind: :secret,
      mode: 0o400
    },
    %{
      path: "grafana_admin_password.key",
      bytes: 32,
      kind: :secret,
      env: "GRAFANA_ADMIN_PASSWORD",
      mode: 0o600
    },
    %{
      path: "atheros_api_token_sha256.key",
      bytes: 48,
      kind: :sha256,
      env: "ATHSEARCH_API_TOKEN_SHA256",
      token_env: "ATHEROS_API_TOKEN",
      token_label: "Atheros API token",
      mode: 0o600
    },
    %{
      path: "waha/api_key.key",
      bytes: 32,
      kind: :secret,
      env: "WAHA_API_KEY",
      mode: 0o600
    },
    %{
      path: "waha/dashboard_password.key",
      bytes: 32,
      kind: :secret,
      env: "WAHA_DASHBOARD_PASSWORD",
      mode: 0o600
    },
    %{
      path: "waha/swagger_password.key",
      bytes: 32,
      kind: :secret,
      env: "WHATSAPP_SWAGGER_PASSWORD",
      mode: 0o600
    }
  ]

  @copies [
    %{
      source: "admin_api_key",
      target: "wg-rotation/candidate/secrets/admin_api_key",
      mode: 0o400
    },
    %{
      source: "wg_obfuscation_key",
      target: "wg-rotation/candidate/secrets/wg_obfuscation_key",
      mode: 0o400
    }
  ]

  @env_order [
    "POSTGRES_PASSWORD",
    "MINIO_ACCESS_KEY_ID",
    "MINIO_SECRET_ACCESS_KEY",
    "GRAFANA_ADMIN_PASSWORD",
    "ATHSEARCH_API_TOKEN_SHA256",
    "WAHA_API_KEY",
    "WAHA_DASHBOARD_PASSWORD",
    "WHATSAPP_SWAGGER_PASSWORD"
  ]

  def repo_root(env \\ System.get_env(), cwd \\ File.cwd!()) do
    case blank_to_nil(env["ROTATOR_REPO_ROOT"]) do
      nil -> discover_repo_root(cwd)
      path -> validate_repo_root(Path.expand(path))
    end
  end

  def generate(repo_root, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    dry_run = Keyword.get(opts, :dry_run, false)

    cond do
      dry_run ->
        {:ok, dry_run_output(repo_root)}

      not force and existing_managed_paths(repo_root) != [] ->
        {:error,
         %Error{
           step: :secret_generation,
           message: "refusing to overwrite existing secret files",
           details: existing_details(repo_root)
         }}

      true ->
        do_generate(repo_root, force)
    end
  end

  def check(repo_root) do
    issues =
      []
      |> check_directories(repo_root)
      |> check_secret_files(repo_root)
      |> check_copy_files(repo_root)
      |> check_one_time_tokens(repo_root)

    case issues do
      [] ->
        {:ok, "OK: secret tree is complete"}

      issues ->
        {:error,
         %Error{
           step: :secret_check,
           message: "secret check failed",
           details: Enum.reverse(issues) |> Enum.join("\n")
         }}
    end
  end

  def env(repo_root, system_env \\ System.get_env()) do
    with {:ok, contents} <- render_env(repo_root, system_env),
         :ok <- AtomicFile.write(Path.join(repo_root, @env_file), contents, 0o600) do
      {:ok, "OK: wrote #{Path.join(repo_root, @env_file)}"}
    end
  end

  def render_env(repo_root, system_env \\ System.get_env()) do
    with {:ok, values} <- read_env_values(repo_root),
         {:ok, registry} <- compose_registry_value(system_env),
         {:ok, image_tag} <- compose_image_tag_value(system_env) do
      {:ok, env_contents(values, registry, image_tag)}
    end
  end

  defp do_generate(repo_root, force) do
    generated_at = DateTime.utc_now() |> DateTime.to_iso8601()

    with :ok <- ensure_secret_directories(repo_root),
         {:ok, token_entries} <- write_secret_specs(repo_root, force),
         :ok <- write_copies(repo_root, force),
         :ok <- write_one_time_tokens(repo_root, token_entries, force) do
      output = [
        "OK: generated secrets in #{Path.join(repo_root, @secret_dir)}",
        "Generated at: #{generated_at}",
        one_time_message(repo_root, token_entries),
        "Run scripts/gen-secrets env to materialize #{Path.join(repo_root, @env_file)}."
      ]

      {:ok, output |> Enum.reject(&(&1 == nil)) |> Enum.join("\n")}
    end
  end

  defp write_secret_specs(repo_root, force) do
    Enum.reduce_while(@secret_specs, {:ok, []}, fn spec, {:ok, token_entries} ->
      path = secret_path(repo_root, spec.path)
      {contents, token_entry} = secret_contents(spec)

      case write_managed_file(path, contents, spec.mode, force) do
        :ok -> {:cont, {:ok, prepend_present(token_entry, token_entries)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp secret_contents(%{kind: :secret, bytes: bytes}) do
    {random_secret(bytes) <> "\n", nil}
  end

  defp secret_contents(%{kind: :sha256, bytes: bytes, token_env: token_env, token_label: label}) do
    raw = random_secret(bytes)
    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    {hash <> "\n", {token_env, label, raw}}
  end

  defp write_copies(repo_root, force) do
    Enum.reduce_while(@copies, :ok, fn copy, :ok ->
      source = secret_path(repo_root, copy.source)
      target = secret_path(repo_root, copy.target)

      result =
        case File.read(source) do
          {:ok, contents} ->
            write_managed_file(target, contents, copy.mode, force)

          {:error, reason} ->
            {:error,
             %Error{
               step: :secret_copy,
               message: "failed to read #{source}",
               details: inspect(reason)
             }}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp write_one_time_tokens(_repo_root, [], _force), do: :ok

  defp write_one_time_tokens(repo_root, token_entries, force) do
    lines = [
      "# One-time raw tokens. Save these outside the repo, then delete this file.",
      "# scripts/gen-secrets check fails while this file exists."
      | Enum.map(Enum.reverse(token_entries), fn {env, label, value} ->
          "# #{label}\n#{env}=#{value}"
        end)
    ]

    write_managed_file(
      one_time_token_path(repo_root),
      Enum.join(lines, "\n") <> "\n",
      0o600,
      force
    )
  end

  defp write_managed_file(path, contents, mode, force) do
    tmp_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- refuse_existing(path, force),
         :ok <- write_temp(tmp_path, contents, mode),
         :ok <- File.rename(tmp_path, path),
         :ok <- File.chmod(path, mode) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)

        {:error,
         %Error{
           step: :secret_write,
           message: "failed to write #{path}",
           details: inspect(reason)
         }}
    end
  end

  defp refuse_existing(_path, true), do: :ok

  defp refuse_existing(path, false) do
    if File.exists?(path), do: {:error, :eexist}, else: :ok
  end

  defp write_temp(path, contents, mode) do
    case File.write(path, contents, [:exclusive, :binary]) do
      :ok -> File.chmod(path, mode)
      error -> error
    end
  end

  defp ensure_secret_directories(repo_root) do
    repo_root
    |> managed_dirs()
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case ensure_secret_dir(dir) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %Error{
           step: :secret_directories,
           message: "failed to prepare secret directories",
           details: inspect(reason)
         }}
    end
  end

  defp ensure_secret_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> File.chmod(dir, 0o700)
      error -> error
    end
  end

  defp check_directories(issues, repo_root) do
    Enum.reduce(managed_dirs(repo_root), issues, fn dir, acc ->
      cond do
        not File.dir?(dir) ->
          ["MISSING_DIR #{dir}" | acc]

        mode(dir) != 0o700 ->
          ["WRONG_PERMS #{dir} got #{format_mode(mode(dir))} expected 0700" | acc]

        true ->
          acc
      end
    end)
  end

  defp check_secret_files(issues, repo_root) do
    Enum.reduce(@secret_specs, issues, fn spec, acc ->
      path = secret_path(repo_root, spec.path)

      acc
      |> check_file(path, spec.mode)
      |> check_hash(path, spec)
      |> check_secret_value(path, spec)
    end)
  end

  defp check_copy_files(issues, repo_root) do
    Enum.reduce(@copies, issues, fn copy, acc ->
      source = secret_path(repo_root, copy.source)
      target = secret_path(repo_root, copy.target)

      acc =
        acc
        |> check_file(target, copy.mode)

      if File.exists?(source) and File.exists?(target) and
           File.read!(source) != File.read!(target) do
        ["MISMATCH #{target} does not match #{source}" | acc]
      else
        acc
      end
    end)
  end

  defp check_one_time_tokens(issues, repo_root) do
    path = one_time_token_path(repo_root)

    if File.exists?(path) do
      ["ONE_TIME_TOKENS_PRESENT #{path} must be consumed and deleted" | issues]
    else
      issues
    end
  end

  defp check_file(issues, path, expected_mode) do
    cond do
      not File.exists?(path) ->
        ["MISSING #{path}" | issues]

      not File.regular?(path) ->
        ["NOT_FILE #{path}" | issues]

      mode(path) != expected_mode ->
        [
          "WRONG_PERMS #{path} got #{format_mode(mode(path))} expected #{format_mode(expected_mode)}"
          | issues
        ]

      true ->
        issues
    end
  end

  defp check_hash(issues, path, %{kind: :sha256}) do
    if File.exists?(path) and File.regular?(path) do
      value = path |> File.read!() |> String.trim()

      if value =~ ~r/\A[0-9a-f]{64}\z/ do
        issues
      else
        ["INVALID_HASH #{path}" | issues]
      end
    else
      issues
    end
  end

  defp check_hash(issues, _path, _spec), do: issues

  defp check_secret_value(issues, path, %{kind: :secret}) do
    if File.exists?(path) and File.regular?(path) do
      value = File.read!(path)
      trimmed = String.trim(value)

      cond do
        trimmed == "" ->
          ["EMPTY_SECRET #{path}" | issues]

        multiline?(trimmed) ->
          ["MULTILINE_SECRET #{path}" | issues]

        true ->
          issues
      end
    else
      issues
    end
  end

  defp check_secret_value(issues, _path, _spec), do: issues

  defp read_env_values(repo_root) do
    Enum.reduce_while(@secret_specs, {:ok, %{}}, fn spec, {:ok, values} ->
      case read_env_value(repo_root, spec) do
        {:ok, nil} -> {:cont, {:ok, values}}
        {:ok, {env, value}} -> {:cont, {:ok, Map.put(values, env, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp read_env_value(repo_root, %{env: env, path: path} = spec) do
    secret_path = secret_path(repo_root, path)

    with {:ok, value} <- read_secret_value(secret_path),
         :ok <- validate_env_secret(secret_path, value, spec) do
      {:ok, {env, value}}
    end
  end

  defp read_env_value(_repo_root, _spec), do: {:ok, nil}

  defp read_secret_value(path) do
    case File.read(path) do
      {:ok, value} ->
        {:ok, String.trim(value)}

      {:error, reason} ->
        {:error,
         %Error{
           step: :secret_env,
           message: "failed to read #{path}",
           details: inspect(reason)
         }}
    end
  end

  defp validate_env_secret(path, value, %{kind: :sha256}) do
    if value =~ ~r/\A[0-9a-f]{64}\z/ do
      :ok
    else
      {:error, %Error{step: :secret_env, message: "invalid SHA-256 secret", details: path}}
    end
  end

  defp validate_env_secret(path, value, _spec) do
    cond do
      value == "" ->
        {:error, %Error{step: :secret_env, message: "secret value is empty", details: path}}

      multiline?(value) ->
        {:error,
         %Error{step: :secret_env, message: "secret value contains newlines", details: path}}

      true ->
        :ok
    end
  end

  defp env_contents(values, registry, image_tag) do
    secret_lines =
      @env_order
      |> Enum.map(fn key -> "#{key}=#{Map.fetch!(values, key)}" end)

    [
      "# Generated by scripts/gen-secrets env. Do not commit.",
      "",
      "# Local registry images",
      "REGISTRY=#{registry}",
      "IMAGE_TAG=#{image_tag}",
      "",
      "# Postgres",
      Enum.find(secret_lines, &String.starts_with?(&1, "POSTGRES_PASSWORD=")),
      "",
      "# MinIO",
      Enum.find(secret_lines, &String.starts_with?(&1, "MINIO_ACCESS_KEY_ID=")),
      Enum.find(secret_lines, &String.starts_with?(&1, "MINIO_SECRET_ACCESS_KEY=")),
      "",
      "# Grafana",
      Enum.find(secret_lines, &String.starts_with?(&1, "GRAFANA_ADMIN_PASSWORD=")),
      "",
      "# Atheros search API token hash. Raw token is only written to secrets/ONE_TIME_TOKENS.",
      Enum.find(secret_lines, &String.starts_with?(&1, "ATHSEARCH_API_TOKEN_SHA256=")),
      "",
      "# ssl-proxy file-backed secrets inside containers",
      "ADMIN_API_KEY=",
      "ADMIN_API_KEY_FILE=/run/local-secrets/admin_api_key",
      "WG_OBFUSCATION_KEY=",
      "WG_OBFUSCATION_KEY_FILE=/run/local-secrets/wg_obfuscation_key",
      "",
      "# WAHA credentials",
      "WAHA_NO_API_KEY=False",
      Enum.find(secret_lines, &String.starts_with?(&1, "WAHA_API_KEY=")),
      "WAHA_API_KEY_FILE=",
      "WAHA_DASHBOARD_NO_PASSWORD=False",
      "WAHA_DASHBOARD_USERNAME=admin",
      Enum.find(secret_lines, &String.starts_with?(&1, "WAHA_DASHBOARD_PASSWORD=")),
      "WHATSAPP_SWAGGER_NO_PASSWORD=False",
      "WHATSAPP_SWAGGER_USERNAME=admin",
      Enum.find(secret_lines, &String.starts_with?(&1, "WHATSAPP_SWAGGER_PASSWORD=")),
      ""
    ]
    |> Enum.join("\n")
  end

  defp compose_registry_value(system_env) do
    case system_env |> Map.get("REGISTRY") |> blank_to_nil() do
      nil -> registry_from_server_ip(system_env)
      value -> require_concrete_compose_value("REGISTRY", value)
    end
  end

  defp compose_image_tag_value(system_env) do
    case system_env |> Map.get("IMAGE_TAG") |> blank_to_nil() do
      nil -> {:ok, @default_image_tag}
      value -> require_concrete_compose_value("IMAGE_TAG", value)
    end
  end

  defp registry_from_server_ip(system_env) do
    case system_env |> Map.get("SERVER_IP") |> blank_to_nil() do
      nil ->
        {:error,
         %Error{
           step: :secret_env,
           message: "REGISTRY or SERVER_IP is required",
           details:
             "set REGISTRY=<server-local-ip>:5000 or SERVER_IP=<server-local-ip> before running scripts/gen-secrets env"
         }}

      server_ip ->
        with {:ok, server_ip} <- require_concrete_compose_value("SERVER_IP", server_ip) do
          {:ok, "#{server_ip}:5000"}
        end
    end
  end

  defp require_concrete_compose_value(key, value) do
    if unresolved_placeholder?(value) do
      {:error,
       %Error{
         step: :secret_env,
         message: "#{key} contains an unresolved placeholder",
         details:
           "set REGISTRY=<server-local-ip>:5000 or SERVER_IP=<server-local-ip> before running scripts/gen-secrets env"
       }}
    else
      {:ok, value}
    end
  end

  defp unresolved_placeholder?(value) do
    String.contains?(value, "<") or String.contains?(value, ">") or
      String.contains?(value, "generated by scripts/gen-secrets env")
  end

  defp dry_run_output(repo_root) do
    create_lines =
      Enum.map(@secret_specs, fn spec ->
        "  CREATE #{secret_path(repo_root, spec.path)} #{spec.bytes} bytes #{spec.kind}"
      end)

    copy_lines =
      Enum.map(@copies, fn copy ->
        "  COPY   #{secret_path(repo_root, copy.target)} <- #{secret_path(repo_root, copy.source)}"
      end)

    token_line = "  CREATE #{one_time_token_path(repo_root)} one-time raw token file"

    Enum.join(
      ["Dry-run mode - no files will be written.", ""] ++
        create_lines ++ copy_lines ++ [token_line],
      "\n"
    )
  end

  defp one_time_message(_repo_root, []), do: nil

  defp one_time_message(repo_root, _token_entries) do
    path = one_time_token_path(repo_root)

    "ONE-TIME TOKENS: save values from #{path}, then delete the file."
  end

  defp existing_details(repo_root) do
    repo_root
    |> existing_managed_paths()
    |> Enum.map_join("\n", &"EXISTS #{&1}")
  end

  defp existing_managed_paths(repo_root) do
    repo_root
    |> managed_file_paths()
    |> Enum.filter(&File.exists?/1)
  end

  defp managed_file_paths(repo_root) do
    secret_paths = Enum.map(@secret_specs, &secret_path(repo_root, &1.path))
    copy_paths = Enum.map(@copies, &secret_path(repo_root, &1.target))
    secret_paths ++ copy_paths ++ [one_time_token_path(repo_root)]
  end

  defp managed_dirs(repo_root) do
    secrets_root = Path.join(repo_root, @secret_dir)

    repo_root
    |> managed_file_paths()
    |> Enum.flat_map(&secret_dir_ancestors(Path.dirname(&1), secrets_root))
    |> Enum.uniq()
  end

  defp secret_dir_ancestors(dir, secrets_root) do
    cond do
      dir == secrets_root ->
        [secrets_root]

      String.starts_with?(dir, secrets_root <> "/") ->
        [dir | secret_dir_ancestors(Path.dirname(dir), secrets_root)]

      true ->
        []
    end
  end

  defp prepend_present(nil, list), do: list
  defp prepend_present(value, list), do: [value | list]

  defp multiline?(value) do
    String.contains?(value, "\r") or String.contains?(value, "\n")
  end

  defp random_secret(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp secret_path(repo_root, path), do: Path.join([repo_root, @secret_dir, path])
  defp one_time_token_path(repo_root), do: secret_path(repo_root, @one_time_tokens)

  defp mode(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.mode &&& 0o777
      {:error, _reason} -> nil
    end
  end

  defp format_mode(nil), do: "missing"

  defp format_mode(mode) do
    mode
    |> Integer.to_string(8)
    |> String.pad_leading(4, "0")
  end

  defp discover_repo_root(cwd) do
    cwd
    |> Path.expand()
    |> ancestors()
    |> Enum.find(&File.exists?(Path.join(&1, "docker-compose.yaml")))
    |> case do
      nil ->
        {:error,
         %Error{
           step: :repo_root,
           message: "could not discover repository root",
           details: "set ROTATOR_REPO_ROOT or run from inside the ssl-proxy checkout"
         }}

      repo_root ->
        validate_repo_root(repo_root)
    end
  end

  defp validate_repo_root(repo_root) do
    if File.exists?(Path.join(repo_root, "docker-compose.yaml")) do
      {:ok, repo_root}
    else
      {:error,
       %Error{
         step: :repo_root,
         message: "repo root must contain docker-compose.yaml",
         details: repo_root
       }}
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

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
