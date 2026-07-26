defmodule UpnpExplorer.ActionPolicyTest do
  use ExUnit.Case, async: true

  alias UpnpExplorer.ActionPolicy

  @wan_ip "urn:schemas-upnp-org:service:WANIPConnection:2"

  test "known zero-input WAN reads run as queries" do
    policy = ActionPolicy.classify(@wan_ip, "GetStatusInfo", [])

    assert policy.kind == :query
    refute policy.confirmation_required?
    assert policy.description =~ "connection status"
  end

  test "a read-style action with inputs still requires review" do
    policy =
      ActionPolicy.classify(@wan_ip, "GetStatusInfo", [
        %{name: "UnexpectedInput"}
      ])

    assert policy.kind == :change
    assert policy.confirmation_required?
  end

  test "zero-input mutations do not masquerade as queries" do
    policy = ActionPolicy.classify(@wan_ip, "ForceTermination", [])

    assert policy.kind == :disruptive
    assert policy.confirmation_required?
    assert policy.confirmation_label == "Disconnect WAN"

    reconnect = ActionPolicy.classify(@wan_ip, "RequestConnection", [])
    assert reconnect.confirmation_label == "Request connection"
  end

  test "unknown mutations and destructive verbs fail closed" do
    assert ActionPolicy.classify("urn:vendor:service:Thing:1", "SetMode", []).kind == :change

    destructive =
      ActionPolicy.classify("urn:vendor:service:Thing:1", "DeleteEverything", [])

    assert destructive.kind == :destructive
    assert destructive.confirmation_required?
  end

  test "uncurated read-like actions still require confirmation" do
    policy =
      ActionPolicy.classify(
        "urn:vendor:service:Diagnostics:1",
        "GetAndClearCounters",
        []
      )

    assert policy.kind == :query
    assert policy.confirmation_required?
    assert policy.label == "Unverified query"
  end
end
