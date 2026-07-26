defmodule UpnpExplorer.EventView do
  @moduledoc "UI projection of GENA property and lifecycle events."

  alias UPnP.EventedProperty
  alias UPnP.Eventing.{Event, Lifecycle}
  alias UPnP.Eventing.AV.LastChange

  @enforce_keys [:id, :kind, :label, :occurred_at]
  defstruct [
    :id,
    :kind,
    :label,
    :value,
    :channel,
    :sequence,
    :occurred_at,
    :detail,
    :tone,
    initial?: false,
    replay?: false
  ]

  @type t :: %__MODULE__{}

  @doc "Projects the atomic replay returned when a service watch begins."
  @spec from_snapshot([EventedProperty.t()]) :: [t()]
  def from_snapshot(properties) do
    now = DateTime.utc_now()

    Enum.flat_map(properties, fn property ->
      property_views(property, now, nil, false, true)
    end)
  end

  @doc "Projects one accepted GENA notification."
  @spec from_event(Event.t()) :: [t()]
  def from_event(%Event{} = event) do
    Enum.flat_map(event.properties, fn property ->
      property_views(
        property,
        event.received_at,
        event.sequence,
        event.initial?,
        false
      )
    end)
  end

  @doc "Projects a subscription lifecycle transition."
  @spec from_lifecycle(Lifecycle.t()) :: t()
  def from_lifecycle(%Lifecycle{} = lifecycle) do
    details =
      [
        lifecycle.sid && "SID #{lifecycle.sid}",
        lifecycle.timeout && "timeout #{inspect(lifecycle.timeout)}",
        lifecycle.expected_sequence && "expected #{lifecycle.expected_sequence}",
        lifecycle.actual_sequence && "received #{lifecycle.actual_sequence}",
        lifecycle.attempt && "attempt #{lifecycle.attempt}",
        lifecycle.reason && format_reason(lifecycle.reason)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    %__MODULE__{
      id: unique_id(),
      kind: :lifecycle,
      label:
        lifecycle.kind |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize(),
      occurred_at: lifecycle.occurred_at,
      detail: details,
      tone: lifecycle_tone(lifecycle.kind)
    }
  end

  defp property_views(
         %EventedProperty{name: name, value: value},
         occurred_at,
         sequence,
         initial?,
         replay?
       ) do
    if same_name?(name, "LastChange") && is_binary(value) do
      case LastChange.parse(value) do
        {:ok, changes} when changes != [] ->
          Enum.map(changes, fn change ->
            %__MODULE__{
              id: unique_id(),
              kind: :av_change,
              label: change.name || "AV state",
              value: change.value,
              channel: change.channel,
              sequence: sequence,
              occurred_at: occurred_at,
              tone: :accent,
              initial?: initial?,
              replay?: replay?
            }
          end)

        _result ->
          [property_view(name, value, occurred_at, sequence, initial?, replay?)]
      end
    else
      [property_view(name, value, occurred_at, sequence, initial?, replay?)]
    end
  end

  defp property_view(name, value, occurred_at, sequence, initial?, replay?) do
    %__MODULE__{
      id: unique_id(),
      kind: :property,
      label: name || "Unnamed property",
      value: value,
      sequence: sequence,
      occurred_at: occurred_at,
      tone: :neutral,
      initial?: initial?,
      replay?: replay?
    }
  end

  defp same_name?(left, right) when is_binary(left),
    do: String.downcase(String.trim(left)) == String.downcase(right)

  defp same_name?(_left, _right), do: false

  defp lifecycle_tone(kind)
       when kind in [:subscribed, :renewed, :resubscribed],
       do: :success

  defp lifecycle_tone(kind)
       when kind in [:lost, :resubscribe_failed, :retry_exhausted, :subscription_refused],
       do: :error

  defp lifecycle_tone(kind) when kind in [:sequence_gap, :stale, :duplicate], do: :warning
  defp lifecycle_tone(_kind), do: :accent

  defp unique_id do
    "service-event-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp format_reason(reason) do
    case reason do
      exception when is_exception(exception) -> Exception.message(exception)
      value -> inspect(value, pretty: true, limit: 6, printable_limit: 160)
    end
  end
end
