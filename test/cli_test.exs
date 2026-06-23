defmodule WgKeyRotator.CLITest do
  use ExUnit.Case, async: false

  alias WgKeyRotator.CLI

  setup do
    previous = System.get_env("ROTATOR_REPO_ROOT")
    root = tmp_repo()
    System.put_env("ROTATOR_REPO_ROOT", root)

    on_exit(fn ->
      restore_env("ROTATOR_REPO_ROOT", previous)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "routes secrets generate dry-run" do
    assert {:ok, output} = CLI.run(["secrets", "generate", "--dry-run"])
    assert output =~ "Dry-run mode"
  end

  test "routes secrets check", %{root: root} do
    assert {:ok, _output} = CLI.run(["secrets", "generate"])
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))

    assert {:ok, "OK: secret tree is complete"} = CLI.run(["secrets", "check"])
  end

  test "routes secrets repair", %{root: root} do
    assert {:ok, _output} = CLI.run(["secrets", "generate"])
    File.rm!(Path.join(root, "secrets/ONE_TIME_TOKENS"))

    assert {:ok, "OK: repaired secret tree"} = CLI.run(["secrets", "repair"])
  end

  test "rejects invalid secrets subcommands" do
    assert {:halt, 64, usage} = CLI.run(["secrets", "bogus"])
    assert usage =~ "wg_key_rotator secrets generate"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp tmp_repo do
    root =
      Path.join(System.tmp_dir!(), "wg-key-rotator-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.touch!(Path.join(root, "docker-compose.yaml"))
    root
  end
end
