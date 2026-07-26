defmodule UPnP.HTTP do
  @moduledoc """
  Injectable HTTP transport used for descriptions, SOAP, and GENA.
  """

  alias UPnP.HTTP.{Request, Response}

  @type adapter :: module() | {module(), keyword()}
  @type error ::
          {:transport, term()}
          | {:body_too_large, non_neg_integer()}
          | :malformed_response
  @type deadline_error :: error() | :timeout | {:task_exit, term()}

  @callback request(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}

  @doc "Runs a request through an adapter."
  @spec request(adapter(), Request.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def request(adapter, request, options \\ [])

  def request({module, adapter_options}, %Request{} = request, options) do
    module.request(request, Keyword.merge(adapter_options, options))
  end

  def request(module, %Request{} = request, options) when is_atom(module) do
    module.request(request, options)
  end

  @doc """
  Runs a request with a deadline driven by the configured UPnP clock.

  The HTTP adapter itself remains synchronous; the request is isolated in a
  supervised task so reaching the deadline also terminates the in-flight work.
  """
  @spec request_with_deadline(adapter(), Request.t(), keyword()) ::
          {:ok, Response.t()} | {:error, deadline_error()}
  def request_with_deadline(adapter, %Request{} = request, options) do
    timeout = Keyword.fetch!(options, :timeout)
    clock = Keyword.get(options, :clock, UPnP.Clock.System)
    supervisor = Keyword.get(options, :supervisor, UPnP.TaskSupervisor)
    request_options = Keyword.get(options, :request_options, [])

    case UPnP.Async.run(
           fn -> request(adapter, request, request_options) end,
           timeout: timeout,
           clock: clock,
           supervisor: supervisor
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
