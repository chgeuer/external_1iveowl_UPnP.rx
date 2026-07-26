for file <- ["interfaces.ex", "device_tree.ex", "runtime.ex"] do
  Code.require_file(Path.join([__DIR__, "support", file]))
end
