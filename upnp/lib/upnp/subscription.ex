defmodule UPnP.Subscription do
  @moduledoc """
  A monitored local subscription handle.

  Events arrive as `{:upnp, reference, event}` in the subscriber's mailbox.
  """

  @enforce_keys [:server, :ref, :kind]
  defstruct [:server, :ref, :kind]

  @type t :: %__MODULE__{server: GenServer.server(), ref: reference(), kind: atom()}

  @doc "Stops this local subscription."
  @spec close(t()) :: :ok
  def close(%__MODULE__{server: server, ref: ref}) do
    GenServer.call(server, {:unsubscribe, ref}, :infinity)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end
end
