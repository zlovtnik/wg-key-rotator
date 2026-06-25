defmodule WgKeyRotator.ConfigTest do
  use ExUnit.Case, async: true

  alias WgKeyRotator.Config

  test "loads repo and WAHA settings from environment" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "config/server"))
    File.touch!(Path.join(root, "docker-compose.yaml"))

    env = %{
      "ROTATOR_REPO_ROOT" => root,
      "WAHA_BASE_URL" => "http://waha.local",
      "WAHA_CHAT_ID" => "12132132130@c.us",
      "WAHA_SESSION" => "default",
      "ROTATOR_INCLUDE_PUBLIC_KEY" => "false",
      "ROTATOR_PEERS" => "peer1, peer3",
      "ROTATOR_HANDSHAKE_GRACE_SECS" => "120",
      "ROTATOR_NEXT_ADMIN_PORT" => "3019"
    }

    assert {:ok, config} = Config.load(env)
    assert config.repo_root == root
    assert config.private_key_path == Path.join(root, "config/server/privatekey-server")
    assert config.public_key_path == Path.join(root, "config/server/publickey-server")
    assert config.state_dir == Path.join(root, "secrets/wg-rotation")

    assert config.frontdoor_config_path ==
             Path.join(root, "secrets/wg-rotation/frontdoor/wg-udp-frontdoor.toml")

    assert config.peers == ["peer1", "peer3"]
    assert config.handshake_grace_secs == 120
    assert config.next_admin_port == 3019
    refute config.include_public_key
  end

  test "falls back to stack peer list when rotator peer list is blank" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "config/server"))
    File.touch!(Path.join(root, "docker-compose.yaml"))

    env = %{
      "ROTATOR_REPO_ROOT" => root,
      "WAHA_BASE_URL" => "http://waha.local",
      "WAHA_CHAT_ID" => "12132132130@c.us",
      "ROTATOR_PEERS" => "",
      "WG_PEERS" => "peer1,peer2,peer3"
    }

    assert {:ok, config} = Config.load(env)
    assert config.peers == ["peer1", "peer2", "peer3"]
  end

  test "rejects unsafe peer names" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "config/server"))
    File.touch!(Path.join(root, "docker-compose.yaml"))

    env = %{
      "ROTATOR_REPO_ROOT" => root,
      "WAHA_BASE_URL" => "http://waha.local",
      "WAHA_CHAT_ID" => "12132132130@c.us",
      "WG_PEERS" => "peer1,../server"
    }

    assert {:error, error} = Config.load(env)
    assert error.step == :peers
    assert error.details == "../server"
  end

  test "discovers repo root from current working directory" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    cwd = Path.join(root, "apps/wg-key-rotator")
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(root, "config/server"))
    File.touch!(Path.join(root, "docker-compose.yaml"))

    env = %{
      "WAHA_BASE_URL" => "http://waha.local",
      "WAHA_CHAT_ID" => "12132132130@c.us"
    }

    assert {:ok, config} = Config.load(env, cwd: cwd)
    assert config.repo_root == root
  end

  test "returns a clear error when repo root cannot be discovered" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:error, error} = Config.load(%{}, cwd: root, require_waha: false)
    assert error.step == :repo_root
    assert error.message == "could not discover repository root"
    assert error.details =~ "ROTATOR_REPO_ROOT"
  end

  test "loads WAHA API key from file" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "config/server"))
    File.touch!(Path.join(root, "docker-compose.yaml"))
    key_path = Path.join(root, "waha-key")
    File.write!(key_path, " file-secret \n")

    env = %{
      "ROTATOR_REPO_ROOT" => root,
      "WAHA_BASE_URL" => "http://waha.local",
      "WAHA_CHAT_ID" => "12132132130@c.us",
      "WAHA_API_KEY_FILE" => key_path
    }

    assert {:ok, config} = Config.load(env)
    assert config.waha_api_key == "file-secret"
  end

  test "requires WAHA settings for real runs" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "config/server"))
    File.touch!(Path.join(root, "docker-compose.yaml"))

    assert {:error, error} = Config.load(%{"ROTATOR_REPO_ROOT" => root})
    assert error.step == :waha_chat_id
  end

  defp tmp_repo do
    Path.join(System.tmp_dir!(), "wg-key-rotator-config-#{System.unique_integer([:positive])}")
  end
end
