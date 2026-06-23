defmodule WgKeyRotator.SecretsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias WgKeyRotator.Secrets

  @secret_files [
    {"postgres.key", 0o600},
    {"minio_access_key.key", 0o600},
    {"minio_secret_key.key", 0o600},
    {"admin_api_key", 0o400},
    {"wg_obfuscation_key", 0o400},
    {"grafana_admin_password.key", 0o600},
    {"atheros_api_token_sha256.key", 0o600},
    {"waha/api_key.key", 0o600},
    {"waha/dashboard_password.key", 0o600},
    {"waha/swagger_password.key", 0o600},
    {"wg-rotation/candidate/secrets/admin_api_key", 0o400},
    {"wg-rotation/candidate/secrets/wg_obfuscation_key", 0o400}
  ]

  test "generates secret tree, copies, permissions, and one-time token hash" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, output} = Secrets.generate(root)
    assert output =~ "OK: generated secrets"

    for {path, expected_mode} <- @secret_files do
      full_path = Path.join([root, "secrets", path])
      assert File.exists?(full_path)
      assert mode(full_path) == expected_mode
    end

    assert File.read!(Path.join(root, "secrets/admin_api_key")) ==
             File.read!(Path.join(root, "secrets/wg-rotation/candidate/secrets/admin_api_key"))

    assert File.read!(Path.join(root, "secrets/wg_obfuscation_key")) ==
             File.read!(
               Path.join(root, "secrets/wg-rotation/candidate/secrets/wg_obfuscation_key")
             )

    token_file = Path.join(root, "secrets/ONE_TIME_TOKENS")
    assert mode(token_file) == 0o600
    raw_token = token_file |> File.read!() |> token_value("ATHEROS_API_TOKEN")
    expected_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)

    assert File.read!(Path.join(root, "secrets/atheros_api_token_sha256.key")) |> String.trim() ==
             expected_hash
  end

  test "check fails while one-time token file exists and passes after cleanup" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    assert {:error, error} = Secrets.check(root)
    assert error.details =~ "ONE_TIME_TOKENS_PRESENT"

    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))
    assert {:ok, "OK: secret tree is complete"} = Secrets.check(root)
  end

  test "generation refuses to overwrite unless forced" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    postgres_path = Path.join(root, "secrets/postgres.key")
    original = File.read!(postgres_path)

    assert {:error, error} = Secrets.generate(root)
    assert error.message =~ "refusing to overwrite"
    assert File.read!(postgres_path) == original

    assert {:ok, _output} = Secrets.generate(root, force: true)
    refute File.read!(postgres_path) == original
  end

  test "dry run reports planned files without writing" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, output} = Secrets.generate(root, dry_run: true)
    assert output =~ "Dry-run mode"
    assert output =~ "postgres.key"
    refute File.exists?(Path.join(root, "secrets"))
  end

  test "check validates SHA-256 hash format" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))
    File.write!(Path.join(root, "secrets/atheros_api_token_sha256.key"), "not-a-hash\n")

    assert {:error, error} = Secrets.check(root)
    assert error.details =~ "INVALID_HASH"
  end

  test "env materializes literal compose values" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    assert {:ok, output} = Secrets.env(root, %{"SERVER_IP" => "192.168.1.221"})
    assert output =~ ".env"

    env = File.read!(Path.join(root, ".env"))
    refute env =~ "$("

    assert env =~
             "POSTGRES_PASSWORD=#{File.read!(Path.join(root, "secrets/postgres.key")) |> String.trim()}"

    assert env =~ "WAHA_NO_API_KEY=False"
    assert env =~ "WAHA_DASHBOARD_NO_PASSWORD=False"
    assert env =~ "WHATSAPP_SWAGGER_NO_PASSWORD=False"
    assert env =~ "REGISTRY=192.168.1.221:5000"
    assert env =~ "IMAGE_TAG=latest"
    assert env =~ "ADMIN_API_KEY_FILE=/run/local-secrets/admin_api_key"
    assert mode(Path.join(root, ".env")) == 0o600
  end

  test "env rejects missing or placeholder compose registry" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)

    assert {:error, error} = Secrets.env(root, %{})
    assert error.step == :secret_env
    assert error.message =~ "REGISTRY or SERVER_IP is required"

    assert {:error, error} = Secrets.env(root, %{"REGISTRY" => "<server-local-ip>:5000"})
    assert error.step == :secret_env
    assert error.message =~ "REGISTRY contains an unresolved placeholder"
  end

  test "env honors compose image overrides" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)

    assert {:ok, output} =
             Secrets.env(root, %{"REGISTRY" => "192.168.1.221:5000", "IMAGE_TAG" => "dev"})

    assert output =~ ".env"

    env = File.read!(Path.join(root, ".env"))
    assert env =~ "REGISTRY=192.168.1.221:5000"
    assert env =~ "IMAGE_TAG=dev"
    refute env =~ "<server-local-ip>"
  end

  test "env derives registry from server ip" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    assert {:ok, output} = Secrets.env(root, %{"SERVER_IP" => "192.168.1.221"})
    assert output =~ ".env"

    env = File.read!(Path.join(root, ".env"))
    assert env =~ "REGISTRY=192.168.1.221:5000"
    assert env =~ "IMAGE_TAG=latest"
    refute env =~ "<server-local-ip>"
  end

  defp token_value(contents, key) do
    contents
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        [^key, value] -> value
        _ -> nil
      end
    end)
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  defp tmp_repo do
    root =
      Path.join(System.tmp_dir!(), "wg-key-rotator-secrets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.touch!(Path.join(root, "docker-compose.yaml"))
    root
  end
end
