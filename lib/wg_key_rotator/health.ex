defmodule WgKeyRotator.Health do
  @moduledoc """
  Performs HTTP health checks against a given URL using Erlang's
  `:httpc` client.
  """

  alias WgKeyRotator.Error

  def get(url, timeout_ms) do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      request = {String.to_charlist(url), [{~c"Accept", ~c"application/json"}]}

      case :httpc.request(:get, request, [{:timeout, timeout_ms}], body_format: :binary) do
        {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
          {:ok, %{status: status, body: body}}

        {:ok, {{_, status, reason}, _headers, body}} ->
          {:error,
           %Error{
             step: :health_check,
             message: "health endpoint returned #{status} #{to_string(reason)}",
             details: body
           }}

        {:error, reason} ->
          {:error,
           %Error{
             step: :health_check,
             message: "health request failed",
             details: inspect(reason)
           }}
      end
    else
      {:error, reason} ->
        {:error,
         %Error{
           step: :health_check,
           message: "failed to start HTTP client",
           details: inspect(reason)
         }}
    end
  end
end
