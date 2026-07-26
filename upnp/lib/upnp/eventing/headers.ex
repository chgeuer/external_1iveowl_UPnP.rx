defmodule UPnP.Eventing.Headers do
  @moduledoc "Pure GENA header composition and parsing."

  @doc "Formats a finite GENA timeout in whole seconds."
  @spec format_timeout(pos_integer()) :: String.t()
  def format_timeout(milliseconds) when is_integer(milliseconds) and milliseconds > 0 do
    seconds = milliseconds |> Kernel./(1_000) |> Float.ceil() |> trunc()
    "Second-#{seconds}"
  end

  @doc "Parses a GENA timeout header leniently."
  @spec parse_timeout(String.t() | nil) :: {:ok, pos_integer() | :infinite} | :error
  def parse_timeout(nil), do: :error

  def parse_timeout(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized in ["infinite", "second-infinite"] ->
        {:ok, :infinite}

      true ->
        seconds = String.replace_prefix(normalized, "second-", "")

        case Integer.parse(seconds) do
          {number, ""} when number > 0 -> {:ok, number * 1_000}
          _ -> :error
        end
    end
  end

  @doc "Parses an unsigned 32-bit GENA event sequence number."
  @spec parse_seq(String.t() | nil) :: {:ok, non_neg_integer()} | :error
  def parse_seq(nil), do: :error

  def parse_seq(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number in 0..4_294_967_295 -> {:ok, number}
      _ -> :error
    end
  end
end
