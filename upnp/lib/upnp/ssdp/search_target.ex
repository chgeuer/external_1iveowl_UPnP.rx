defmodule UPnP.SSDP.SearchTarget do
  @moduledoc "Constructors for standard SSDP search targets."

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @doc "Searches once per root device."
  @spec root_device() :: t()
  def root_device, do: %__MODULE__{value: "upnp:rootdevice"}

  @doc "Searches every advertised target."
  @spec all() :: t()
  def all, do: %__MODULE__{value: "ssdp:all"}

  @doc "Searches a UPnP device type and version."
  @spec device_type(String.t(), pos_integer()) :: t()
  def device_type(type, version \\ 1)
      when is_binary(type) and is_integer(version) and version > 0 do
    %__MODULE__{value: "urn:schemas-upnp-org:device:#{type}:#{version}"}
  end

  @doc "Searches a UPnP service type and version."
  @spec service_type(String.t(), pos_integer()) :: t()
  def service_type(type, version \\ 1)
      when is_binary(type) and is_integer(version) and version > 0 do
    %__MODULE__{value: "urn:schemas-upnp-org:service:#{type}:#{version}"}
  end

  @doc "Searches a particular device UUID."
  @spec uuid(String.t()) :: t()
  def uuid("uuid:" <> _ = uuid), do: %__MODULE__{value: uuid}
  def uuid(uuid) when is_binary(uuid), do: %__MODULE__{value: "uuid:" <> uuid}

  @doc "Creates a target from a validated wire value."
  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_search_target}
  def new(value) when is_binary(value) do
    if value != "" and not String.contains?(value, ["\r", "\n"]) do
      {:ok, %__MODULE__{value: value}}
    else
      {:error, :invalid_search_target}
    end
  end
end
