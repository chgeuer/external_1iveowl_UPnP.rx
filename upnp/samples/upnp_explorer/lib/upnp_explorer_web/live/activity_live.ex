defmodule UpnpExplorerWeb.ActivityLive do
  @moduledoc "Full semantic and wire-level activity timeline."

  use UpnpExplorerWeb, :live_view

  import UpnpExplorerWeb.ExplorerComponents

  alias UpnpExplorer.{Activity, Explorer}

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Explorer.snapshot()

    if connected?(socket), do: :ok = Explorer.subscribe()

    socket =
      socket
      |> assign(
        page_title: "Activity",
        mode: :changes,
        paused?: false,
        paused_count: 0,
        status: snapshot.status
      )
      |> stream_configure(:activities, dom_id: & &1.id)
      |> stream(:activities, Enum.filter(snapshot.activities, &Activity.matches?(&1, :changes)))

    {:ok, socket}
  end

  @impl true
  def handle_event("set-mode", %{"mode" => mode}, socket) do
    mode = parse_mode(mode)
    activities = Explorer.list_activity(mode)

    {:noreply,
     socket
     |> assign(mode: mode, paused_count: 0)
     |> stream(:activities, activities, reset: true)}
  end

  def handle_event("toggle-pause", _params, %{assigns: %{paused?: true}} = socket) do
    activities = Explorer.list_activity(socket.assigns.mode)

    {:noreply,
     socket
     |> assign(paused?: false, paused_count: 0)
     |> stream(:activities, activities, reset: true)}
  end

  def handle_event("toggle-pause", _params, socket) do
    {:noreply, assign(socket, paused?: true, paused_count: 0)}
  end

  @impl true
  def handle_info({:explorer_activity_upserted, %Activity{} = activity}, socket) do
    cond do
      socket.assigns.paused? ->
        {:noreply, update(socket, :paused_count, &(&1 + 1))}

      Activity.matches?(activity, socket.assigns.mode) ->
        {:noreply, stream_insert(socket, :activities, activity, at: 0, limit: 200)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:explorer_status, status}, socket) do
    {:noreply, assign(socket, :status, status)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp parse_mode("wire"), do: :wire
  defp parse_mode("all"), do: :all
  defp parse_mode(_mode), do: :changes
end
