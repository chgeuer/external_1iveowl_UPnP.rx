defmodule UPnP.Samples.Interfaces do
  @moduledoc false

  @spec ipv4_addresses() :: {:ok, [:inet.ip4_address()]} | {:error, term()}
  def ipv4_addresses do
    with {:ok, interfaces} <- :inet.getifaddrs() do
      addresses =
        interfaces
        |> Enum.flat_map(fn {name, properties} ->
          flags = Keyword.get(properties, :flags, [])

          if :up in flags and :multicast in flags and :loopback not in flags and
               operational?(name, flags) do
            properties
            |> Keyword.get_values(:addr)
            |> Enum.filter(&ipv4?/1)
          else
            []
          end
        end)
        |> Enum.uniq()

      {:ok, addresses}
    end
  end

  @spec format(:inet.ip_address()) :: String.t()
  def format(address), do: address |> :inet.ntoa() |> List.to_string()

  defp operational?(name, flags) do
    case :os.type() do
      {:unix, :linux} ->
        name = List.to_string(name)

        case File.read("/sys/class/net/#{name}/operstate") do
          {:ok, state} -> String.trim(state) in ["up", "unknown"]
          {:error, _reason} -> :running in flags
        end

      _other ->
        :running in flags
    end
  end

  defp ipv4?({_, _, _, _}), do: true
  defp ipv4?(_address), do: false
end
