defmodule UPnP.WireInterfaceTest do
  use ExUnit.Case, async: true

  @canonical_functions [
    {UPnP.Description, :parse, 2},
    {UPnP.SCPD, :parse, 1},
    {UPnP.SOAP, :compose, 3},
    {UPnP.SOAP, :soap_action_header, 2},
    {UPnP.SOAP, :parse, 2},
    {UPnP.SOAP, :parse_fault, 1},
    {UPnP.Eventing.PropertySet, :parse, 1},
    {UPnP.SSDP, :parse, 1},
    {UPnP.SSDP, :m_search, 2},
    {UPnP.Eventing.AV.LastChange, :parse, 1}
  ]

  @removed_modules [
    UPnP.Description.Parser,
    UPnP.SCPD.Parser,
    UPnP.Eventing.Parser,
    UPnP.Eventing.AV.Parser
  ]

  @removed_functions [
    {UPnP.Description, :parse_device_description, 2},
    {UPnP.SOAP, :compose_action_request, 3},
    {UPnP.SOAP, :compose_soap_action_header, 2},
    {UPnP.SOAP, :parse_response, 2},
    {UPnP.SOAP, :parse_action_response, 2},
    {UPnP.SOAP.Composer, :compose_action_request, 3},
    {UPnP.SOAP.Composer, :compose_soap_action_header, 2},
    {UPnP.SOAP.Parser, :parse_response, 2},
    {UPnP.SOAP.Parser, :parse_action_response, 2}
  ]

  @implementation_modules [
    UPnP.SOAP.Composer,
    UPnP.SOAP.Parser,
    UPnP.SSDP.Composer,
    UPnP.SSDP.Parser
  ]

  test "wire formats expose one documented canonical interface" do
    Enum.each(@canonical_functions, fn {module, function, arity} ->
      assert Code.ensure_loaded?(module), "expected #{inspect(module)} to load"

      assert function_exported?(module, function, arity),
             "expected #{inspect(module)}.#{function}/#{arity} to be exported"

      assert documented?(module, function, arity),
             "expected #{inspect(module)}.#{function}/#{arity} to be documented"
    end)
  end

  test "redundant wire interfaces are removed" do
    Enum.each(@removed_modules, fn module ->
      refute Code.ensure_loaded?(module), "expected #{inspect(module)} to be removed"
    end)

    Enum.each(@removed_functions, fn {module, function, arity} ->
      refute function_exported?(module, function, arity),
             "expected #{inspect(module)}.#{function}/#{arity} to be removed"
    end)
  end

  test "directional implementation modules are hidden from ExDoc" do
    Enum.each(@implementation_modules, fn module ->
      assert {:docs_v1, _, _, _, :hidden, _, _} = Code.fetch_docs(module)
    end)
  end

  defp documented?(module, function, arity) do
    with {:docs_v1, _, _, _, _, _, entries} <- Code.fetch_docs(module) do
      Enum.any?(entries, fn
        {{:function, ^function, ^arity}, _, _, %{"en" => documentation}, _}
        when is_binary(documentation) and documentation != "" ->
          true

        _other ->
          false
      end)
    else
      _other -> false
    end
  end
end
