defmodule UPnP.UserAgent do
  @moduledoc false

  @spec default() :: String.t()
  def default do
    "Elixir/#{System.version()} UPnP/2.0 upnp/#{package_version()}"
  end

  @spec from_options(keyword()) :: {:ok, String.t()} | {:error, :invalid_header_value}
  def from_options(options) do
    options
    |> Keyword.get_lazy(:user_agent, &default/0)
    |> validate()
  end

  defp validate(value) when is_binary(value) do
    if value != "" and not String.contains?(value, ["\r", "\n"]),
      do: {:ok, value},
      else: {:error, :invalid_header_value}
  end

  defp validate(_value), do: {:error, :invalid_header_value}

  defp package_version do
    case Application.spec(:upnp, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      nil -> raise "UPnP application metadata is not loaded"
    end
  end
end
