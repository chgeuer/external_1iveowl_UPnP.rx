defmodule UPnP.Subscription do
  @moduledoc """
  A monitored local subscription handle.

  Events arrive as `{:upnp, reference, event}` in the subscriber's mailbox.
  Roster and announcement subscriptions receive a
  `UPnP.Subscription.Closed` terminal event when their control-point generation
  restarts or the control point stops. GENA subscriptions receive the
  equivalent `UPnP.Eventing.Lifecycle` value.
  """

  @enforce_keys [:server, :ref, :kind]
  defstruct [:server, :ref, :kind]

  @type t :: %__MODULE__{server: GenServer.server(), ref: reference(), kind: atom()}

  @doc "Stops this local subscription idempotently."
  @spec close(t()) :: :ok
  def close(%__MODULE__{server: server, ref: ref}) do
    GenServer.call(server, {:unsubscribe, ref}, :infinity)
  catch
    :exit, _reason -> :ok
  end
end
