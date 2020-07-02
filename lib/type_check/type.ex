defmodule TypeCheck.Type do
  @moduledoc """
  TODO
  """

  @typedoc """
  Something is a TypeCheck.Type if it implements the TypeCheck.Protocols.ToCheck protocol.

  It is also expected to implement the TypeCheck.Protocols.Inspect protocol (although that has an `Any` fallback).

  In practice, this type means 'any of the' structs in the `TypeCheck.Builtin.*` modules.
  """
  @type t() :: any()

  @typedoc """
  Indicates that we expect a 'type AST' that will be expanded
  to a proper type. This means that it might contain essentially the full syntax that Elixir Typespecs
  allow, which will be rewritten to calls to the functions in `TypeCheck.Builtin`.

  See `TypeCheck.Builtin` for the precise syntax you are allowed to use.
  """
  @type expandable_type() :: any()


  defmacro build(type_ast) do
    type_ast
    |> build_unescaped(__CALLER__)
    |> Macro.escape()
  end

  @doc false
  # Building block of macros that take an unexpanded type-AST as input.
  #
  # Transforms `type_ast` (which is expected to be a quoted Elixir AST) into a type value.
  # The result is _not_ escaped
  # assuming that you'd want to do further compile-time work with the type.
  def build_unescaped(type_ast, caller, add_typecheck_module \\ false) do
    type_ast = TypeCheck.Internals.PreExpander.rewrite(type_ast, caller)
    code =
    if add_typecheck_module do
      quote do
        import __MODULE__.TypeCheck
        unquote(type_ast)
      end
    else
      type_ast
    end

    {type, []} = Code.eval_quoted(code, [], caller)
    type
  end

  defmacro to_typespec(type) do
    TypeCheck.Internals.ToTypespec.rewrite(type, __CALLER__)
  end

  def is_type?(possibly_a_type) do
    TypeCheck.Protocols.ToCheck.impl_for(possibly_a_type) != nil
  end

  @doc false
  def ensure_type!(possibly_a_type) do
    case TypeCheck.Protocols.ToCheck.impl_for(possibly_a_type) do
      nil ->
        raise """
        Invalid value passed to a function expecting a type!
        `#{inspect(possibly_a_type)}` is not a valid TypeCheck type.
        You probably tried to use a TypeCheck type as a function directly.

        Instead, either implement named types using the `type`, `typep`, `opaque` macros,
        or use TypeCheck.Type.build/1 to construct a one-off type.

        Both of these will perform the necessary conversions to turn 'normal' datatypes to types.
        """
      _other -> :ok
    end
  end

  if Code.ensure_loaded?(StreamData) do
    defmodule StreamData do
      @moduledoc """
      Transforms types to generators.

      This module is only included when the optional dependency
      `:stream_data` is added to your project's dependencies.
      """

      @doc """
      When given a type, it is transformed to a StreamData generator
      that can be used in a property test.

      """
      def gen(type) do
        TypeCheck.Protocols.ToStreamData.to_gen(type)
      end
    end
  end


  defmodule Public do
    defstruct [:name_with_maybe_params, :structure]

    defimpl TypeCheck.Protocols.Inspect do
      def inspect(s, opts) do
        "#{Macro.to_string(s.name_with_maybe_params)}"
      end
    end

    defimpl TypeCheck.Protocols.ToCheck do
      def to_check(s, param) do
        child_check = TypeCheck.Protocols.ToCheck.to_check(s.structure, param)
        quote do
          case unquote(child_check) do
            {:ok, bindings} ->
              {:ok, bindings}
            {:error, problem} ->
              {:error, {unquote(Macro.escape(s)), :no_match, %{problem: problem}, unquote(param)}}
          end
        end
      end
    end
  end

  defmodule Private do
    defstruct [:name_with_maybe_params, :structure]

    defimpl TypeCheck.Protocols.Inspect do
      def inspect(s, opts) do
        "#{Macro.to_string(s.name_with_maybe_params)} (private type)"
      end
    end

    defimpl TypeCheck.Protocols.ToCheck do
      def to_check(s, param) do
        child_check = TypeCheck.Protocols.ToCheck.to_check(s.structure, param)
        quote do
          case unquote(child_check) do
            {:ok, bindings} ->
              {:ok, bindings}
            {:error, problem} ->
              {:error, {unquote(Macro.escape(s)), :no_match, %{problem: problem}, unquote(param)}}
          end
        end
      end
    end
  end

  defmodule Opaque do
    defstruct [:name_with_maybe_params, :structure]
    defimpl TypeCheck.Protocols.Inspect do
      def inspect(s, opts) do
        "#{Macro.to_string(s.name_with_maybe_params)} (opaque type)"
      end
    end

    defimpl TypeCheck.Protocols.ToCheck do
      def to_check(s, param) do
        child_check = TypeCheck.Protocols.ToCheck.to_check(s.structure, param)
        quote do
          case unquote(child_check) do
            {:ok, bindings} ->
              {:ok, bindings}
            {:error, problem} ->
              {:error, {unquote(Macro.escape(s)), :no_match, %{problem: problem}, unquote(param)}}
          end
        end
      end
    end
  end
end
