defmodule UpnpExplorer.EventViewTest do
  use ExUnit.Case, async: true

  alias UPnP.EventedProperty
  alias UPnP.Eventing.{Event, Lifecycle}
  alias UpnpExplorer.EventView

  test "expands AV LastChange properties into readable state changes" do
    occurred_at = ~U[2026-01-02 03:04:05Z]

    event = %Event{
      sid: "uuid:subscription",
      sequence: 7,
      properties: [
        %EventedProperty{
          name: "LastChange",
          value:
            ~s(<Event><InstanceID val="0"><Volume channel="Master" val="25"/></InstanceID></Event>)
        }
      ],
      snapshot: [],
      initial?: false,
      received_at: occurred_at
    }

    assert [%EventView{} = projected] = EventView.from_event(event)
    assert projected.kind == :av_change
    assert projected.label == "Volume"
    assert projected.value == "25"
    assert projected.channel == "Master"
    assert projected.sequence == 7
    assert projected.occurred_at == occurred_at
  end

  test "projects lifecycle failures as data" do
    lifecycle = %Lifecycle{
      kind: :sequence_gap,
      sid: "uuid:subscription",
      expected_sequence: 4,
      actual_sequence: 8,
      occurred_at: ~U[2026-01-02 03:04:05Z]
    }

    projected = EventView.from_lifecycle(lifecycle)

    assert projected.kind == :lifecycle
    assert projected.label == "Sequence gap"
    assert projected.tone == :warning
    assert projected.detail =~ "expected 4"
    assert projected.detail =~ "received 8"
  end
end
