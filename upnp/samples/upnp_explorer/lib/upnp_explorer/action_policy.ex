defmodule UpnpExplorer.ActionPolicy do
  @moduledoc """
  Conservative invocation policy for actions advertised by untrusted devices.

  SCPD describes signatures but not side effects. Known standardized actions get
  curated semantics; unknown actions are treated as state changes unless they
  have no inputs and follow a conventional read-action name.
  """

  @enforce_keys [
    :kind,
    :label,
    :description,
    :warning,
    :button_label,
    :confirmation_label,
    :confirmation_required?
  ]
  defstruct [
    :kind,
    :label,
    :description,
    :warning,
    :button_label,
    :confirmation_label,
    :confirmation_required?
  ]

  @type kind :: :query | :change | :destructive | :disruptive
  @type t :: %__MODULE__{
          kind: kind(),
          label: binary(),
          description: binary(),
          warning: binary(),
          button_label: binary(),
          confirmation_label: binary(),
          confirmation_required?: boolean()
        }

  @wan_connection_services ~w(WANIPConnection WANPPPConnection)

  @wan_actions %{
    "GetExternalIPAddress" => {
      :query,
      "Reads the public address currently reported by the WAN connection."
    },
    "GetNATRSIPStatus" => {
      :query,
      "Reads whether NAT and Realm-Specific IP are enabled for this connection."
    },
    "GetStatusInfo" => {
      :query,
      "Reads connection status, the last connection error, and connection uptime."
    },
    "ForceTermination" => {
      :disruptive,
      "Terminates the current WAN session. Internet access and active sessions may be interrupted."
    },
    "RequestConnection" => {
      :change,
      "Requests that the gateway establish its configured WAN connection."
    }
  }

  @doc "Classifies one advertised action and supplies its user-facing safeguards."
  @spec classify(binary() | nil, binary() | nil, [map()]) :: t()
  def classify(service_type, action_name, inputs) when is_list(inputs) do
    service = service_token(service_type)
    input_count = length(inputs)

    case known_action(service, action_name) do
      {:query, description} when input_count == 0 ->
        query(description)

      {:query, description} ->
        change(
          description,
          "This standardized query declares input arguments. Review them before it is sent."
        )

      {:disruptive, description} ->
        disruptive(description, action_name)

      {:destructive, description} ->
        destructive(description, action_name)

      {:change, description} ->
        change(
          description,
          "Review the connection state before sending this request.",
          confirmation_label(action_name, "Confirm and invoke")
        )

      nil ->
        classify_unknown(action_name, input_count)
    end
  end

  defp known_action(service, action_name)
       when service in @wan_connection_services and is_binary(action_name) do
    Map.get(@wan_actions, action_name)
  end

  defp known_action(_service, "DeletePortMapping") do
    {:destructive, "Removes a port mapping from the gateway."}
  end

  defp known_action(_service, "DeletePortMappingRange") do
    {:destructive, "Removes a range of port mappings from the gateway."}
  end

  defp known_action(_service, action_name)
       when action_name in ["FactoryReset", "Reboot", "Restart", "Shutdown"] do
    {:disruptive, "May interrupt access to the device and the services it provides."}
  end

  defp known_action(_service, _action_name), do: nil

  defp classify_unknown(action_name, input_count) when is_binary(action_name) do
    cond do
      input_count == 0 and read_action_name?(action_name) ->
        query(
          "This zero-input action follows a conventional read-action name.",
          "Expected to be read-only, but the device's SCPD does not describe side effects.",
          true
        )

      disruptive_action_name?(action_name) ->
        disruptive(
          "This action may interrupt connectivity or device availability.",
          action_name
        )

      destructive_action_name?(action_name) ->
        destructive("This action may remove device state or configuration.", action_name)

      true ->
        change("This action may change device or network state.")
    end
  end

  defp classify_unknown(_action_name, _input_count) do
    change(
      "The device did not provide a usable action name.",
      "Malformed actions cannot be invoked."
    )
  end

  defp query(
         description,
         warning \\ "Read-only query; no device state should change.",
         confirmation_required? \\ false
       ) do
    %__MODULE__{
      kind: :query,
      label: if(confirmation_required?, do: "Unverified query", else: "Query"),
      description: description,
      warning: warning,
      button_label: if(confirmation_required?, do: "Review query", else: "Run query"),
      confirmation_label: "Confirm and run query",
      confirmation_required?: confirmation_required?
    }
  end

  defp change(
         description,
         warning \\ "Review all arguments before talking to the device.",
         confirmation_label \\ "Confirm and invoke"
       ) do
    %__MODULE__{
      kind: :change,
      label: "Changes state",
      description: description,
      warning: warning,
      button_label: "Review invocation",
      confirmation_label: confirmation_label,
      confirmation_required?: true
    }
  end

  defp destructive(description, action_name) do
    %__MODULE__{
      kind: :destructive,
      label: "Destructive",
      description: description,
      warning: "The requested change may not be reversible.",
      button_label: "Review destructive action",
      confirmation_label: confirmation_label(action_name, "Confirm destructive action"),
      confirmation_required?: true
    }
  end

  defp disruptive(description, action_name) do
    %__MODULE__{
      kind: :disruptive,
      label: "Connectivity risk",
      description: description,
      warning: "You may temporarily lose Internet or device access.",
      button_label: "Review disruptive action",
      confirmation_label: confirmation_label(action_name, "Confirm disruptive action"),
      confirmation_required?: true
    }
  end

  defp confirmation_label("ForceTermination", _fallback), do: "Disconnect WAN"
  defp confirmation_label("RequestConnection", _fallback), do: "Request connection"
  defp confirmation_label(_action_name, fallback), do: fallback

  defp read_action_name?(action_name) do
    Regex.match?(~r/(?:^|[_-])(Get|Query|Browse|Search)[A-Z0-9_]/, action_name)
  end

  defp disruptive_action_name?(action_name) do
    Regex.match?(
      ~r/(?:^|[_-])(ForceTermination|FactoryReset|Reboot|Restart|Shutdown|Disconnect)(?:$|[A-Z0-9_])/,
      action_name
    )
  end

  defp destructive_action_name?(action_name) do
    Regex.match?(~r/(?:^|[_-])(Delete|Remove|Destroy|Clear)(?:$|[A-Z0-9_])/, action_name)
  end

  defp service_token(nil), do: nil

  defp service_token(service_type) do
    service_type
    |> String.split(":")
    |> Enum.reverse()
    |> Enum.find(fn token -> token != "" and not version_token?(token) end)
  end

  defp version_token?(token), do: match?({_version, ""}, Integer.parse(token))
end
