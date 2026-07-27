defmodule UpnpExplorer.TestActionControlPoint do
  @moduledoc false

  use GenServer

  alias UPnP.ControlPoint.Runtime

  alias UPnP.{
    ActionDescription,
    ActionResult,
    AllowedValueRange,
    ArgumentDescription,
    SCPD,
    StateVariable
  }

  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  def reply(server, result), do: GenServer.cast(server, {:reply, result})

  @impl true
  def init(options) do
    :ok = Runtime.register(make_ref(), :coordinator)

    {:ok,
     %{
       test: Keyword.fetch!(options, :test),
       mode: Keyword.get(options, :mode, :immediate),
       pending: nil
     }}
  end

  @impl true
  def handle_call({:get_scpd, _key, _url}, _from, state) do
    {:reply, {:ok, scpd()}, state}
  end

  def handle_call(
        {:invoke_action, _service, action_name, arguments, _options},
        from,
        state
      ) do
    send(state.test, {:action_invoked, action_name, arguments})

    case state.mode do
      :controlled ->
        {:noreply, %{state | pending: from}}

      :immediate ->
        {:reply, action_result(action_name), state}
    end
  end

  @impl true
  def handle_cast({:reply, _result}, %{pending: nil} = state), do: {:noreply, state}

  def handle_cast({:reply, result}, state) do
    GenServer.reply(state.pending, result)
    {:noreply, %{state | pending: nil}}
  end

  defp action_result("GetExternalIPAddress") do
    {:ok, %ActionResult{out: %{"NewExternalIPAddress" => "203.0.113.42"}}}
  end

  defp action_result("RequestConnection") do
    {:error, {:upnp_error, 501, "Action failed"}}
  end

  defp action_result(_action_name), do: {:ok, %ActionResult{}}

  defp scpd do
    %SCPD{
      actions: [
        %ActionDescription{
          name: "GetExternalIPAddress",
          arguments: [
            %ArgumentDescription{
              name: "NewExternalIPAddress",
              direction: :out,
              is_return_value: true,
              related_state_variable: "ExternalIPAddress"
            }
          ]
        },
        %ActionDescription{
          name: "DeletePortMapping",
          arguments: [
            %ArgumentDescription{
              name: "NewExternalPort",
              direction: :in,
              related_state_variable: "ExternalPort"
            },
            %ArgumentDescription{
              name: "NewProtocol",
              direction: :in,
              related_state_variable: "PortMappingProtocol"
            }
          ]
        },
        %ActionDescription{name: "ForceTermination"},
        %ActionDescription{name: "RequestConnection"}
      ],
      state_variables: [
        %StateVariable{
          name: "ExternalIPAddress",
          data_type: "string",
          sends_events: false
        },
        %StateVariable{
          name: "ExternalPort",
          data_type: "ui2",
          allowed_range: %AllowedValueRange{
            minimum: "1",
            maximum: "65535",
            step: "1"
          },
          sends_events: false
        },
        %StateVariable{
          name: "PortMappingProtocol",
          data_type: "string",
          allowed_values: ["TCP", "UDP"],
          sends_events: false
        }
      ]
    }
  end
end
