defmodule WgKeyRotator.MixProject do
  use Mix.Project

  def project do
    [
      app: :wg_key_rotator,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: WgKeyRotator.CLI],
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end
end
