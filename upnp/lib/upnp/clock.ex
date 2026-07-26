defmodule UPnP.Clock do
  @moduledoc """
  The single clock used by UPnP protocol state machines.

  A clock is either a module implementing this behaviour or `{module, state}`.
  Production uses `UPnP.Clock.System`; tests can use `UPnP.Clock.Manual`.
  """

  @type t :: module() | {module(), term()}
  @type timer_ref :: reference()

  @callback monotonic_time(state :: term()) :: integer()
  @callback utc_now(state :: term()) :: DateTime.t()
  @callback send_after(
              state :: term(),
              destination :: Process.dest(),
              message :: term(),
              non_neg_integer()
            ) ::
              timer_ref()
  @callback cancel_timer(state :: term(), timer_ref()) :: non_neg_integer() | false

  @doc "Returns monotonic milliseconds from the configured clock."
  @spec monotonic_time(t()) :: integer()
  def monotonic_time(clock) do
    {module, state} = normalize(clock)
    module.monotonic_time(state)
  end

  @doc "Returns UTC wall time for informational timestamps."
  @spec utc_now(t()) :: DateTime.t()
  def utc_now(clock) do
    {module, state} = normalize(clock)
    module.utc_now(state)
  end

  @doc "Schedules a protocol message on the configured clock."
  @spec send_after(t(), Process.dest(), term(), non_neg_integer()) :: timer_ref()
  def send_after(clock, destination, message, milliseconds)
      when is_integer(milliseconds) and milliseconds >= 0 do
    {module, state} = normalize(clock)
    module.send_after(state, destination, message, milliseconds)
  end

  @doc "Cancels a clock timer."
  @spec cancel_timer(t(), timer_ref()) :: non_neg_integer() | false
  def cancel_timer(clock, timer_ref) when is_reference(timer_ref) do
    {module, state} = normalize(clock)
    module.cancel_timer(state, timer_ref)
  end

  @doc false
  @spec normalize(t()) :: {module(), term()}
  def normalize({module, state}) when is_atom(module), do: {module, state}
  def normalize(module) when is_atom(module), do: {module, nil}
end
