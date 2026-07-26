defmodule UPnP.Eventing.Transport do
  @moduledoc "Injectable outbound GENA transport."

  @type adapter :: module() | {module(), term()}
  @type subscription :: %{sid: String.t(), timeout: pos_integer() | :infinite}
  @type error :: term()

  @callback subscribe(
              state :: term(),
              URI.t(),
              URI.t(),
              pos_integer(),
              keyword()
            ) :: {:ok, subscription()} | {:error, error()}
  @callback renew(state :: term(), URI.t(), String.t(), pos_integer(), keyword()) ::
              {:ok, pos_integer() | :infinite} | {:error, error()}
  @callback unsubscribe(state :: term(), URI.t(), String.t(), keyword()) ::
              :ok | {:error, error()}

  @doc false
  def subscribe(adapter, event_url, callback_url, timeout, options) do
    {module, state} = normalize(adapter)
    module.subscribe(state, event_url, callback_url, timeout, options)
  end

  @doc false
  def renew(adapter, event_url, sid, timeout, options) do
    {module, state} = normalize(adapter)
    module.renew(state, event_url, sid, timeout, options)
  end

  @doc false
  def unsubscribe(adapter, event_url, sid, options) do
    {module, state} = normalize(adapter)
    module.unsubscribe(state, event_url, sid, options)
  end

  defp normalize({module, state}) when is_atom(module), do: {module, state}
  defp normalize(module) when is_atom(module), do: {module, nil}
end
