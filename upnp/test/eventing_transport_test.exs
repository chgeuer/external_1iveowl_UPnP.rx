defmodule UPnP.EventingTransportTest do
  use ExUnit.Case, async: true

  alias UPnP.Eventing.{Headers, Transport}
  alias UPnP.HTTP.Response

  @async_timeout 1_000

  defmodule FakeHTTP do
    @behaviour UPnP.HTTP

    @impl true
    def request(request, test_pid: test_pid) do
      send(test_pid, {:request, request})

      receive do
        {:respond, response} -> response
      end
    end
  end

  setup do
    %{task_supervisor: start_supervised!(Task.Supervisor)}
  end

  test "timeout and SEQ headers are parsed without atoms" do
    assert Headers.format_timeout(1_001) == "Second-2"
    assert Headers.parse_timeout("second-30") == {:ok, 30_000}
    assert Headers.parse_timeout("INFINITE") == {:ok, :infinite}
    assert Headers.parse_timeout("garbage") == :error
    assert Headers.parse_seq("4294967295") == {:ok, 4_294_967_295}
    assert Headers.parse_seq("4294967296") == :error
  end

  test "GENA HTTP transport composes each method exactly", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    adapter = {FakeHTTP, test_pid: parent}
    event_url = URI.parse("http://device/events")
    callback = URI.parse("http://192.0.2.10:4000/upnp/events/token")

    subscribe =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Transport.subscribe(UPnP.Eventing.Transport.HTTP, event_url, callback, 30_000,
          http_adapter: adapter
        )
      end)

    assert_receive {:request, request}, @async_timeout
    assert request.method == "SUBSCRIBE"
    assert {"CALLBACK", "<http://192.0.2.10:4000/upnp/events/token>"} in request.headers
    assert {"NT", "upnp:event"} in request.headers

    send(
      subscribe.pid,
      {:respond,
       {:ok, %Response{status: 200, headers: [{"SID", "uuid:sid"}, {"TIMEOUT", "Second-60"}]}}}
    )

    assert Task.await(subscribe, @async_timeout) ==
             {:ok, %{sid: "uuid:sid", timeout: 60_000}}

    renew =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Transport.renew(UPnP.Eventing.Transport.HTTP, event_url, "uuid:sid", 30_000,
          http_adapter: adapter
        )
      end)

    assert_receive {:request, request}, @async_timeout
    assert request.method == "SUBSCRIBE"
    assert request.headers == [{"SID", "uuid:sid"}, {"TIMEOUT", "Second-30"}]
    send(renew.pid, {:respond, {:ok, %Response{status: 200}}})
    assert Task.await(renew, @async_timeout) == {:ok, 30_000}

    unsubscribe =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Transport.unsubscribe(UPnP.Eventing.Transport.HTTP, event_url, "uuid:sid",
          http_adapter: adapter
        )
      end)

    assert_receive {:request, request}, @async_timeout
    assert request.method == "UNSUBSCRIBE"
    assert request.headers == [{"SID", "uuid:sid"}]
    send(unsubscribe.pid, {:respond, {:ok, %Response{status: 200}}})
    assert Task.await(unsubscribe, @async_timeout) == :ok
  end

  test "GENA response parsing preserves missing and granted header semantics", %{
    task_supervisor: task_supervisor
  } do
    adapter = {FakeHTTP, test_pid: self()}
    event_url = URI.parse("http://device/events")
    callback = URI.parse("http://192.0.2.10:4000/upnp/events/token")

    missing_sid =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Transport.subscribe(UPnP.Eventing.Transport.HTTP, event_url, callback, 30_000,
          http_adapter: adapter
        )
      end)

    assert_receive {:request, _request}
    send(missing_sid.pid, {:respond, {:ok, %Response{status: 200}}})
    assert Task.await(missing_sid, @async_timeout) == {:error, :missing_sid}

    fallback_timeout =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Transport.subscribe(UPnP.Eventing.Transport.HTTP, event_url, callback, 30_000,
          http_adapter: adapter
        )
      end)

    assert_receive {:request, _request}

    send(
      fallback_timeout.pid,
      {:respond,
       {:ok, %Response{status: 200, headers: [{"SID", " uuid:fallback "}, {"TIMEOUT", "bad"}]}}}
    )

    assert Task.await(fallback_timeout, @async_timeout) ==
             {:ok, %{sid: "uuid:fallback", timeout: 30_000}}

    renewed =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Transport.renew(UPnP.Eventing.Transport.HTTP, event_url, "uuid:sid", 30_000,
          http_adapter: adapter
        )
      end)

    assert_receive {:request, _request}

    send(
      renewed.pid,
      {:respond, {:ok, %Response{status: 200, headers: [{"TIMEOUT", "Second-5"}]}}}
    )

    assert Task.await(renewed, @async_timeout) == {:ok, 5_000}
  end
end
