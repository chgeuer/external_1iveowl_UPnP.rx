defmodule UPnP.SSDP.Transport do
  @moduledoc "Injectable UDP transport for SSDP interface workers."

  @type adapter :: module() | {module(), term()}
  @type socket :: term()

  @callback open(state :: term(), :inet.ip4_address(), keyword()) ::
              {:ok, socket()} | {:error, term()}
  @callback activate(state :: term(), socket()) :: :ok | {:error, term()}
  @callback send(state :: term(), socket(), :inet.ip_address(), :inet.port_number(), iodata()) ::
              :ok | {:error, term()}
  @callback close(state :: term(), socket()) :: :ok

  @doc false
  def open(adapter, address, options) do
    {module, state} = normalize(adapter)
    module.open(state, address, options)
  end

  @doc false
  def activate(adapter, socket) do
    {module, state} = normalize(adapter)
    module.activate(state, socket)
  end

  @doc false
  def send(adapter, socket, address, port, payload) do
    {module, state} = normalize(adapter)
    module.send(state, socket, address, port, payload)
  end

  @doc false
  def close(adapter, socket) do
    {module, state} = normalize(adapter)
    module.close(state, socket)
  end

  defp normalize({module, state}) when is_atom(module), do: {module, state}
  defp normalize(module) when is_atom(module), do: {module, nil}
end
