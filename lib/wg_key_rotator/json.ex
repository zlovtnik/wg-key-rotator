defmodule WgKeyRotator.Json do
  @moduledoc """
  Minimal JSON encoder for small objects (maps with string keys/values).
  """

  def encode(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> [string(to_string(key)), ?:, string(to_string(value))] end)
    |> Enum.intersperse(?,)
    |> then(&[?{, &1, ?}])
    |> IO.iodata_to_binary()
  end

  defp string(value) do
    [?\", escape(value), ?\"]
  end

  @escape_chars %{
    ?" => "\\\"",
    ?\\ => "\\\\",
    ?\n => "\\n",
    ?\r => "\\r",
    ?\t => "\\t",
    ?\b => "\\b",
    ?\f => "\\f"
  }

  defp escape(value) do
    for <<codepoint::utf8 <- value>>, into: "" do
      escape_codepoint(codepoint)
    end
  end

  defp escape_codepoint(codepoint) do
    case @escape_chars[codepoint] do
      nil when codepoint < 0x20 ->
        "\\u" <> String.pad_leading(Integer.to_string(codepoint, 16), 4, "0")

      nil ->
        <<codepoint::utf8>>

      escaped ->
        escaped
    end
  end
end
