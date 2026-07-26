defmodule UpnpExplorerWeb.ExplorerComponents do
  @moduledoc "Shared presentation components for the UPnP explorer."

  use UpnpExplorerWeb, :html

  attr :activity, UpnpExplorer.Activity, required: true
  attr :compact, :boolean, default: false
  attr :id, :string, required: true

  def activity_item(assigns) do
    ~H"""
    <article
      id={@id}
      class={[
        "group relative grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 border-b border-[var(--line)] py-3 last:border-b-0",
        @compact && "py-2.5"
      ]}
    >
      <div class={[
        "mt-1.5 size-2 rounded-full",
        activity_marker_class(@activity.tone)
      ]}>
      </div>
      <div class="min-w-0">
        <div class="flex items-baseline justify-between gap-3">
          <p class={[
            "truncate font-medium text-[var(--text)]",
            @compact && "text-[0.78rem]",
            !@compact && "text-sm"
          ]}>
            {@activity.title}
          </p>
          <time
            datetime={DateTime.to_iso8601(@activity.occurred_at)}
            class="shrink-0 font-mono text-[0.68rem] text-[var(--text-faint)]"
          >
            {Calendar.strftime(@activity.occurred_at, "%H:%M:%S")}
          </time>
        </div>
        <p
          :if={@activity.detail}
          class="mt-0.5 truncate font-mono text-[0.68rem] text-[var(--text-muted)]"
        >
          {@activity.detail}
        </p>
        <span
          :if={@activity.count > 1}
          class="mt-1 inline-flex rounded-full border border-[var(--line-strong)] px-1.5 py-0.5 font-mono text-[0.62rem] text-[var(--text-muted)]"
        >
          repeated {@activity.count} times
        </span>
      </div>
    </article>
    """
  end

  attr :status, :atom, required: true

  def presence(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full border px-2 py-1 text-[0.68rem] font-semibold",
      presence_class(@status)
    ]}>
      <span class="size-1.5 rounded-full bg-current" aria-hidden="true"></span>
      {presence_label(@status)}
    </span>
    """
  end

  attr :title, :string, required: true
  attr :detail, :string, default: nil
  attr :icon, :string, default: "hero-signal"
  slot :action

  def empty_state(assigns) do
    ~H"""
    <section class="flex min-h-56 flex-col items-center justify-center px-6 py-12 text-center">
      <div class="grid size-11 place-items-center rounded-lg border border-[var(--line-strong)] bg-[var(--surface-raised)] text-[var(--accent)]">
        <.icon name={@icon} class="size-5" />
      </div>
      <h2 class="mt-4 text-base font-semibold tracking-[-0.015em] text-[var(--text)]">{@title}</h2>
      <p :if={@detail} class="mt-2 max-w-md text-sm leading-6 text-[var(--text-muted)]">
        {@detail}
      </p>
      <div :if={@action != []} class="mt-5">
        {render_slot(@action)}
      </div>
    </section>
    """
  end

  defp presence_label(:discovered), do: "Discovered"
  defp presence_label(:describing), do: "Describing"
  defp presence_label(:online), do: "Online"
  defp presence_label(:degraded), do: "Degraded"

  defp presence_class(:online),
    do: "border-[var(--success-border)] bg-[var(--success-soft)] text-[var(--success)]"

  defp presence_class(:degraded),
    do: "border-[var(--warning-border)] bg-[var(--warning-soft)] text-[var(--warning)]"

  defp presence_class(_status),
    do: "border-[var(--accent-border)] bg-[var(--accent-soft)] text-[var(--accent)]"

  defp activity_marker_class(:accent), do: "bg-[var(--accent)]"
  defp activity_marker_class(:success), do: "bg-[var(--success)]"
  defp activity_marker_class(:warning), do: "bg-[var(--warning)]"
  defp activity_marker_class(:error), do: "bg-[var(--danger)]"
  defp activity_marker_class(_tone), do: "bg-[var(--text-faint)]"
end
