defmodule WgKeyRotator.PeerConfig do
  def replace_values(contents, replacements) when is_binary(contents) and is_list(replacements) do
    Enum.reduce(replacements, contents, fn {section, key, value}, acc ->
      replace_value(acc, section, key, value)
    end)
  end

  def value(contents, section, key) do
    contents
    |> String.split("\n")
    |> Enum.reduce_while({nil, nil}, fn line, {current, found} ->
      cond do
        section_header?(line) ->
          {:cont, {header_name(line), found}}

        current == section ->
          case key_value(line) do
            {^key, value} -> {:halt, {current, value}}
            _ -> {:cont, {current, found}}
          end

        true ->
          {:cont, {current, found}}
      end
    end)
    |> elem(1)
  end

  defp replace_value(contents, section, key, value) do
    {lines, _current, replaced} =
      contents
      |> String.split("\n")
      |> Enum.reduce({[], nil, false}, fn line, {acc, current, replaced} ->
        cond do
          section_header?(line) ->
            {[line | acc], header_name(line), replaced}

          current == section and not replaced and match_key?(line, key) ->
            {["#{key} = #{value}" | acc], current, true}

          true ->
            {[line | acc], current, replaced}
        end
      end)

    rendered =
      lines
      |> Enum.reverse()
      |> Enum.join("\n")

    if replaced do
      rendered
    else
      append_value(rendered, section, key, value)
    end
  end

  defp append_value(contents, section, key, value) do
    lines = String.split(contents, "\n")

    {updated, current, inserted} =
      Enum.reduce(lines, {[], nil, false}, fn line, {acc, current, inserted} ->
        cond do
          inserted ->
            {[line | acc], current, inserted}

          section_header?(line) and current == section ->
            {["#{key} = #{value}", line | acc], header_name(line), true}

          section_header?(line) ->
            {[line | acc], header_name(line), inserted}

          true ->
            {[line | acc], current, inserted}
        end
      end)

    updated =
      cond do
        inserted ->
          updated

        current == section ->
          ["#{key} = #{value}" | updated]

        true ->
          ["#{key} = #{value}", "[#{section}]" | updated]
      end

    updated
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp section_header?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]")
  end

  defp header_name(line) do
    line
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end

  defp match_key?(line, key) do
    case key_value(line) do
      {^key, _value} -> true
      _ -> false
    end
  end

  defp key_value(line) do
    case String.split(line, "=", parts: 2) do
      [lhs, rhs] -> {String.trim(lhs), String.trim(rhs)}
      _ -> nil
    end
  end
end
