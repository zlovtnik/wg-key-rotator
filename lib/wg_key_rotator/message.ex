defmodule WgKeyRotator.Message do
  @moduledoc """
  Renders a human-readable rotation notification message for WhatsApp.
  """

  def render(config, public_key, now) do
    [
      "WireGuard server key rotation complete",
      "at: #{DateTime.to_iso8601(now)}",
      "deploy: docker compose pull ssl-proxy && docker compose up -d ssl-proxy",
      "health: ok",
      public_key_line(config, public_key)
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
  end

  defp public_key_line(%{include_public_key: true}, public_key),
    do: "server public key: #{public_key}"

  defp public_key_line(_config, _public_key), do: nil
end
