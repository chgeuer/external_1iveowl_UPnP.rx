defmodule UpnpExplorer.Activity do
  @moduledoc "A bounded, UI-facing explanation of one network event."

  @enforce_keys [:id, :category, :kind, :title, :occurred_at]
  defstruct [
    :id,
    :category,
    :kind,
    :device_id,
    :title,
    :detail,
    :occurred_at,
    :tone,
    count: 1
  ]

  @type category :: :change | :wire | :system
  @type t :: %__MODULE__{category: category()}

  @doc "Creates an activity with a stable sequence ID."
  @spec new(non_neg_integer(), category(), atom(), binary(), DateTime.t(), keyword()) :: t()
  def new(sequence, category, kind, title, occurred_at, options \\ []) do
    %__MODULE__{
      id: "activity-#{sequence}",
      category: category,
      kind: kind,
      device_id: Keyword.get(options, :device_id),
      title: title,
      detail: Keyword.get(options, :detail),
      occurred_at: occurred_at,
      tone: Keyword.get(options, :tone, :neutral)
    }
  end

  @doc "Reports whether an activity belongs in the selected feed mode."
  @spec matches?(t(), :changes | :wire | :all) :: boolean()
  def matches?(%__MODULE__{category: :wire}, :changes), do: false
  def matches?(%__MODULE__{category: :wire}, :wire), do: true
  def matches?(%__MODULE__{}, :wire), do: false
  def matches?(%__MODULE__{}, mode) when mode in [:changes, :all], do: true
end
