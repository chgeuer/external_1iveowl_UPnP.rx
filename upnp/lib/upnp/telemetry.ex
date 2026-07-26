defmodule UPnP.Telemetry do
  @moduledoc """
  Telemetry events emitted by the control point.

  Every event has a `:count` measurement equal to `1`. Event-specific
  measurements and metadata are:

  | Event | Measurements | Metadata |
  | --- | --- | --- |
  | `[:upnp, :ssdp, :interface_error]` | `:count` | `:interface`, `:reason` |
  | `[:upnp, :ssdp, :parse_error]` | `:count` | `:interface`, `:reason` |
  | `[:upnp, :ssdp, :datagram_dropped]` | `:count`, `:bytes` | `:interface`, `:reason` |
  | `[:upnp, :ssdp, :send_error]` | `:count` | `:interface`, `:reason` |
  | `[:upnp, :roster, :change]` | `:count` | `:kind`, `:identity` |
  | `[:upnp, :description, :fetch]` | `:count` | `:location`, `:outcome` |
  | `[:upnp, :action, :invoke]` | `:count` | `:service_type`, `:action`, `:outcome` |
  | `[:upnp, :eventing, :notification]` | `:count`, `:property_count` | `:subscription`, `:sid`, `:sequence` |
  | `[:upnp, :eventing, :lifecycle]` | `:count` | `:subscription`, `:kind`, `:sid`, `:reason` |
  | `[:upnp, :igd, :lease]` | `:count` | `:kind`, `:reason`, `:external_port`, `:protocol` |

  `:reason` and error `:outcome` values are bounded classifications. Raw
  exception terms, parser details, transport payloads, and HTTP response bodies
  are never included in metadata.
  """

  @events [
    [:upnp, :ssdp, :interface_error],
    [:upnp, :ssdp, :parse_error],
    [:upnp, :ssdp, :datagram_dropped],
    [:upnp, :ssdp, :send_error],
    [:upnp, :roster, :change],
    [:upnp, :description, :fetch],
    [:upnp, :action, :invoke],
    [:upnp, :eventing, :notification],
    [:upnp, :eventing, :lifecycle],
    [:upnp, :igd, :lease]
  ]

  @contracts %{
    [:upnp, :ssdp, :interface_error] => {[:count], [:interface, :reason]},
    [:upnp, :ssdp, :parse_error] => {[:count], [:interface, :reason]},
    [:upnp, :ssdp, :datagram_dropped] => {[:bytes, :count], [:interface, :reason]},
    [:upnp, :ssdp, :send_error] => {[:count], [:interface, :reason]},
    [:upnp, :roster, :change] => {[:count], [:identity, :kind]},
    [:upnp, :description, :fetch] => {[:count], [:location, :outcome]},
    [:upnp, :action, :invoke] => {[:count], [:action, :outcome, :service_type]},
    [:upnp, :eventing, :notification] =>
      {[:count, :property_count], [:sequence, :sid, :subscription]},
    [:upnp, :eventing, :lifecycle] => {[:count], [:kind, :reason, :sid, :subscription]},
    [:upnp, :igd, :lease] => {[:count], [:external_port, :kind, :protocol, :reason]}
  }

  @doc "Returns every emitted event name."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc false
  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements, metadata) when is_map(measurements) and is_map(metadata) do
    {measurement_keys, metadata_keys} =
      case Map.fetch(@contracts, event) do
        {:ok, contract} -> contract
        :error -> raise ArgumentError, "unknown UPnP telemetry event: #{inspect(event)}"
      end

    measurements = Map.put(measurements, :count, 1)
    metadata = sanitize_metadata(metadata)

    validate_keys!(event, :measurement, measurements, measurement_keys)
    validate_keys!(event, :metadata, metadata, metadata_keys)

    :telemetry.execute(event, measurements, metadata)
  end

  @doc false
  @spec classify_error(term()) :: term()
  def classify_error(nil), do: nil
  def classify_error(reason) when is_atom(reason), do: reason
  def classify_error({:http_status, status, _body}), do: {:http_status, status}
  def classify_error({:http_status, status}), do: {:http_status, status}
  def classify_error({:upnp_error, %{code: code}}), do: {:upnp_error, code}
  def classify_error({:parse, _error}), do: :parse_error
  def classify_error({:transport, _reason}), do: :transport_error

  def classify_error({kind, reason})
      when kind in [:renewal_failed, :callback_server_down, :worker_exit],
      do: {kind, classify_error(reason)}

  def classify_error(_reason), do: :error

  defp sanitize_metadata(metadata) do
    metadata
    |> update_if_present(:reason, &classify_error/1)
    |> update_if_present(:outcome, &classify_outcome/1)
  end

  defp classify_outcome({:error, reason}), do: {:error, classify_error(reason)}
  defp classify_outcome(outcome), do: outcome

  defp update_if_present(metadata, key, function) do
    if Map.has_key?(metadata, key) do
      Map.update!(metadata, key, function)
    else
      metadata
    end
  end

  defp validate_keys!(event, kind, values, expected_keys) do
    actual_keys = values |> Map.keys() |> Enum.sort()

    if actual_keys != expected_keys do
      raise ArgumentError,
            "#{inspect(event)} #{kind} keys must be #{inspect(expected_keys)}, " <>
              "got: #{inspect(actual_keys)}"
    end
  end
end
