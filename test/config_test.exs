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
      "ROTATOR_INCLUDE_PUBLIC_KEY" => "false"
    }

    assert {:ok, config} = Config.load(env)
    assert config.repo_root == root
    assert config.private_key_path == Path.join(root, "config/server/privatekey-server")
    assert config.public_key_path == Path.join(root, "config/server/publickey-server")
    refute config.include_public_key
  end

  test "requires WAHA settings for real runs" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, "config/server"))
    File.touch!(Path.join(root, "docker-compose.yaml"))

    assert {:error, error} = Config.load(%{"ROTATOR_REPO_ROOT" => root})
    assert error.step == :waha_base_url
  end

  defp tmp_repo do
    Path.join(System.tmp_dir!(), "wg-key-rotator-config-#{System.unique_integer([:positive])}")
  end
end
