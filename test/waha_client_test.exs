defmodule WgKeyRotator.WahaClientTest do
  use ExUnit.Case, async: true

  alias WgKeyRotator.{Config, WahaClient}

  test "posts WAHA sendText payload" do
    config = %Config{
      waha_base_url: "http://waha.local/",
      waha_session: "default",
      waha_chat_id: "12132132130@c.us",
      waha_api_key: "secret",
      health_timeout_ms: 999
    }

    request_fun = fn url, headers, body, timeout ->
      assert url == "http://waha.local/api/sendText"
      assert {"X-Api-Key", "secret"} in headers
      assert {"Accept", "application/json"} in headers
      assert timeout == 999
      assert body =~ ~s("session":"default")
      assert body =~ ~s("chatId":"12132132130@c.us")
      assert body =~ ~s("text":"rotated\\nkey")
      {:ok, %{status: 200, body: "{}"}}
    end

    assert {:ok, %{status: 200}} =
             WahaClient.send_message(config, "rotated\nkey", request_fun: request_fun)
  end
end
