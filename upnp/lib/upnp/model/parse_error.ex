defmodule UPnP.ParseError do
  @moduledoc """
  Inspectable error returned by UPnP wire parsers.

  Parsers return this exception struct as data and do not raise it for malformed
  network input.
  """

  defexception message: "unable to parse UPnP wire data", source: nil, reason: nil

  @type t :: %__MODULE__{
          message: binary(),
          source: atom() | nil,
          reason: term()
        }
end
