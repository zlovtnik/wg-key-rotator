defmodule WgKeyRotator.WahaClient do
  alias WgKeyRotator.{Error, Json}

  def send_message(config, text, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &post/4)
    url = config.waha_base_url |> String.trim_trailing("/") |> Kernel.<>("/api/sendText")

    headers =
      [{"Accept", "application/json"}]
      |> maybe_api_key(config.waha_api_key)

    body =
      Json.encode(%{
        "session" => config.waha_session,
        "chatId" => config.waha_chat_id,
        "text" => text
      })

    request_fun.(url, headers, body, config.health_timeout_ms)
  end

  defp maybe_api_key(headers, nil), do: headers
  defp maybe_api_key(headers, ""), do: headers
  defp maybe_api_key(headers, api_key), do: [{"X-Api-Key", api_key} | headers]

  defp post(url, headers, body, timeout_ms) do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      request = {
        String.to_charlist(url),
        Enum.map(headers, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end),
        ~c"application/json",
        body
      }

      case :httpc.request(:post, request, [{:timeout, timeout_ms}], body_format: :binary) do
        {:ok, {{_, status, _}, _headers, response_body}} when status in 200..299 ->
          {:ok, %{status: status, body: response_body}}

        {:ok, {{_, status, reason}, _headers, response_body}} ->
          {:error,
           %Error{
             step: :whatsapp_notification,
             message: "WAHA returned #{status} #{to_string(reason)}",
             details: response_body
           }}

        {:error, reason} ->
          {:error,
           %Error{
             step: :whatsapp_notification,
             message: "WAHA request failed",
             details: inspect(reason)
           }}
      end
    else
      {:error, reason} ->
        {:error,
         %Error{
           step: :whatsapp_notification,
           message: "failed to start HTTP client",
           details: inspect(reason)
         }}
    end
  end
end
