defmodule Binary.Dict do
  @moduledoc """
  This module implements a dictionary that forces the keys to
  be converted to binaries on insertion. Currently it is
  implemented using a `List.Dict` underneath, but this may
  change in the future.

  Check the `Dict` module for examples and documentation.
  """

  defstruct datamap: %{}

  import Kernel, except: [to_binary: 1]
  @compile { :inline, to_binary: 1 }

  defp to_binary(key) do
    if is_binary(key), do: key, else: to_string(key)
  end

  defmacrop dict(enum) do
    quote do
      %__MODULE__{datamap: Enum.into(unquote(enum), %{})}
    end
  end

  def new, do: dict([])

  def new(pairs) do
    dict Enum.map pairs, fn({ k, v }) -> { to_binary(k), v } end
  end

  def new(pairs, transform) when is_function(transform) do
    dict Enum.map pairs, fn(entry) ->
      { k, v } = transform.(entry)
      { to_binary(k), v }
    end
  end

  @doc false
  def keys(%__MODULE__{} = dict) do
    Map.keys dict.datamap
  end

  @doc false
  def values(%__MODULE__{} = dict) do
    Map.values dict.datamap
  end

  @doc false
  def size(%__MODULE__{} = dict) do
    Map.size dict.datamap
  end

  @doc false
  def has_key?(%__MODULE__{} = dict, key) do
    Map.has_key?(dict.datamap, to_binary(key))
  end

  @doc false
  def get(%__MODULE__{} = dict, key, default \\ nil) do
    Map.get(dict.datamap, to_binary(key), default)
  end

  @doc false
  def get!(%__MODULE__{} = dict, key) do
    Map.get!(dict.datamap, to_binary(key))
  end

  @doc false
  def fetch(%__MODULE__{} = dict, key) do
    Map.fetch(dict.datamap, to_binary(key))
  end

  @doc false
  def put(%__MODULE__{} = dict, key, value) do
    %{dict | datamap: Map.put(dict.datamap, to_binary(key), value)}
  end

  @doc false
  def put_new(%__MODULE__{} = dict, key, value) do
     %{dict | datamap: Map.put_new(dict.datamap, to_binary(key), value)}
  end

  @doc false
  def delete(%__MODULE__{} = dict, key) do
    %{dict | datamap: Map.delete(dict.datamap, to_binary(key))}
  end

  @doc false
  def merge(%__MODULE__{} = dict, enum, fun \\ fn(_k, _v1, v2) -> v2 end) do
    new_datamap = Enum.reduce enum, dict.datamap, fn({ k, v2 }, acc) ->
      k = to_binary(k)
      Map.update(acc, k, v2, fn(v1) -> fun.(k, v1, v2) end)
    end
    %{dict | datamap: new_datamap}
  end

  @doc false
  def update(%__MODULE__{} = dict, key, fun) do
    %{dict | datamap: Map.update(dict.datamap, to_binary(key), fun)}
  end

  @doc false
  def update(%__MODULE__{} = dict, key, initial, fun) do
    %{dict | datamap: Map.update(dict.datamap, to_binary(key), initial, fun)}
  end

  @doc false
  def empty(_) do
    dict([])
  end

  @doc false
  def to_list(%__MODULE__{} = dict) do
    Map.to_list(dict.datamap)
  end

end

defimpl Enumerable, for: Binary.Dict do
  def reduce(%Binary.Dict{} = dict, acc, fun), do: :lists.foldl(fun, acc, Map.to_list(dict.datamap))
  def count(%Binary.Dict{} = dict),            do: Map.size(dict.datamap) 
  def member?(%Binary.Dict{} = dict, v),       do: :lists.member(v, Map.to_list(dict.datamap))
end

defimpl Access, for: Binary.Dict do
  def get(%Binary.Dict{} = dict, key) do
    case :maps.find(to_string(key), dict.datamap) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  def get_and_update(%Binary.Dict{} = dict, key, fun)  do
    value =
      case :maps.find(to_string(key), dict.datamap) do
        {:ok, value} -> value
        :error -> nil
      end

     {get, update} = fun.(value)
     {get, %{dict | datamap: :maps.put(key, update, dict.datamap)} }
  end

end

defimpl Inspect, for: Binary.Dict do
  import Inspect.Algebra

  def inspect(%Binary.Dict{} = dict, opts) do
    concat ["#Binary.Dict", Inspect.Map.inspect(dict.datamap, opts)]
  end
end
