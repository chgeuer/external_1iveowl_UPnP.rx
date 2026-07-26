defmodule UPnP.XML do
  @moduledoc """
  Shared, total XML helpers for UPnP's receive-side wire formats.

  XML is parsed with `Saxy.SimpleForm`, so element and attribute names remain
  binaries. Lookups compare case-insensitive local names and ignore namespaces.
  """

  alias UPnP.ParseError

  @typedoc "A Saxy simple-form XML element."
  @type element ::
          {binary(), [{binary(), binary()}], [binary() | {:cdata, binary()} | element()]}

  @bare_ampersand ~r/&(?!(?:[A-Za-z_][A-Za-z0-9._:-]*|#[0-9]+|#x[0-9A-Fa-f]+);)/

  @doc """
  Parses a UTF-8 XML document, retrying once after escaping bare ampersands.
  """
  @spec parse(binary(), atom()) :: {:ok, element()} | {:error, ParseError.t()}
  def parse(xml, source \\ :xml) when is_binary(xml) and is_atom(source) do
    if String.valid?(xml) do
      parse_with_retry(xml, source)
    else
      error(source, "XML input is not valid UTF-8", :invalid_utf8)
    end
  end

  @doc "Escapes ampersands which do not begin an entity or character reference."
  @spec escape_bare_ampersands(binary()) :: binary()
  def escape_bare_ampersands(xml) when is_binary(xml) do
    Regex.replace(@bare_ampersand, xml, "&amp;")
  end

  @doc "Returns the local part of a qualified binary XML name."
  @spec local_name(binary()) :: binary()
  def local_name(name) when is_binary(name) do
    name
    |> :binary.split(":", [:global])
    |> List.last()
  end

  @doc "Tests a binary XML name against a local name without regard to casing."
  @spec name?(binary(), binary()) :: boolean()
  def name?(name, expected) when is_binary(name) and is_binary(expected) do
    caseless_equal?(local_name(name), expected)
  end

  @doc "Returns direct child elements with the requested local name."
  @spec children(element(), binary()) :: [element()]
  def children({_name, _attributes, content}, expected) when is_binary(expected) do
    Enum.filter(content, fn
      {name, attributes, child_content}
      when is_binary(name) and is_list(attributes) and is_list(child_content) ->
        name?(name, expected)

      _other ->
        false
    end)
  end

  @doc "Returns the first direct child with the requested local name."
  @spec child(element(), binary()) :: element() | nil
  def child(element, expected) when is_binary(expected) do
    element
    |> children(expected)
    |> List.first()
  end

  @doc "Returns all descendant elements in document order."
  @spec descendants(element()) :: [element()]
  def descendants({_name, _attributes, content}) do
    Enum.flat_map(content, fn
      {name, attributes, child_content} = child
      when is_binary(name) and is_list(attributes) and is_list(child_content) ->
        [child | descendants(child)]

      _other ->
        []
    end)
  end

  @doc "Finds the first matching element, including the supplied root."
  @spec find_first(element(), binary()) :: element() | nil
  def find_first({name, _attributes, _content} = element, expected) when is_binary(expected) do
    if name?(name, expected) do
      element
    else
      Enum.find(descendants(element), fn {descendant_name, _, _} ->
        name?(descendant_name, expected)
      end)
    end
  end

  @doc "Returns an attribute value by case-insensitive local name."
  @spec attribute(element(), binary()) :: binary() | nil
  def attribute({_name, attributes, _content}, expected) when is_binary(expected) do
    Enum.find_value(attributes, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if name?(name, expected), do: value

      _other ->
        nil
    end)
  end

  @doc "Returns all descendant character data for an element."
  @spec text(element()) :: binary()
  def text({_name, _attributes, content}) do
    content
    |> Enum.flat_map(&text_fragments/1)
    |> IO.iodata_to_binary()
  end

  @doc "Returns trimmed element text, or nil when it is empty."
  @spec text_or_nil(element() | nil) :: binary() | nil
  def text_or_nil(nil), do: nil

  def text_or_nil(element) do
    case element |> text() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  @doc "Returns the trimmed text of a named direct child."
  @spec child_text(element(), binary()) :: binary() | nil
  def child_text(element, expected) when is_binary(expected) do
    element
    |> child(expected)
    |> text_or_nil()
  end

  @doc "Returns child text with every whitespace run removed."
  @spec child_token(element(), binary()) :: binary() | nil
  def child_token(element, expected) when is_binary(expected) do
    case child(element, expected) do
      nil ->
        nil

      child ->
        case child |> text() |> String.replace(~r/\s+/u, "") do
          "" -> nil
          value -> value
        end
    end
  end

  @doc "Parses a named child as a base-10 integer, returning nil when malformed."
  @spec child_integer(element(), binary()) :: integer() | nil
  def child_integer(element, expected) when is_binary(expected) do
    case child_token(element, expected) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> nil
        end
    end
  end

  @doc "Parses an attribute as a base-10 integer, returning nil when malformed."
  @spec attribute_integer(element(), binary()) :: integer() | nil
  def attribute_integer(element, expected) when is_binary(expected) do
    case attribute(element, expected) do
      nil ->
        nil

      value ->
        case value |> String.trim() |> Integer.parse() do
          {integer, ""} -> integer
          _other -> nil
        end
    end
  end

  @doc "Returns a usable absolute HTTP(S) URI, or nil."
  @spec absolute_http_uri(binary() | URI.t() | nil) :: URI.t() | nil
  def absolute_http_uri(nil), do: nil

  def absolute_http_uri(%URI{} = uri) do
    if http_uri?(uri), do: uri
  end

  def absolute_http_uri(value) when is_binary(value) do
    try do
      case URI.new(value) do
        {:ok, uri} -> absolute_http_uri(uri)
        {:error, _part} -> nil
      end
    rescue
      _error -> nil
    end
  end

  @doc "Resolves an HTTP(S) URL against a base URI, returning nil when unusable."
  @spec resolve_url(URI.t(), binary() | nil) :: URI.t() | nil
  def resolve_url(%URI{} = base_url, raw) when is_binary(raw) do
    try do
      with {:ok, relative_or_absolute} <- URI.new(raw) do
        base_url
        |> URI.merge(relative_or_absolute)
        |> absolute_http_uri()
      else
        {:error, _part} -> nil
      end
    rescue
      _error -> nil
    end
  end

  def resolve_url(%URI{}, nil), do: nil

  defp parse_with_retry(xml, source) do
    case safe_parse(xml) do
      {:ok, document} ->
        {:ok, document}

      {:error, initial_reason} ->
        repaired = escape_bare_ampersands(xml)

        case safe_parse(repaired) do
          {:ok, document} ->
            {:ok, document}

          {:error, _retry_reason} ->
            message = "input is not well-formed UTF-8 XML: #{reason_message(initial_reason)}"
            error(source, message, initial_reason)
        end
    end
  end

  defp safe_parse(xml) do
    case Saxy.SimpleForm.parse_string(xml, expand_entity: :keep, cdata_as_characters: true) do
      {:ok, {name, attributes, content} = document}
      when is_binary(name) and is_list(attributes) and is_list(content) ->
        {:ok, document}

      {:ok, other} ->
        {:error, {:invalid_document, other}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp text_fragments(value) when is_binary(value), do: [value]
  defp text_fragments({:cdata, value}) when is_binary(value), do: [value]

  defp text_fragments({name, attributes, content})
       when is_binary(name) and is_list(attributes) and is_list(content) do
    Enum.flat_map(content, &text_fragments/1)
  end

  defp text_fragments(_other), do: []

  defp caseless_equal?(left, right) do
    String.downcase(left) == String.downcase(right)
  end

  defp http_uri?(%URI{scheme: scheme, host: host, port: port})
       when is_binary(scheme) and is_binary(host) and host != "" do
    String.valid?(scheme) and String.valid?(host) and
      String.downcase(scheme) in ["http", "https"] and
      (is_nil(port) or port in 1..65_535)
  end

  defp http_uri?(_uri), do: false

  defp reason_message(%{__exception__: true} = error), do: Exception.message(error)
  defp reason_message(reason), do: inspect(reason)

  defp error(source, message, reason) do
    {:error, %ParseError{source: source, message: message, reason: reason}}
  end
end
