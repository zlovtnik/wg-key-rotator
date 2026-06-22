defmodule WgKeyRotator.RotationTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias WgKeyRotator.{Config, Rotation}

  @now ~U[2026-06-22 10:00:00Z]
  @server_private Base.encode64(:binary.copy(<<10>>, 32))
  @server_public Base.encode64(:binary.copy(<<11>>, 32))
  @peer1_private Base.encode64(:binary.copy(<<12>>, 32))
  @peer1_public Base.encode64(:binary.copy(<<13>>, 32))
  @peer1_psk Base.encode64(:binary.copy(<<14>>, 32))
  @peer2_private Base.encode64(:binary.copy(<<15>>, 32))
  @peer2_public Base.encode64(:binary.copy(<<16>>, 32))
  @peer2_psk Base.encode64(:binary.copy(<<17>>, 32))

  test "stage writes candidate artifacts with strict modes and safe notification" do
    {root, config} = repo_config()
    on_exit(fn -> File.rm_rf(root) end)

    config = %{
      config
      | waha_base_url: "http://waha.local",
        waha_session: "default",
        waha_chat_id: "12132132130@c.us"
    }

    test_pid = self()

    assert {:ok, result} =
             Rotation.stage(config,
               runner: key_runner(),
               generation_id: "gen1",
               now: @now,
               notify_fun: fn _config, message, _opts ->
                 send(test_pid, {:notification, message})
                 {:ok, %{status: 200, body: "{}"}}
               end
             )

    assert result.status == :staged
    assert result.peer_count == 2
    assert File.read!(Path.join(config.state_dir, "state/pending_generation")) == "gen1\n"

    candidate = Path.join(config.state_dir, "candidate")

    assert File.read!(Path.join(candidate, "config/server/privatekey-server")) ==
             @server_private <> "\n"

    assert File.read!(Path.join(candidate, "config/peer1/publickey-peer1")) ==
             @peer1_public <> "\n"

    assert File.read!(Path.join(candidate, "config/peer1/presharedkey-peer1")) ==
             @peer1_psk <> "\n"

    assert mode(Path.join(candidate, "config/server/privatekey-server")) == 0o600
    assert mode(Path.join(candidate, "secrets/admin_api_key")) == 0o400
    assert mode(Path.join(candidate, "client-bundles/peer1/peer1.conf")) == 0o600

    assert_receive {:notification, message}
    assert message =~ "rotation staged"
    refute message =~ @server_private
    refute message =~ @peer1_private
    refute message =~ @peer1_psk
  end

  test "start-next installs candidate frontdoor config and runs rotation compose profile" do
    {root, config} = repo_config()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _} =
             Rotation.stage(config, runner: key_runner(), generation_id: "gen1", now: @now)

    test_pid = self()

    runner = fn command, args, opts ->
      send(test_pid, {:command, command, args, opts})
      {"started", 0}
    end

    assert {:ok, result} = Rotation.start_next(config, runner: runner)
    assert result.status == :candidate_started
    assert File.read!(config.frontdoor_config_path) =~ ~s(candidate-443")
    assert File.read!(config.frontdoor_config_path) =~ "enabled = true"

    assert_receive {:command, "docker",
                    [
                      "compose",
                      "--profile",
                      "rotation",
                      "up",
                      "-d",
                      "--build",
                      "ssl-proxy-next",
                      "wg-udp-frontdoor"
                    ], opts}

    assert opts[:cd] == root
  end

  test "scheduled run does not stage another generation while one is pending" do
    {root, config} = repo_config()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _} =
             Rotation.stage(config, runner: key_runner(), generation_id: "gen1", now: @now)

    assert {:ok, result} =
             Rotation.scheduled(config,
               now_epoch: 100,
               dump_fun: fn -> {:ok, dump(%{@peer1_public => 0, @peer2_public => 0})} end,
               runner: fn command, _args, _opts ->
                 flunk("unexpected command while pending: #{command}")
               end
             )

    assert result.status == :pending
    assert result.generation_id == "gen1"
  end

  test "promote enforces all-peer handshake gate then installs active files" do
    {root, config} = repo_config()
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _} =
             Rotation.stage(config, runner: key_runner(), generation_id: "gen1", now: @now)

    stale_dump = dump(%{@peer1_public => 90, @peer2_public => 0})

    assert {:error, error} =
             Rotation.promote(config,
               runner: docker_runner(),
               dump_fun: fn -> {:ok, stale_dump} end,
               now_epoch: 100,
               health_get: fn _url, _timeout -> {:ok, %{status: 200, body: "ok"}} end
             )

    assert error.step == :promotion_gate
    assert error.details == "peer2"

    ready_dump = dump(%{@peer1_public => 99, @peer2_public => 98})

    assert {:ok, result} =
             Rotation.promote(config,
               runner: docker_runner(),
               dump_fun: fn -> {:ok, ready_dump} end,
               now_epoch: 100,
               health_get: fn _url, _timeout -> {:ok, %{status: 200, body: "ok"}} end
             )

    assert result.status == :promoted

    assert File.read!(Path.join(root, "config/server/privatekey-server")) ==
             @server_private <> "\n"

    assert File.read!(Path.join(root, "config/peer2/presharedkey-peer2")) == @peer2_psk <> "\n"
    assert File.exists?(Path.join(root, "secrets/admin_api_key"))
    assert File.read!(Path.join(config.state_dir, "state/active_generation")) == "gen1\n"
    refute File.exists?(Path.join(config.state_dir, "state/pending_generation"))
    assert File.read!(config.frontdoor_config_path) =~ "candidate-443"
    assert File.read!(config.frontdoor_config_path) =~ "enabled = false"
  end

  defp repo_config do
    root = tmp_repo()
    File.mkdir_p!(Path.join(root, "config/peer1"))
    File.mkdir_p!(Path.join(root, "config/peer2"))
    File.mkdir_p!(Path.join(root, "config/server"))
    File.touch!(Path.join(root, "docker-compose.yaml"))

    File.write!(Path.join(root, "config/peer1/peer1.conf"), peer_conf("10.13.13.2/32"))

    File.write!(
      Path.join(root, "config/peer1/peer1-obfuscated.conf.example"),
      peer_conf("10.13.13.2/32")
    )

    File.write!(
      Path.join(root, "config/peer2/peer2-obfuscated.conf.example"),
      peer_conf("10.13.13.3/32")
    )

    config = %Config{
      repo_root: root,
      private_key_path: Path.join(root, "config/server/privatekey-server"),
      public_key_path: Path.join(root, "config/server/publickey-server"),
      state_dir: Path.join(root, "secrets/wg-rotation"),
      peers: ["peer1", "peer2"],
      migration_timeout_secs: 86_400,
      handshake_grace_secs: 600,
      frontdoor_config_path:
        Path.join(root, "secrets/wg-rotation/frontdoor/wg-udp-frontdoor.toml"),
      next_admin_port: 3012,
      health_url: "http://127.0.0.1:3002/health",
      health_timeout_ms: 1000
    }

    {root, config}
  end

  defp peer_conf(address) do
    """
    [Interface]
    Address = #{address}
    PrivateKey = #{Base.encode64(:binary.copy(<<1>>, 32))}
    ListenPort = 443
    MTU = 1280
    DNS = 10.13.13.1

    [Peer]
    PublicKey = #{Base.encode64(:binary.copy(<<2>>, 32))}
    PresharedKey = #{Base.encode64(:binary.copy(<<3>>, 32))}
    Endpoint = 127.0.0.1:51821
    AllowedIPs = 0.0.0.0/0, ::/0
    """
  end

  defp key_runner do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          private_keys: [@server_private, @peer1_private, @peer2_private],
          psks: [@peer1_psk, @peer2_psk]
        }
      end)

    pubkeys = %{
      @server_private => @server_public,
      @peer1_private => @peer1_public,
      @peer2_private => @peer2_public
    }

    fn
      "wg", ["genkey"], _opts ->
        Agent.get_and_update(agent, fn state ->
          [key | rest] = state.private_keys
          {key <> "\n", %{state | private_keys: rest}}
        end)
        |> then(&{&1, 0})

      "sh", ["-c", cmd], _opts ->
        # wg pubkey < tmp_path -> reads key from temp file written by Keygen.pubkey/2
        "wg pubkey < '" <> quoted_path = cmd
        tmp_path = String.trim_trailing(quoted_path, "'")
        private_key = File.read!(tmp_path) |> String.trim()
        {Map.fetch!(pubkeys, private_key) <> "\n", 0}

      "wg", ["genpsk"], _opts ->
        Agent.get_and_update(agent, fn state ->
          [key | rest] = state.psks
          {key <> "\n", %{state | psks: rest}}
        end)
        |> then(&{&1, 0})
    end
  end

  defp docker_runner do
    fn
      "docker", ["compose", "up", "-d", "--build", "ssl-proxy"], _opts ->
        {"deploy ok", 0}

      "docker", ["compose", "ps", "ssl-proxy"], _opts ->
        {"ssl-proxy running", 0}

      "docker", ["compose", "--profile", "rotation", "stop", "ssl-proxy-next"], _opts ->
        {"stopped", 0}
    end
  end

  defp dump(handshakes) do
    interface = "#{@server_private}\t#{@server_public}\t51820\toff"

    peers =
      Enum.map_join(handshakes, "\n", fn {public_key, handshake} ->
        "#{public_key}\tpsk\t198.51.100.10:443\t10.13.13.2/32\t#{handshake}\t1\t2\t25"
      end)

    interface <> "\n" <> peers <> "\n"
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  defp tmp_repo do
    Path.join(System.tmp_dir!(), "wg-key-rotator-rotation-#{System.unique_integer([:positive])}")
  end
end
