defmodule UPnP.Telemetry do
  @moduledoc """
  Telemetry events emitted by the control point.

  Every event has a `:count` measurement. Notification events also include
  `:property_count`, and oversized SSDP datagrams include `:bytes`.
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

  @doc "Returns every emitted event name."
  @spec events() :: [[atom()]]
  def events, do: @events

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
end
