defmodule UPnP.ControlPoint.Runtime do
  @moduledoc """
  The isolated OTP subtree owned by one control point.

  Every control point started with `{UPnP.ControlPoint, options}` or
  `UPnP.start_control_point/1` gets its own runtime. The runtime root is
  `:transient` and uses `:one_for_all`, so the coordinator and the supervisors
  it depends on are restarted as one coherent unit and never outlive each
  other. A failure inside one control point cannot reach another.

  The coordinator is a `:transient` significant child of an
  `auto_shutdown: :any_significant` supervisor: a coordinator crash restarts the
  whole runtime, while a coordinator that stops normally after saying its
  protocol goodbyes shuts the runtime down instead of resurrecting it.

  The runtime owns, in start order:

  1. a `Task.Supervisor` for that control point's asynchronous work,
  2. a `DynamicSupervisor` for its SSDP interface workers,
  3. a `DynamicSupervisor` for its GENA subscription workers,
  4. a `DynamicSupervisor` for its GENA callback listener,
  5. a `DynamicSupervisor` for its eventing manager, and
  6. the `UPnP.ControlPoint` coordinator itself.

  Shutdown runs in reverse, so the coordinator says its protocol goodbyes
  before the supervisors holding sockets and workers go away.

  Only genuinely shared or independently owned infrastructure stays at
  application scope: the Finch pool, the `UPnP.Registry`, the dynamic
  supervisor holding runtime roots, and the IGD lease infrastructure.

  ## Naming

  Each runtime has a unique identity. Its components are registered in
  `UPnP.Registry` under `{identity, component}`, which is what lets a public
  control-point handle resolve to the coordinator and to the owned supervisors
  without walking the tree. Prefer `UPnP.ControlPoint.whereis/1` and
  `UPnP.ControlPoint.runtime/1` over these keys.
  """

  use Supervisor

  @components [
    :runtime,
    :coordinator,
    :tasks,
    :ssdp_interfaces,
    :eventing_managers,
    :eventing_subscriptions,
    :eventing_servers
  ]

  @typedoc "The unique identity of one control point runtime."
  @type id :: reference()

  @typedoc "A process owned by, or naming, one control point runtime."
  @type component ::
          :runtime
          | :coordinator
          | :tasks
          | :ssdp_interfaces
          | :eventing_managers
          | :eventing_subscriptions
          | :eventing_servers

  @doc """
  Starts one control point runtime.

  Options are the `UPnP.ControlPoint` options; `:name`, when given, names the
  coordinator rather than this supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) when is_list(options) do
    id = make_ref()
    Supervisor.start_link(__MODULE__, {id, options}, name: name(id, :runtime))
  end

  @doc """
  Returns the `:via` name of one runtime component.
  """
  @spec name(id(), component()) :: GenServer.name()
  def name(id, component) when component in @components do
    {:via, Registry, {UPnP.Registry, {id, component}}}
  end

  @doc """
  Resolves one runtime component to a live process, or `nil`.
  """
  @spec whereis(id(), component()) :: pid() | nil
  def whereis(id, component) when component in @components do
    case Registry.lookup(UPnP.Registry, {id, component}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns the runtime identity and role a process was registered under.

  Processes that belong to no runtime return `nil`.
  """
  @spec identity(pid()) :: {id(), component()} | nil
  def identity(pid) when is_pid(pid) do
    case Registry.keys(UPnP.Registry, pid) do
      [{_id, component} = identity] when component in @components -> identity
      _other -> nil
    end
  end

  @doc false
  @spec register(id(), component()) :: :ok | {:error, term()}
  def register(id, component) when component in @components do
    case Registry.register(UPnP.Registry, {id, component}, nil) do
      {:ok, _owner} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init({id, options}) do
    children = [
      {Task.Supervisor, name: name(id, :tasks)},
      {DynamicSupervisor, name: name(id, :ssdp_interfaces), strategy: :one_for_one},
      {DynamicSupervisor, name: name(id, :eventing_subscriptions), strategy: :one_for_one},
      {DynamicSupervisor, name: name(id, :eventing_servers), strategy: :one_for_one},
      {DynamicSupervisor, name: name(id, :eventing_managers), strategy: :one_for_one},
      coordinator(id, options)
    ]

    Supervisor.init(children, strategy: :one_for_all, auto_shutdown: :any_significant)
  end

  defp coordinator(id, options) do
    %{
      id: :coordinator,
      start: {UPnP.ControlPoint, :start_coordinator, [Keyword.put(options, :runtime_id, id)]},
      type: :worker,
      restart: :transient,
      significant: true,
      shutdown: 5_000
    }
  end
end
