defmodule WgKeyRotator.Json do
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

  defp escape(value) do
    for <<codepoint::utf8 <- value>>, into: "" do
      case codepoint do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        ?\b -> "\\b"
        ?\f -> "\\f"
        cp when cp < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(cp, 16), 4, "0")
        cp -> <<cp::utf8>>
      end
    end
  end
end
