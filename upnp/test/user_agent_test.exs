defmodule UPnP.UserAgentTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.Eventing.Transport.HTTP, as: EventingHTTP
  alias UPnP.HTTP.{Request, Response}
  alias UPnP.SSDP
  alias UPnP.SSDP.SearchTarget

  @service_type "urn:schemas-upnp-org:service:WANIPConnection:2"
  @custom_user_agent "Example/1 UPnP/2.0 Client/3"

  defmodule CaptureHTTP do
    @behaviour UPnP.HTTP

    @impl true
    def request(request, options) do
      send(Keyword.fetch!(options, :test), {:http_request, request})
      {:ok, %Response{status: 503, body: "unavailable"}}
    end
  end

  setup do
    {:ok, clock} = start_supervised(Manual)

    {:ok, options} =
      UPnP.Options.new(
        clock: {Manual, clock},
        http_adapter: {CaptureHTTP, test: self()}
      )

    %{options: options}
  end

  test "all outbound protocols use the application-versioned default", %{options: options} do
    expected = expected_user_agent()

    assert {:ok, search} = SSDP.m_search(SearchTarget.root_device(), [])
    assert search =~ "USER-AGENT: #{expected}\r\n"

    assert {:error, _reason} =
             UPnP.Description.Client.fetch(URI.parse("http://device/description.xml"), options)

    assert_receive {:http_request, description_request}

    assert {:error, _reason} =
             UPnP.SCPD.Client.fetch(URI.parse("http://device/service.xml"), options)

    assert_receive {:http_request, scpd_request}

    service = %UPnP.ServiceDescription{
      service_type: @service_type,
      control_url: URI.parse("http://device/control")
    }

    assert {:error, _reason} =
             UPnP.Action.invoke(service, "GetStatusInfo", [], options, [])

    assert_receive {:http_request, action_request}

    assert {:error, {:http_status, 503, "unavailable"}} =
             EventingHTTP.subscribe(
               nil,
               URI.parse("http://device/events"),
               URI.parse("http://192.0.2.10/callback"),
               30_000,
               http_adapter: {CaptureHTTP, test: self()}
             )

    assert_receive {:http_request, eventing_request}

    assert Enum.map(
             [description_request, scpd_request, action_request, eventing_request],
             &header(&1, "user-agent")
           ) == List.duplicate(expected, 4)
  end

  test "supported overrides reject CR and LF before sending a request" do
    assert {:ok, search} =
             SSDP.m_search(SearchTarget.root_device(), user_agent: @custom_user_agent)

    assert search =~ "USER-AGENT: #{@custom_user_agent}\r\n"

    assert {:error, {:http_status, 503, "unavailable"}} =
             EventingHTTP.subscribe(
               nil,
               URI.parse("http://device/events"),
               URI.parse("http://192.0.2.10/callback"),
               30_000,
               http_adapter: {CaptureHTTP, test: self()},
               user_agent: @custom_user_agent
             )

    assert_receive {:http_request, request}
    assert header(request, "user-agent") == @custom_user_agent

    Enum.each(["bad\rInjected: yes", "bad\nInjected: yes"], fn invalid ->
      assert {:error, :invalid_header_value} =
               SSDP.m_search(SearchTarget.root_device(), user_agent: invalid)

      assert {:error, :invalid_header_value} =
               EventingHTTP.subscribe(
                 nil,
                 URI.parse("http://device/events"),
                 URI.parse("http://192.0.2.10/callback"),
                 30_000,
                 http_adapter: {CaptureHTTP, test: self()},
                 user_agent: invalid
               )

      refute_received {:http_request, _request}
    end)
  end

  test "non-binary overrides are rejected before composition" do
    assert UPnP.UserAgent.from_options(user_agent: 42) == {:error, :invalid_header_value}
  end

  defp expected_user_agent do
    version = Mix.Project.config() |> Keyword.fetch!(:version)
    "Elixir/#{System.version()} UPnP/2.0 upnp/#{version}"
  end

  defp header(%Request{headers: headers}, expected_name) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == expected_name, do: value
    end)
  end
end
