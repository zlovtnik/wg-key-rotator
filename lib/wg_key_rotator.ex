defmodule WgKeyRotator do
  @moduledoc """
  Top-level module for WireGuard key rotation.

  Provides the main `rotate/1` and `rotate/2` entry points that
  orchestrate key generation, atomic file writes, deployment, and
  WhatsApp notification.
  """

  alias WgKeyRotator.{AtomicFile, Config, Deploy, Error, Keygen, Message, WahaClient}

  def rotate(opts \\ []) when is_list(opts) do
    with {:ok, config} <- Config.load(:system, require_waha: true) do
      rotate(config, opts)
    end
  end

  def rotate(%Config{} = config, opts) do
    runner = Keyword.get(opts, :runner, &WgKeyRotator.Command.system_runner/3)
    deploy_fun = Keyword.get(opts, :deploy_fun, fn cfg -> Deploy.run(cfg, opts) end)

    notify_fun =
      Keyword.get(opts, :notify_fun, fn cfg, text -> WahaClient.send_message(cfg, text, opts) end)

    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, keys} <- Keygen.generate(runner),
         :ok <- AtomicFile.write(config.private_key_path, keys.private_key <> "\n", 0o600),
         :ok <- AtomicFile.write(config.public_key_path, keys.public_key <> "\n", 0o644),
         {:ok, deploy_result} <- deploy_fun.(config),
         message = Message.render(config, keys.public_key, now),
         {:ok, notification} <- notify_fun.(config, message) do
      {:ok,
       %{
         public_key: keys.public_key,
         deploy: deploy_result,
         notification: notification,
         message: message
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      %Error{} = error ->
        {:error, error}

      {:error, reason} ->
        {:error, %Error{step: :rotation, message: "rotation failed", details: inspect(reason)}}
    end
  end
end
