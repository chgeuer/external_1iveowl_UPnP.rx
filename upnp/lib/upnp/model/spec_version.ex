defmodule UPnP.SpecVersion do
  @moduledoc "The UPnP architecture version declared by an XML description."

  defstruct major: nil, minor: 0

  @type t :: %__MODULE__{
          major: non_neg_integer() | nil,
          minor: non_neg_integer()
        }
end
