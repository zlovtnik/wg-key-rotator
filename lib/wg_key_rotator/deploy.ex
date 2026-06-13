defmodule WgKeyRotator.Deploy do
  alias WgKeyRotator.{Command, Error, Health}

  def run(config, opts \\ []) do
    runner = Keyword.get(opts, :runner, &Command.system_runner/3)
    health_get = Keyword.get(opts, :health_get, &Health.get/2)

    with {:ok, deploy_output} <- compose_up(config, runner),
         {:ok, ps_output} <- compose_ps(config, runner),
         :ok <- verify_ps(ps_output),
         {:ok, health} <- health_get.(config.health_url, config.health_timeout_ms) do
      {:ok, %{deploy_output: deploy_output, ps_output: ps_output, health: health}}
    end
  end

  defp compose_up(config, runner) do
    Command.run(
      runner,
      "docker",
      ["compose", "up", "-d", "--build", "ssl-proxy"],
      [cd: config.repo_root, stderr_to_stdout: true],
      :deploy
    )
  end

  defp compose_ps(config, runner) do
    Command.run(
      runner,
      "docker",
      ["compose", "ps", "ssl-proxy"],
      [cd: config.repo_root, stderr_to_stdout: true],
      :compose_ps
    )
  end

  defp verify_ps(output) do
    if String.contains?(output, "ssl-proxy") do
      :ok
    else
      {:error,
       %Error{
         step: :compose_ps,
         message: "docker compose ps did not include ssl-proxy",
         details: output
       }}
    end
  end
end
