defmodule TypeCheck.Builtin.Literal do
  defstruct [:value]

  defimpl TypeCheck.Protocols.ToCheck do
    def to_check(%{value: value}, param) do
      quote do
        case unquote(param) do
          x when x === unquote(value) ->
            :ok
          _ ->
            {:error, {TypeCheck.Builtin.Literal, :not_same_value, %{value: unquote(value)}, unquote(param)}}
        end
      end
    end
  end
end