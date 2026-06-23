defmodule WgKeyRotator.MixProject do
  use Mix.Project

  def project do
    [
      app: :wg_key_rotator,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: WgKeyRotator.CLI],
      deps: deps()
    ]
  end

  defp deps do
    case Mix.env() do
      env when env in [:dev, :test] ->
        [{:credo, "~> 1.7", runtime: false}]

      _ ->
        []
    end
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl]
    ]
  end
end
