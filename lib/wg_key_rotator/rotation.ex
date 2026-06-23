defmodule WgKeyRotator.Rotation do
  @moduledoc """
  Orchestrates WireGuard key rotation: staging a new generation,
  starting the next runtime, checking migration status, promoting or
  rolling back, and sending WhatsApp notifications via WAHA.
  """

  import Bitwise

  alias WgKeyRotator.{AtomicFile, Command, Config, Deploy, Error, Keygen, PeerConfig, WahaClient}

  @pending_marker "state/pending_generation"
  @active_marker "state/active_generation"
  @created_marker "created_at"

  def stage(%Config{} = config, opts \\ []) do
    runner = Keyword.get(opts, :runner, &Command.system_runner/3)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    generation_id = Keyword.get(opts, :generation_id, generation_id(now))

    with :ok <- ensure_no_pending(config),
         {:ok, peers} <- discover_peers(config),
         {:ok, server_keys} <- Keygen.generate(runner),
         {:ok, peer_artifacts} <- generate_peer_artifacts(peers, server_keys.public_key, runner),
         :ok <- write_generation(config, generation_id, now, server_keys, peer_artifacts),
         :ok <- mirror_candidate(config, generation_id),
         :ok <- write_marker(config, @pending_marker, generation_id) do
      result = %{
        generation_id: generation_id,
        status: :staged,
        peer_count: length(peer_artifacts),
        candidate_dir: candidate_dir(config),
        bundle_dir: Path.join(generation_dir(config, generation_id), "client-bundles")
      }

      notify_event(config, result, opts)
      {:ok, result}
    end
  end

  def start_next(%Config{} = config, opts \\ []) do
    runner = Keyword.get(opts, :runner, &Command.system_runner/3)

    with {:ok, generation_id} <- pending_generation(config),
         :ok <- ensure_active_runtime_secrets(config),
         :ok <- install_frontdoor_config(config, generation_id, :candidate),
         {:ok, pull_output} <- pull_next_runtime(config, runner),
         {:ok, start_output} <- start_next_runtime(config, runner) do
      result = %{
        generation_id: generation_id,
        status: :candidate_started,
        output: join_output(pull_output, start_output)
      }

      notify_event(config, result, opts)
      {:ok, result}
    end
  end

  defp pull_next_runtime(config, runner) do
    Command.run(
      runner,
      "docker",
      ["compose", "--profile", "rotation", "pull", "ssl-proxy-next", "wg-udp-frontdoor"],
      [cd: config.repo_root, stderr_to_stdout: true, timeout_ms: config.command_timeout_ms],
      :pull_next
    )
  end

  defp start_next_runtime(config, runner) do
    Command.run(
      runner,
      "docker",
      ["compose", "--profile", "rotation", "up", "-d", "ssl-proxy-next", "wg-udp-frontdoor"],
      [cd: config.repo_root, stderr_to_stdout: true, timeout_ms: config.command_timeout_ms],
      :start_next
    )
  end

  def status(%Config{} = config, opts \\ []) do
    now_epoch = Keyword.get(opts, :now_epoch, System.system_time(:second))

    pending =
      case pending_generation(config) do
        {:ok, generation_id} ->
          migration =
            case migration_status(config, generation_id, opts) do
              {:ok, migration} -> migration
              {:error, error} -> %{error: Error.format(error), peers: []}
            end

          %{generation_id: generation_id, migration: migration}

        {:error, _error} ->
          nil
      end

    active =
      case marker(config, @active_marker) do
        {:ok, generation_id} -> generation_id
        {:error, _error} -> nil
      end

    {:ok, %{status: :ok, active_generation: active, pending: pending, checked_at: now_epoch}}
  end

  def promote(%Config{} = config, opts \\ []) do
    runner = Keyword.get(opts, :runner, &Command.system_runner/3)

    with {:ok, generation_id} <- pending_generation(config),
         {:ok, migration} <- migration_status(config, generation_id, opts),
         :ok <- require_all_peers_migrated(migration),
         :ok <- install_candidate_config(config, generation_id),
         :ok <- install_active_secrets(config, generation_id),
         {:ok, deploy_result} <- Deploy.run(config, opts),
         :ok <- install_frontdoor_config(config, generation_id, :active),
         :ok <- stop_next(config, runner),
         :ok <- write_marker(config, @active_marker, generation_id),
         :ok <- clear_pending(config) do
      result = %{
        generation_id: generation_id,
        status: :promoted,
        migration: migration,
        deploy: deploy_result
      }

      notify_event(config, result, opts)
      {:ok, result}
    end
  end

  def rollback(%Config{} = config, opts \\ []) do
    runner = Keyword.get(opts, :runner, &Command.system_runner/3)

    with {:ok, generation_id} <- pending_generation(config),
         :ok <- install_frontdoor_config(config, generation_id, :active),
         :ok <- stop_next(config, runner),
         :ok <- clear_pending(config) do
      result = %{generation_id: generation_id, status: :rolled_back}
      notify_event(config, result, opts)
      {:ok, result}
    end
  end

  def scheduled(%Config{} = config, opts \\ []) do
    case pending_generation(config) do
      {:ok, generation_id} ->
        with :ok <- ensure_not_expired(config, generation_id, opts),
             :ok <- ensure_active_runtime_secrets(config) do
          handle_existing_generation(config, generation_id, opts)
        end

      {:error, _error} ->
        stage_and_start_next(config, opts)
    end
  end

  defp handle_existing_generation(config, generation_id, opts) do
    case migration_status(config, generation_id, opts) do
      {:ok, migration} ->
        if Enum.all?(migration.peers, & &1.migrated?) do
          promote(config, opts)
        else
          {:ok, %{generation_id: generation_id, status: :pending, migration: migration}}
        end

      {:error, error} ->
        if candidate_unavailable?(error) do
          start_next(config, opts)
        else
          {:error, error}
        end
    end
  end

  defp stage_and_start_next(config, opts) do
    with {:ok, _stage_result} <- stage(config, opts) do
      start_next(config, opts)
    end
  end

  def render_result(%{status: :ok} = result) do
    pending =
      case result.pending do
        nil ->
          "pending: none"

        pending ->
          migrated = Enum.count(pending.migration.peers, & &1.migrated?)
          total = length(pending.migration.peers)
          "pending: #{pending.generation_id} peers=#{migrated}/#{total}"
      end

    ["rotation status", "active: #{result.active_generation || "none"}", pending]
    |> Enum.join("\n")
  end

  def render_result(result) do
    lines = [
      "rotation #{result.status}",
      "generation: #{result.generation_id}"
    ]

    lines =
      if Map.has_key?(result, :peer_count) do
        lines ++ ["peers: #{result.peer_count}", "bundles: #{result.bundle_dir}"]
      else
        lines
      end

    lines =
      if Map.has_key?(result, :migration) do
        migrated = Enum.count(result.migration.peers, & &1.migrated?)
        total = length(result.migration.peers)
        lines ++ ["migrated peers: #{migrated}/#{total}"]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp ensure_no_pending(config) do
    case pending_generation(config) do
      {:ok, generation_id} ->
        {:error,
         %Error{
           step: :rotation_state,
           message: "pending generation already exists",
           details: generation_id
         }}

      {:error, _error} ->
        :ok
    end
  end

  defp ensure_not_expired(config, generation_id, opts) do
    now_epoch = Keyword.get(opts, :now_epoch, System.system_time(:second))
    created_path = Path.join(generation_dir(config, generation_id), @created_marker)

    with {:ok, created_at} <- File.read(created_path),
         {:ok, created_at, _offset} <- DateTime.from_iso8601(String.trim(created_at)) do
      age = now_epoch - DateTime.to_unix(created_at)

      if age <= config.migration_timeout_secs do
        :ok
      else
        {:error,
         %Error{
           step: :migration_timeout,
           message: "pending generation exceeded migration timeout",
           details: generation_id
         }}
      end
    else
      {:error, reason} -> file_error(:migration_timeout, created_path, reason)
    end
  end

  defp discover_peers(config) do
    peers =
      config.peers
      |> Enum.map(&discover_peer(config, &1))
      |> Enum.reject(&is_nil/1)

    if peers == [] do
      {:error,
       %Error{
         step: :peer_discovery,
         message: "no peer configs found",
         details: Enum.join(config.peers, ",")
       }}
    else
      {:ok, peers}
    end
  end

  defp discover_peer(config, name) do
    dir = Path.join([config.repo_root, "config", name])
    direct = Path.join(dir, "#{name}.conf")
    obfuscated = Path.join(dir, "#{name}-obfuscated.conf")
    obfuscated_example = Path.join(dir, "#{name}-obfuscated.conf.example")
    public_key_path = Path.join(dir, "publickey-#{name}")
    preshared_key_path = Path.join(dir, "presharedkey-#{name}")

    source =
      cond do
        File.exists?(direct) -> direct
        File.exists?(obfuscated) -> obfuscated
        File.exists?(obfuscated_example) -> obfuscated_example
        true -> nil
      end

    if source do
      contents = File.read!(source)

      %{
        name: name,
        dir: dir,
        direct_path: direct,
        obfuscated_path: obfuscated,
        obfuscated_example_path: obfuscated_example,
        source_path: source,
        source_contents: contents,
        address: PeerConfig.value(contents, "Interface", "Address"),
        public_key_path: public_key_path,
        preshared_key_path: preshared_key_path
      }
    end
  end

  defp generate_peer_artifacts(peers, server_public_key, runner) do
    Enum.reduce_while(peers, {:ok, []}, fn peer, {:ok, acc} ->
      with {:ok, keys} <- Keygen.generate(runner),
           {:ok, preshared_key} <- Keygen.generate_psk(runner) do
        artifact =
          peer
          |> Map.put(:private_key, keys.private_key)
          |> Map.put(:public_key, keys.public_key)
          |> Map.put(:preshared_key, preshared_key)
          |> Map.put(:server_public_key, server_public_key)

        {:cont, {:ok, [artifact | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  defp write_generation(config, generation_id, now, server_keys, peers) do
    dir = generation_dir(config, generation_id)

    with :ok <- File.mkdir_p(dir),
         :ok <-
           write_text(Path.join(dir, @created_marker), DateTime.to_iso8601(now) <> "\n", 0o644),
         :ok <-
           write_text(
             Path.join(dir, "config/server/privatekey-server"),
             server_keys.private_key <> "\n",
             0o600
           ),
         :ok <-
           write_text(
             Path.join(dir, "config/server/publickey-server"),
             server_keys.public_key <> "\n",
             0o644
           ),
         :ok <- write_peer_artifacts(dir, peers),
         :ok <- write_rotation_secrets(dir),
         :ok <-
           write_frontdoor_config(Path.join(dir, "frontdoor/wg-udp-frontdoor.toml"), :candidate),
         do: :ok
  end

  defp write_peer_artifacts(dir, peers) do
    Enum.reduce_while(peers, :ok, fn peer, :ok ->
      peer_dir = Path.join([dir, "config", peer.name])
      bundle_dir = Path.join([dir, "client-bundles", peer.name])

      direct =
        render_peer_config(
          peer.source_contents,
          peer.private_key,
          peer.server_public_key,
          peer.preshared_key
        )

      obfuscated_source =
        cond do
          File.exists?(peer.obfuscated_example_path) -> File.read!(peer.obfuscated_example_path)
          File.exists?(peer.obfuscated_path) -> File.read!(peer.obfuscated_path)
          true -> peer.source_contents
        end

      obfuscated =
        render_peer_config(
          obfuscated_source,
          peer.private_key,
          peer.server_public_key,
          peer.preshared_key
        )

      case write_peer_files(peer, peer_dir, bundle_dir, direct, obfuscated) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp write_peer_files(peer, peer_dir, bundle_dir, direct, obfuscated) do
    with :ok <- write_text(Path.join(peer_dir, "#{peer.name}.conf"), direct, 0o600),
         :ok <-
           write_text(Path.join(peer_dir, "#{peer.name}-obfuscated.conf"), obfuscated, 0o600),
         :ok <-
           write_text(
             Path.join(peer_dir, "publickey-#{peer.name}"),
             peer.public_key <> "\n",
             0o644
           ),
         :ok <-
           write_text(
             Path.join(peer_dir, "presharedkey-#{peer.name}"),
             peer.preshared_key <> "\n",
             0o600
           ),
         :ok <- write_text(Path.join(bundle_dir, "#{peer.name}.conf"), direct, 0o600),
         :ok <-
           write_text(
             Path.join(bundle_dir, "#{peer.name}-obfuscated.conf"),
             obfuscated,
             0o600
           ),
         do: :ok
  end

  defp render_peer_config(contents, private_key, server_public_key, preshared_key) do
    contents
    |> PeerConfig.replace_values([
      {"Interface", "PrivateKey", private_key},
      {"Peer", "PublicKey", server_public_key},
      {"Peer", "PresharedKey", preshared_key}
    ])
    |> ensure_trailing_newline()
  end

  defp write_rotation_secrets(dir) do
    with :ok <-
           write_text(
             Path.join(dir, "secrets/admin_api_key"),
             Keygen.random_secret(32, :url_base64) <> "\n",
             0o400
           ),
         :ok <-
           write_text(
             Path.join(dir, "secrets/wg_obfuscation_key"),
             Keygen.random_secret(32, :base64) <> "\n",
             0o400
           ),
         do: :ok
  end

  defp ensure_active_runtime_secrets(config) do
    with :ok <-
           ensure_secret_file(
             Path.join(config.repo_root, "secrets/admin_api_key"),
             fn -> Keygen.random_secret(32, :url_base64) <> "\n" end,
             0o400
           ),
         :ok <-
           ensure_secret_file(
             Path.join(config.repo_root, "secrets/wg_obfuscation_key"),
             fn -> Keygen.random_secret(32, :base64) <> "\n" end,
             0o400
           ),
         do: :ok
  end

  defp ensure_secret_file(path, value_fun, mode) do
    cond do
      File.exists?(path) and File.regular?(path) and mode(path) == mode ->
        :ok

      File.exists?(path) ->
        write_text(path, value_fun.(), mode)

      true ->
        write_text(path, value_fun.(), mode)
    end
  end

  defp mirror_candidate(config, generation_id) do
    source = generation_dir(config, generation_id)
    target = candidate_dir(config)

    with {:ok, _} <- File.rm_rf(target),
         :ok <- File.mkdir_p(Path.dirname(target)) do
      case File.cp_r(source, target) do
        {:ok, _files} ->
          :ok

        {:error, reason, path} ->
          {:error,
           %Error{
             step: :candidate_state,
             message: "failed to mirror candidate generation",
             details: "#{path}: #{inspect(reason)}"
           }}
      end
    end
  end

  defp install_candidate_config(config, generation_id) do
    dir = generation_dir(config, generation_id)

    files = [
      {"config/server/privatekey-server", "config/server/privatekey-server", 0o600},
      {"config/server/publickey-server", "config/server/publickey-server", 0o644}
    ]

    peer_files =
      config.peers
      |> Enum.flat_map(fn peer ->
        [
          {"config/#{peer}/#{peer}.conf", "config/#{peer}/#{peer}.conf", 0o600},
          {"config/#{peer}/#{peer}-obfuscated.conf", "config/#{peer}/#{peer}-obfuscated.conf",
           0o600},
          {"config/#{peer}/publickey-#{peer}", "config/#{peer}/publickey-#{peer}", 0o644},
          {"config/#{peer}/presharedkey-#{peer}", "config/#{peer}/presharedkey-#{peer}", 0o600}
        ]
      end)

    copy_files(dir, config.repo_root, files ++ peer_files)
  end

  defp install_active_secrets(config, generation_id) do
    dir = generation_dir(config, generation_id)

    copy_files(dir, config.repo_root, [
      {"secrets/admin_api_key", "secrets/admin_api_key", 0o400},
      {"secrets/wg_obfuscation_key", "secrets/wg_obfuscation_key", 0o400}
    ])
  end

  defp copy_file(source_path, target_path, mode) do
    case File.read(source_path) do
      {:ok, contents} -> write_text(target_path, contents, mode)
      {:error, reason} -> file_error(:copy_file, source_path, reason)
    end
  end

  defp copy_files(source_root, target_root, files) do
    Enum.reduce_while(files, :ok, fn {source, target, mode}, :ok ->
      source_path = Path.join(source_root, source)
      target_path = Path.join(target_root, target)

      result =
        if File.exists?(source_path) do
          copy_file(source_path, target_path, mode)
        else
          :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp stop_next(config, runner) do
    case Command.run(
           runner,
           "docker",
           ["compose", "--profile", "rotation", "stop", "ssl-proxy-next"],
           [cd: config.repo_root, stderr_to_stdout: true, timeout_ms: config.command_timeout_ms],
           :stop_next
         ) do
      {:ok, _output} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp migration_status(config, generation_id, opts) do
    now_epoch = Keyword.get(opts, :now_epoch, System.system_time(:second))
    dump_fun = Keyword.get(opts, :dump_fun, fn -> candidate_dump(config, opts) end)

    with {:ok, peers} <- candidate_public_keys(config, generation_id),
         {:ok, dump} <- dump_fun.() do
      handshakes = parse_dump(dump)

      peer_status =
        Enum.map(peers, fn peer ->
          handshake_epoch = Map.get(handshakes, peer.public_key, 0)
          age = max(now_epoch - handshake_epoch, 0)

          %{
            name: peer.name,
            public_key: peer.public_key,
            latest_handshake_epoch: handshake_epoch,
            handshake_age_secs: if(handshake_epoch == 0, do: nil, else: age),
            migrated?: handshake_epoch > 0 and age <= config.handshake_grace_secs
          }
        end)

      {:ok,
       %{
         generation_id: generation_id,
         checked_at_epoch: now_epoch,
         handshake_grace_secs: config.handshake_grace_secs,
         peers: peer_status
       }}
    end
  end

  defp candidate_dump(config, opts) do
    runner = Keyword.get(opts, :runner, &Command.system_runner/3)

    Command.run(
      runner,
      "docker",
      ["compose", "exec", "-T", "ssl-proxy-next", "/app/ssl-proxy", "boringtun", "dump", "wg1"],
      [cd: config.repo_root, stderr_to_stdout: true, timeout_ms: config.command_timeout_ms],
      :candidate_dump
    )
  end

  defp candidate_unavailable?(%Error{step: :candidate_dump, details: details}) do
    details = to_string(details || "")

    String.contains?(details, "service \"ssl-proxy-next\" is not running") or
      String.contains?(details, "is restarting") or
      String.contains?(details, "No such container")
  end

  defp candidate_unavailable?(_error), do: false

  defp candidate_public_keys(config, generation_id) do
    peers =
      config.peers
      |> Enum.map(fn peer ->
        path =
          Path.join([generation_dir(config, generation_id), "config", peer, "publickey-#{peer}"])

        if File.exists?(path) do
          %{name: peer, public_key: path |> File.read!() |> String.trim()}
        end
      end)
      |> Enum.reject(&is_nil/1)

    if peers == [] do
      {:error,
       %Error{
         step: :candidate_state,
         message: "candidate generation has no peer public keys",
         details: generation_id
       }}
    else
      {:ok, peers}
    end
  end

  defp parse_dump(dump) do
    dump
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.reduce(%{}, fn line, acc ->
      fields = String.split(line, "\t")

      case fields do
        [public_key, _psk, _endpoint, _allowed_ips, latest_handshake | _rest] ->
          Map.put(acc, public_key, parse_epoch(latest_handshake))

        _ ->
          acc
      end
    end)
  end

  defp parse_epoch(value) do
    case Integer.parse(String.trim(value)) do
      {epoch, ""} when epoch >= 0 -> epoch
      _ -> 0
    end
  end

  defp require_all_peers_migrated(migration) do
    pending = Enum.reject(migration.peers, & &1.migrated?)

    if pending == [] do
      :ok
    else
      names = Enum.map_join(pending, ",", & &1.name)

      {:error,
       %Error{
         step: :promotion_gate,
         message: "not all peers have a recent candidate handshake",
         details: names
       }}
    end
  end

  defp install_frontdoor_config(config, generation_id, mode) do
    source =
      case mode do
        :candidate ->
          Path.join(generation_dir(config, generation_id), "frontdoor/wg-udp-frontdoor.toml")

        :active ->
          nil
      end

    if source do
      source
      |> File.read()
      |> case do
        {:ok, contents} -> write_text(config.frontdoor_config_path, contents, 0o644)
        {:error, reason} -> file_error(:frontdoor_config, source, reason)
      end
    else
      write_frontdoor_config(config.frontdoor_config_path, :active)
    end
  end

  defp write_frontdoor_config(path, mode) do
    listeners =
      case mode do
        :active ->
          [
            {"wg-public-443", "0.0.0.0:443", ["active-443"]},
            {"wg-public-51820", "0.0.0.0:51820", ["active-51820"]}
          ]

        :candidate ->
          [
            {"wg-public-443", "0.0.0.0:443", ["active-443", "candidate-443"]},
            {"wg-public-51820", "0.0.0.0:51820", ["active-51820", "candidate-51820"]}
          ]
      end

    contents =
      [
        "# Generated by wg-key-rotator. Safe to replace with a newer generated file.",
        "",
        Enum.map_join(listeners, "\n\n", fn {name, bind_addr, backends} ->
          backends = Enum.map_join(backends, ", ", &~s("#{&1}"))

          """
          [[listeners]]
          name = "#{name}"
          bind_addr = "#{bind_addr}"
          backends = [#{backends}]
          """
          |> String.trim()
        end),
        "",
        backend_toml("active-443", "ssl-proxy:443", true),
        backend_toml("active-51820", "ssl-proxy:51820", true),
        backend_toml("candidate-443", "ssl-proxy-next:443", mode == :candidate),
        backend_toml("candidate-51820", "ssl-proxy-next:51820", mode == :candidate)
      ]
      |> Enum.join("\n")
      |> ensure_trailing_newline()

    write_text(path, contents, 0o644)
  end

  defp backend_toml(name, addr, enabled) do
    """
    [[backends]]
    name = "#{name}"
    addr = "#{addr}"
    enabled = #{enabled}
    """
    |> String.trim()
  end

  defp write_marker(config, marker, value) do
    write_text(Path.join(config.state_dir, marker), value <> "\n", 0o644)
  end

  defp clear_pending(config) do
    path = Path.join(config.state_dir, @pending_marker)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> file_error(:rotation_state, path, reason)
    end
  end

  defp pending_generation(config), do: marker(config, @pending_marker)

  defp marker(config, marker) do
    path = Path.join(config.state_dir, marker)

    case File.read(path) do
      {:ok, value} ->
        value = String.trim(value)
        if value == "", do: file_error(:rotation_state, path, :empty), else: {:ok, value}

      {:error, reason} ->
        file_error(:rotation_state, path, reason)
    end
  end

  defp write_text(path, contents, mode) do
    AtomicFile.write(path, contents, mode)
  end

  defp file_error(step, path, reason) do
    {:error,
     %Error{
       step: step,
       message: "file operation failed",
       details: "#{path}: #{inspect(reason)}"
     }}
  end

  defp generation_dir(config, generation_id) do
    Path.join([config.state_dir, "generations", generation_id])
  end

  defp candidate_dir(config) do
    Path.join(config.state_dir, "candidate")
  end

  defp generation_id(now) do
    now
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end

  defp ensure_trailing_newline(contents) do
    if String.ends_with?(contents, "\n"), do: contents, else: contents <> "\n"
  end

  defp mode(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.mode &&& 0o777
      {:error, _reason} -> nil
    end
  end

  defp join_output(first, second) do
    [first, second]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp notify_event(config, result, opts) do
    notify_fun = Keyword.get(opts, :notify_fun, &WahaClient.send_message/3)

    if config.waha_base_url && config.waha_chat_id do
      _ = notify_fun.(config, notification_text(result), opts)
      :ok
    else
      :ok
    end
  end

  defp notification_text(result) do
    render_result(result)
  end
end
