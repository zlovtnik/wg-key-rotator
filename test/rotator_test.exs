defmodule WgKeyRotatorTest do
  use ExUnit.Case, async: true

  alias WgKeyRotator.Config

  @private_key Base.encode64(:binary.copy(<<3>>, 32))
  @public_key Base.encode64(:binary.copy(<<4>>, 32))

  test "rotates key files, deploys, and sends notification" do
    root = tmp_repo()
    on_exit(fn -> File.rm_rf(root) end)

    private_path = Path.join(root, "config/server/privatekey-server")
    public_path = Path.join(root, "config/server/publickey-server")
    File.mkdir_p!(Path.dirname(private_path))
    File.touch!(Path.join(root, "docker-compose.yaml"))

    config = %Config{
      repo_root: root,
      private_key_path: private_path,
      public_key_path: public_path,
      waha_base_url: "http://waha.local",
      waha_session: "default",
      waha_chat_id: "12132132130@c.us",
      health_timeout_ms: 1000,
      include_public_key: true
    }

    runner = fn
      "wg", ["genkey"], _opts ->
        {@private_key <> "\n", 0}

      "sh", ["-c", cmd], _opts ->
        assert String.starts_with?(cmd, "wg pubkey < /")
        tmp_path = String.trim_leading(cmd, "wg pubkey < ")
        private_key = File.read!(tmp_path) |> String.trim()
        assert private_key == @private_key
        {@public_key <> "\n", 0}
    end

    test_pid = self()

    deploy_fun = fn cfg ->
      send(test_pid, {:deploy, cfg.repo_root})

      {:ok,
       %{deploy_output: "ok", ps_output: "ssl-proxy running", health: %{status: 200, body: "ok"}}}
    end

    notify_fun = fn _cfg, message ->
      send(test_pid, {:notify, message})
      {:ok, %{status: 200, body: "{}"}}
    end

    assert {:ok, result} =
             WgKeyRotator.rotate(config,
               runner: runner,
               deploy_fun: deploy_fun,
               notify_fun: notify_fun,
               now: ~U[2026-06-12 10:00:00Z]
             )

    assert File.read!(private_path) == @private_key <> "\n"
    assert File.read!(public_path) == @public_key <> "\n"
    assert result.public_key == @public_key
    assert_receive {:deploy, ^root}
    assert_receive {:notify, message}
    assert message =~ "WireGuard server key rotation complete"
    assert message =~ "server public key: #{@public_key}"
  end

  defp tmp_repo do
    Path.join(System.tmp_dir!(), "wg-key-rotator-repo-#{System.unique_integer([:positive])}")
  end
end
