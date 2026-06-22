defmodule WgKeyRotator.PeerConfigTest do
  use ExUnit.Case, async: true

  alias WgKeyRotator.PeerConfig

  test "appends a missing key to the final matching section without duplicating it" do
    contents = """
    [Interface]
    Address = 10.13.13.2/32

    [Peer]
    PublicKey = old
    """

    rendered = PeerConfig.replace_values(contents, [{"Peer", "PresharedKey", "new"}])

    assert rendered =~ "PresharedKey = new"
    assert rendered |> String.split("[Peer]") |> length() == 2
  end

  test "creates the section when the target section is absent" do
    contents = """
    [Interface]
    Address = 10.13.13.2/32
    """

    rendered = PeerConfig.replace_values(contents, [{"Peer", "PublicKey", "new"}])

    assert rendered =~ "[Peer]\nPublicKey = new"
  end
end
