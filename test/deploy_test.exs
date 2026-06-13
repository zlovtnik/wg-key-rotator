defmodule WgKeyRotator.DeployTest do
  use ExUnit.Case, async: true

  alias WgKeyRotator.{Config, Deploy}

  test "runs compose deployment, checks ps, and probes health" do
    root = "/tmp/wg-key-rotator-repo"

    config = %Config{
      repo_root: root,
      health_url: "http://127.0.0.1:3002/health",
      health_timeout_ms: 123
    }

    runner = fn
      "docker", ["compose", "up", "-d", "--build", "ssl-proxy"], opts ->
        assert opts[:cd] == root
        {"deploy ok", 0}

      "docker", ["compose", "ps", "ssl-proxy"], opts ->
        assert opts[:cd] == root
        {"ssl-proxy running", 0}
    end

    health_get = fn url, timeout ->
      assert url == "http://127.0.0.1:3002/health"
      assert timeout == 123
      {:ok, %{status: 200, body: "ok"}}
    end

    assert {:ok, result} = Deploy.run(config, runner: runner, health_get: health_get)
    assert result.deploy_output == "deploy ok"
    assert result.health.status == 200
  end
end
