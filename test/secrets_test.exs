defmodule WgKeyRotator.SecretsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias WgKeyRotator.Secrets

  @repo_marker Path.join(["apps", "wg-key-rotator", "mix.exs"])

  @secret_files [
    {"postgres.key", 0o600},
    {"minio_access_key.key", 0o600},
    {"minio_secret_key.key", 0o600},
    {"admin_api_key", 0o400},
    {"wg_obfuscation_key", 0o400},
    {"grafana_admin_password.key", 0o600},
    {"schema-migrator/encrypt_key.key", 0o600},
    {"schema-migrator/jwt_secret.key", 0o600},
    {"schema-migrator/api_bearer_token.key", 0o600},
    {"schema-migrator/state_db_password.key", 0o600},
    {"schema-migrator/keycloak_database_password.key", 0o600},
    {"schema-migrator/keycloak_bootstrap_admin_password.key", 0o600},
    {"schema-migrator/application_admin_password.key", 0o600},
    {"oracle_password.txt", 0o444},
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

    assert mode(Path.join(root, "secrets")) == 0o711

    assert File.read!(Path.join(root, "secrets/admin_api_key")) ==
             File.read!(Path.join(root, "secrets/wg-rotation/candidate/secrets/admin_api_key"))

    assert File.read!(Path.join(root, "secrets/wg_obfuscation_key")) ==
             File.read!(
               Path.join(root, "secrets/wg-rotation/candidate/secrets/wg_obfuscation_key")
             )

    token_file = Path.join(root, "secrets/ONE_TIME_TOKENS")
    assert mode(token_file) == 0o600
    raw_token = token_file |> File.read!() |> token_value("ATHEROS_API_TOKEN")

    schema_admin_password =
      token_file |> File.read!() |> token_value("SCHEMA_MIGRATOR_ADMIN_PASSWORD")

    expected_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)

    assert File.read!(Path.join(root, "secrets/atheros_api_token_sha256.key")) |> String.trim() ==
             expected_hash

    assert schema_admin_password ==
             File.read!(Path.join(root, "secrets/schema-migrator/application_admin_password.key"))
             |> String.trim()

    assert {:ok, encrypt_key} =
             Path.join(root, "secrets/schema-migrator/encrypt_key.key")
             |> File.read!()
             |> String.trim()
             |> Base.decode64()

    assert byte_size(encrypt_key) == 32
  end

  test "discovers and validates the current repository layout" do
    root = tmp_repo()
    nested = Path.join(root, "apps/wg-key-rotator")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, ^root} = Secrets.repo_root(%{}, nested)
    assert {:ok, ^root} = Secrets.repo_root(%{"ROTATOR_REPO_ROOT" => root}, "/")
  end

  test "rejects a root that only has the retired compose marker" do
    root = tmp_dir()
    on_exit(fn -> File.rm_rf(root) end)
    File.touch!(Path.join(root, "docker-compose.yaml"))

    assert {:error, error} =
             Secrets.repo_root(%{"ROTATOR_REPO_ROOT" => root}, "/")

    assert error.message == "repo root must contain #{@repo_marker}"
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

  test "repair fixes stale bootstrap candidate copies and permissions" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))

    candidate_dir = Path.join(root, "secrets/wg-rotation/candidate")
    candidate_secrets_dir = Path.join(candidate_dir, "secrets")
    candidate_admin = Path.join(candidate_secrets_dir, "admin_api_key")
    candidate_obfuscation = Path.join(candidate_secrets_dir, "wg_obfuscation_key")

    assert :ok = File.chmod(candidate_admin, 0o600)
    assert :ok = File.chmod(candidate_obfuscation, 0o600)
    File.write!(candidate_admin, "stale-admin\n")
    File.write!(candidate_obfuscation, "stale-obfuscation\n")
    assert :ok = File.chmod(candidate_dir, 0o775)
    assert :ok = File.chmod(candidate_secrets_dir, 0o775)

    assert {:error, error} = Secrets.check(root)
    assert error.details =~ "WRONG_PERMS"
    assert error.details =~ "MISMATCH"

    assert {:ok, "OK: repaired secret tree"} = Secrets.repair(root)
    assert {:ok, "OK: secret tree is complete"} = Secrets.check(root)

    assert mode(candidate_dir) == 0o700
    assert mode(candidate_secrets_dir) == 0o700
    assert mode(candidate_admin) == 0o400
    assert mode(candidate_obfuscation) == 0o400

    assert File.read!(candidate_admin) == File.read!(Path.join(root, "secrets/admin_api_key"))

    assert File.read!(candidate_obfuscation) ==
             File.read!(Path.join(root, "secrets/wg_obfuscation_key"))
  end

  test "repair syncs the active server public key into generated peer profiles" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))

    public_key = Base.encode64(:binary.copy(<<7>>, 32))
    server_dir = Path.join(root, "config/server")
    peer_dir = Path.join(root, "config/peer2")
    File.mkdir_p!(server_dir)
    File.mkdir_p!(peer_dir)
    File.write!(Path.join(server_dir, "publickey-server"), public_key <> "\n")

    for name <- ["peer2.conf", "peer2-obfuscated.conf"] do
      File.write!(
        Path.join(peer_dir, name),
        "[Interface]\nPrivateKey = private\n[Peer]\nPublicKey = <server-public-key>\n"
      )
    end

    assert {:ok, "OK: repaired secret tree"} = Secrets.repair(root)

    for name <- ["peer2.conf", "peer2-obfuscated.conf"] do
      path = Path.join(peer_dir, name)
      assert File.read!(path) =~ "PublicKey = #{public_key}"
      refute File.read!(path) =~ "<server-public-key>"
      assert mode(path) == 0o600
    end
  end

  test "repair creates missing Oracle password without rotating existing secrets" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))

    postgres_path = Path.join(root, "secrets/postgres.key")
    oracle_path = Path.join(root, "secrets/oracle_password.txt")
    original_postgres = File.read!(postgres_path)
    File.rm!(oracle_path)
    assert :ok = File.chmod(Path.join(root, "secrets"), 0o700)

    assert {:error, error} = Secrets.check(root)
    assert error.details =~ "MISSING #{oracle_path}"

    assert {:ok, "OK: repaired secret tree"} = Secrets.repair(root)
    assert {:ok, "OK: secret tree is complete"} = Secrets.check(root)
    assert File.read!(postgres_path) == original_postgres
    assert File.exists?(oracle_path)
    assert mode(oracle_path) == 0o444
    assert mode(Path.join(root, "secrets")) == 0o711
  end

  test "repair creates missing schema migrator state database password without rotating existing secrets" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))

    postgres_path = Path.join(root, "secrets/postgres.key")
    state_db_path = Path.join(root, "secrets/schema-migrator/state_db_password.key")
    original_postgres = File.read!(postgres_path)
    File.rm!(state_db_path)
    assert :ok = File.chmod(Path.join(root, "secrets"), 0o700)

    assert {:error, error} = Secrets.check(root)
    assert error.details =~ "MISSING #{state_db_path}"

    assert {:ok, "OK: repaired secret tree"} = Secrets.repair(root)
    assert {:ok, "OK: secret tree is complete"} = Secrets.check(root)
    assert File.read!(postgres_path) == original_postgres
    assert File.exists?(state_db_path)
    assert mode(state_db_path) == 0o600
    assert mode(Path.join(root, "secrets")) == 0o711
  end

  test "repair adds missing schema migrator secrets and emits the temporary administrator password" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))

    schema_dir = Path.join(root, "secrets/schema-migrator")
    File.rm_rf!(schema_dir)

    assert {:error, error} = Secrets.check(root)
    assert error.details =~ "schema-migrator/application_admin_password.key"

    assert {:error, error} = Secrets.repair(root)
    assert error.details =~ "ONE_TIME_TOKENS_PRESENT"

    token_file = Path.join(root, "secrets/ONE_TIME_TOKENS")
    assert File.exists?(token_file)

    assert token_value(File.read!(token_file), "SCHEMA_MIGRATOR_ADMIN_PASSWORD") ==
             File.read!(Path.join(schema_dir, "application_admin_password.key")) |> String.trim()

    File.rm!(token_file)
    assert {:ok, "OK: secret tree is complete"} = Secrets.check(root)
  end

  test "repair preserves pending generation candidate secrets" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _output} = Secrets.generate(root)
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))

    generation_secrets = Path.join(root, "secrets/wg-rotation/generations/gen1/secrets")
    File.mkdir_p!(generation_secrets)
    generation_admin = Path.join(generation_secrets, "admin_api_key")
    generation_obfuscation = Path.join(generation_secrets, "wg_obfuscation_key")
    File.write!(generation_admin, "pending-admin\n")
    File.write!(generation_obfuscation, "pending-obfuscation\n")
    assert :ok = File.chmod(generation_admin, 0o400)
    assert :ok = File.chmod(generation_obfuscation, 0o400)

    state_dir = Path.join(root, "secrets/wg-rotation/state")
    File.mkdir_p!(state_dir)
    File.write!(Path.join(state_dir, "pending_generation"), "gen1\n")

    candidate_secrets_dir = Path.join(root, "secrets/wg-rotation/candidate/secrets")
    candidate_admin = Path.join(candidate_secrets_dir, "admin_api_key")
    candidate_obfuscation = Path.join(candidate_secrets_dir, "wg_obfuscation_key")

    assert :ok = File.chmod(candidate_admin, 0o600)
    assert :ok = File.chmod(candidate_obfuscation, 0o600)
    File.write!(candidate_admin, "stale-admin\n")
    File.write!(candidate_obfuscation, "stale-obfuscation\n")

    assert {:error, error} = Secrets.check(root)
    assert error.details =~ "MISMATCH"

    assert {:ok, "OK: repaired secret tree"} = Secrets.repair(root)
    assert {:ok, "OK: secret tree is complete"} = Secrets.check(root)
    assert File.read!(candidate_admin) == "pending-admin\n"
    assert File.read!(candidate_obfuscation) == "pending-obfuscation\n"
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
    root = tmp_dir()
    marker = Path.join(root, @repo_marker)
    File.mkdir_p!(Path.dirname(marker))
    File.touch!(marker)
    root
  end

  defp tmp_dir do
    root =
      Path.join(System.tmp_dir!(), "wg-key-rotator-secrets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root
  end
end
