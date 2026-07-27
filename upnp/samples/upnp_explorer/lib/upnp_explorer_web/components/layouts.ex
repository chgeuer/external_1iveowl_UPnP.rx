defmodule UpnpExplorerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use UpnpExplorerWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :string, default: "devices", values: ~w(devices activity gateway)

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div
      id="tauri-bridge"
      class="hidden"
      phx-hook="TauriHook"
      phx-update="ignore"
      aria-hidden="true"
    >
    </div>

    <header class="sticky top-0 z-40 border-b border-[var(--line)] bg-[var(--shell)] backdrop-blur-xl">
      <div class="mx-auto flex h-16 w-full max-w-[1800px] items-center gap-4 px-4 sm:px-6">
        <.link navigate={~p"/"} class="flex min-w-0 items-center gap-2.5">
          <span class="relative grid size-8 shrink-0 place-items-center rounded-md border border-[var(--accent-border)] bg-[var(--accent-soft)] text-[var(--accent)]">
            <.icon name="hero-signal" class="size-4" />
          </span>
          <span class="hidden min-w-0 sm:block">
            <span class="block truncate text-sm font-semibold tracking-[-0.02em] text-[var(--text)]">
              UPnP Explorer
            </span>
            <span class="block text-[0.62rem] uppercase tracking-[0.1em] text-[var(--text-faint)]">
              Home network
            </span>
          </span>
        </.link>

        <nav class="ml-auto flex h-full items-center gap-1" aria-label="Primary navigation">
          <.link
            :for={
              {label, path, icon, key} <- [
                {"Devices", ~p"/", "hero-rectangle-stack", "devices"},
                {"Activity", ~p"/activity", "hero-list-bullet", "activity"},
                {"Gateway", ~p"/gateway", "hero-globe-alt", "gateway"}
              ]
            }
            navigate={path}
            aria-current={@active == key && "page"}
            class={[
              "relative inline-flex h-10 items-center gap-2 rounded-md px-2.5 text-xs font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] sm:px-3",
              @active == key && "bg-[var(--accent-soft)] text-[var(--accent)]",
              @active != key &&
                "text-[var(--text-muted)] hover:bg-[var(--surface-hover)] hover:text-[var(--text)]"
            ]}
          >
            <.icon name={icon} class="size-4" />
            <span class="hidden md:inline">{label}</span>
            <span
              :if={@active == key}
              class="absolute inset-x-2 -bottom-[0.82rem] h-0.5 rounded-full bg-[var(--accent)]"
            ></span>
          </.link>
        </nav>

        <div class="h-5 w-px bg-[var(--line)]"></div>
        <.theme_toggle />
      </div>
    </header>

    <div class="pt-3 sm:pt-5">
      {render_slot(@inner_block)}
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides system, light, and dark theme controls.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="flex items-center rounded-md border border-[var(--line-strong)] bg-[var(--surface)] p-0.5">
      <button
        type="button"
        class="theme-option"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="Use system theme"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5" />
      </button>

      <button
        type="button"
        class="theme-option"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Use light theme"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-3.5" />
      </button>

      <button
        type="button"
        class="theme-option"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Use dark theme"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-3.5" />
      </button>
    </div>
    """
  end
end
