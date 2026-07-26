defmodule UPnP.DescriptionControlInterfaceTest do
  use ExUnit.Case, async: true

  @target Path.expand("description_control_test.exs", __DIR__)

  test "description control cache tests stay behind public interfaces" do
    source = File.read!(@target)
    assert {:ok, quoted} = Code.string_to_quoted(source)

    refute contains_atom?(quoted, :"$gen_call")
    refute remote_call?(quoted, :sys, :get_state)
  end

  defp contains_atom?(quoted, atom) do
    {_quoted, found?} =
      Macro.prewalk(quoted, false, fn node, found? ->
        {node, found? or node == atom}
      end)

    found?
  end

  defp remote_call?(quoted, module, function) do
    {_quoted, found?} =
      Macro.prewalk(quoted, false, fn
        {{:., _meta, [^module, ^function]}, _call_meta, _arguments} = node, _found? ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end
end
