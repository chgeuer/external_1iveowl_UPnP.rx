defmodule UPnP.SSDP.Composer do
  @moduledoc false

  alias UPnP.SSDP.SearchTarget
  alias UPnP.UserAgent

  @multicast_host "239.255.255.250:1900"

  @spec m_search(SearchTarget.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def m_search(%SearchTarget{value: target}, options) do
    mx = Keyword.get(options, :mx, 3)
    friendly_name = Keyword.get(options, :friendly_name, "UPnP")

    with :ok <- validate_mx(mx),
         :ok <- validate_field(target),
         :ok <- validate_field(friendly_name),
         {:ok, user_agent} <- UserAgent.from_options(options) do
      {:ok,
       [
         "M-SEARCH * HTTP/1.1\r\n",
         "HOST: ",
         @multicast_host,
         "\r\n",
         "MAN: \"ssdp:discover\"\r\n",
         "MX: ",
         Integer.to_string(mx),
         "\r\n",
         "ST: ",
         target,
         "\r\n",
         "CPFN.UPNP.ORG: ",
         friendly_name,
         "\r\n",
         "USER-AGENT: ",
         user_agent,
         "\r\n",
         "\r\n"
       ]
       |> IO.iodata_to_binary()}
    end
  end

  defp validate_mx(mx) when is_integer(mx) and mx in 1..5, do: :ok
  defp validate_mx(_mx), do: {:error, :invalid_mx}

  defp validate_field(value) when is_binary(value) do
    if value != "" and not String.contains?(value, ["\r", "\n"]),
      do: :ok,
      else: {:error, :invalid_header_value}
  end
end
