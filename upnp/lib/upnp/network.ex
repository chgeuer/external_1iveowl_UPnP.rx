defmodule UPnP.Network do
  @moduledoc """
  Injectable network route selection.

  Adapters resolve the local IPv4 address used to reach a remote URI. Configure
  either an Adapter module or `{module, state}`; module-only Adapters receive
  `nil` as their state.
  """

  @type adapter :: module() | {module(), term()}
  @type result :: {:ok, :inet.ip4_address()} | {:error, term()}

  @doc """
  Resolves the local IPv4 address used to reach `uri`.
  """
  @callback local_address_for(URI.t(), state :: term()) :: result()

  @doc "Runs route selection through an Adapter."
  @spec local_address_for(adapter(), URI.t()) :: result()
  def local_address_for(adapter, %URI{} = uri) do
    {module, state} = normalize(adapter)
    module.local_address_for(uri, state)
  end

  defp normalize({module, state}) when is_atom(module), do: {module, state}
  defp normalize(module) when is_atom(module), do: {module, nil}
end
