defmodule TypeCheck.Macros do
  @moduledoc """
  Contains the `@spec!`, `@type!`, `@typep!`, `@opaque!` macros to define runtime-checked function- and type-specifications.

  ## Usage

  This module is included by calling `use TypeCheck`.
  This will set up the module to use the special macros.

  Usually you'll want to use the module attribute-style of the macros, like
  `@spec!` and `@type!`.
  Using these forms has two advantages over using the direct calls:

  1. Syntax highlighting will highlight the types correctly
  and the Elixir formatter will not mess with the way you write your type.
  2. It is clear to people who have not heard of `TypeCheck` before that `@type!` and `@spec!`
  will work similarly to resp. `@type` and `@spec`.

  ### Avoiding naming conflicts with TypeCheck.Builtin

  If you want to define a type with the same name as one in TypeCheck.Builtin,
  _(which is not particularly recommended)_,
  you should hide those particular functions from TypeCheck.Builtin by adding
  `import TypeCheck.Builtin, except: [...]`
  below `use TypeCheck` manually.

  ### Calling the explicit implementations

  In case you are working in an environment where the `@/1` is already overridden
  by another library, you can still use this library,
  by simply adding `import TypeCheck.Macros, except: [@: 1]` to your module
  and calling the direct versions of the macros instead.


  ### TypeCheck and metaprogramming

  In certain cases you might want to use TypeCheck to dynamically generate
  types or functions, such as to add `@spec!`-s to functions
  that themselves are dynamically generated.

  TypeCheck's macros support 'unquote fragments',
  just like many builtin 'definition' constructs like `def`, but also `@type` do.
  (c.f. `Elixir.Kernel.SpecialForms.quote/2` for more details about unquote fragments.)

  An example:

  ```
  defmodule MetaExample do
    use TypeCheck
    people = ~w[joe robert mike]a
    for name <- people do
      @type! unquote(name)() :: %{name: unquote(name), coolness_level: :high}
    end
  end
  ```

  ```
  iex> MetaExample.joe
  #TypeCheck.Type< %{coolness_level: :high, name: :joe} >

  iex> MetaExample.mike
  #TypeCheck.Type< %{coolness_level: :high, name: :mike} >

  ```

  #### Macros

  Inside macros, we use unquote fragments in the same way.
  There is however one more thing to keep in mind:
  You'll need to add a call to `import Kernel, except: [@: 1]` in your macro (before the quote)
  to make sure you can call `@type!`, `@spec!` etc.
  This is a subtle consequence of Elixir's macro-hygiene rules.
  [See this issue on Elixir's GitHub repository for more info](https://github.com/elixir-lang/elixir/issues/10497#issuecomment-729479434)

  (Alternatively, directly calls to `type!`, `spec!` etc. are possible without overriding the import.)

  An example:

  ```
  defmodule GreeterMacro do
    defmacro generate_greeter(greeting) do
      import Kernel, except: [@: 1] # Ensures TypeSpec's overridden `@` is used in the quote
      quote do
        @spec! unquote(greeting)(binary) :: binary
        def unquote(greeting)(name) do
          "\#{greeting}, \#{name}!"
        end
      end
    end
  end

  defmodule GreeterExample do
    use TypeCheck
    require GreeterMacro

    GreeterMacro.generate_greeter(:hi)
    GreeterMacro.generate_greeter(:hello)
  end
  ```

  ```
  iex> GreeterExample.hi("John")
  "hi, John!"

  iex> GreeterExample.hello("Frank")
  "hello, Frank!"

  iex> GreeterExample.hi(42)
  ** (TypeCheck.TypeError) At test/type_check/macros_test.exs:32:
  The call to `hi/1` failed,
  because parameter no. 1 does not adhere to the spec `binary()`.
  Rather, its value is: `42`.
  Details:
    The call `hi(42)`
    does not adhere to spec `hi(binary()) :: binary()`. Reason:
      parameter no. 1:
        `42` is not a binary.

  ```

  #### About `use TypeCheck`

  The `use TypeCheck` statement adds an `@before_compile`-hook to the final module,
  which is used to wrap functions with the specified runtime type-checks.

  This means that some care needs to be taken to ensure that a call to `use TypeCheck` exists
  in the final module, if you're generating specs dynamically from inside macros.
  """
  defmacro __using__(options) do
    quote generated: true, location: :keep do
      import Kernel, except: [@: 1]
      import TypeCheck.Macros, only: [type!: 1, typep!: 1, opaque!: 1, spec!: 1, @: 1]
      @compile {:inline_size, 1080}

      Module.register_attribute(__MODULE__, TypeCheck.TypeDefs, accumulate: true)
      Module.register_attribute(__MODULE__, TypeCheck.Specs, accumulate: true)
      @before_compile TypeCheck.Macros

      Module.put_attribute(__MODULE__, TypeCheck.Options, TypeCheck.Options.new(unquote(options)))
    end
  end

  defmacro __before_compile__(env) do
    defs = Module.get_attribute(env.module, TypeCheck.TypeDefs)

    compile_time_imports_module_name = Module.concat(TypeCheck.Internals.UserTypes, env.module)

    Module.create(
      compile_time_imports_module_name,
      quote generated: true, location: :keep do
        @moduledoc false
        # This extra module is created
        # so that we can already access the custom user types
        # at compile-time
        # _inside_ the module they will be part of
        unquote(defs)
      end,
      env
    )

    # And now, define all specs:
    definitions = Module.definitions_in(env.module)
    specs = Module.get_attribute(env.module, TypeCheck.Specs)
    spec_defs = create_spec_defs(specs, definitions, env)
    spec_quotes = wrap_functions_with_specs(specs, definitions, env)

    # And now for the tricky bit ;-)
    quote generated: true, location: :keep do
      unquote(spec_defs)

      import unquote(compile_time_imports_module_name)

      unquote(spec_quotes)
    end
  end

  defp create_spec_defs(specs, _definitions, caller) do
    for {name, _line, arity, _clean_params, params_ast, return_type_ast} <- specs do
      require TypeCheck.Type

      typecheck_options = Module.get_attribute(caller.module, TypeCheck.Options, TypeCheck.Options.new())
      param_types = Enum.map(params_ast, &TypeCheck.Type.build_unescaped(&1, caller, typecheck_options, true))
      return_type = TypeCheck.Type.build_unescaped(return_type_ast, caller, typecheck_options, true)

      TypeCheck.Spec.create_spec_def(name, arity, param_types, return_type)
    end
  end

  defp wrap_functions_with_specs(specs, definitions, caller) do
    for {name, line, arity, clean_params, params_ast, return_type_ast} <- specs do
      unless {name, arity} in definitions do
        raise ArgumentError, "spec for undefined function #{name}/#{arity}"
      end

      require TypeCheck.Type

      typecheck_options = Module.get_attribute(caller.module, TypeCheck.Options, TypeCheck.Options.new())
      param_types = Enum.map(params_ast, &TypeCheck.Type.build_unescaped(&1, caller, typecheck_options, true))
      return_type = TypeCheck.Type.build_unescaped(return_type_ast, caller, typecheck_options, true)

      {params_spec_code, return_spec_code} =
        TypeCheck.Spec.prepare_spec_wrapper_code(
          name,
          param_types,
          clean_params,
          return_type,
          caller
        )

      res = TypeCheck.Spec.wrap_function_with_spec(
        name,
        line,
        arity,
        clean_params,
        params_spec_code,
        return_spec_code
      )

      if typecheck_options.debug do
        TypeCheck.Internals.Helper.prettyprint_spec("TypeCheck.Macros @spec", res)
      end

      res
    end
  end

  @doc """
  Define a public type specification.

  Usually invoked as `@type!`

  This behaves similarly to Elixir's builtin `@type` attribute,
  and will create a type whose name and definition are public.

  Calling this macro will:

  - Fill the `@type`-attribute with a Typespec-friendly
    representation of the TypeCheck type.
  - Add a (or append to an already existing) `@typedoc` detailing that the type is
    managed by TypeCheck, and containing the full definition of the TypeCheck type.
  - Define a (hidden) public function with the same name (and arity) as the type
    that returns the TypeCheck.Type as a datastructure when called.
    This makes the type usable in calls to:
    - definitions of other type-specifications (in the same or different modules).
    - definitions of function-specifications (in the same or different modules).
    - `TypeCheck.conforms/2` and variants,
    - `TypeCheck.Type.build/1`

  ## Usage

  The syntax is essentially the same as for the built-in `@type` attribute:

  ```elixir
  @type! type_name :: type_description
  ```

  It is possible to create parameterized types as well:

  ```
  @type! dict(key, value) :: [{key, value}]
  ```

  ### Named types

  You can also introduce named types:

  ```
  @type! color :: {red :: integer, green :: integer, blue :: integer}
  ```
  Not only is this nice to document that the same type
  is being used for different purposes,
  it can also be used with a 'type guard' to add custom checks
  to your type specifications:

  ```
  @type! sorted_pair(a, b) :: {first :: a, second :: b} when first <= second
  ```

  """
  defmacro type!(typedef) do
    # The extra indirection here ensures we are able to support unquote fragments
    quote generated: true, location: :keep do
      unquote(Macro.escape(typedef, unquote: true))
      |> TypeCheck.Macros.define_type(:type, __ENV__)
      |> Code.eval_quoted(binding(__ENV__), __ENV__)
    end
  end

  @doc """
  Define a private type specification.


  Usually invoked as `@typep!`

  This behaves similarly to Elixir's builtin `@typep` attribute,
  and will create a type whose name and structure is private
  (therefore only usable in the current module).

  - Fill the `@typep`-attribute with a Typespec-friendly
    representation of the TypeCheck type.
  - Define a private function with the same name (and arity) as the type
    that returns the TypeCheck.Type as a datastructure when called.
    This makes the type usable in calls (in the same module) to:
      - definitions of other type-specifications
      - definitions of function-specifications
      - `TypeCheck.conforms/2` and variants,
      - `TypeCheck.Type.build/1`

  `typep!/1` accepts the same typedef expression as `type!/1`.
  """
  defmacro typep!(typedef) do
    # The extra indirection here ensures we are able to support unquote fragments
    quote generated: true, location: :keep do
      unquote(Macro.escape(typedef, unquote: true))
      |> TypeCheck.Macros.define_type(:typep, __ENV__)
      |> Code.eval_quoted(binding(__ENV__), __ENV__)
    end
  end

  @doc """
  Define a opaque type specification.


  Usually invoked as `@opaque!`

  This behaves similarly to Elixir's builtin `@opaque` attribute,
  and will create a type whose name is public
  but whose structure is private.


  Calling this macro will:

  - Fill the `@opaque`-attribute with a Typespec-friendly
    representation of the TypeCheck type.
  - Add a (or append to an already existing) `@typedoc` detailing that the type is
    managed by TypeCheck, and containing the name of the TypeCheck type.
    (not the definition, since it is an opaque type).
  - Define a (hidden) public function with the same name (and arity) as the type
    that returns the TypeCheck.Type as a datastructure when called.
    This makes the type usable in calls to:
    - definitions of other type-specifications (in the same or different modules).
    - definitions of function-specifications (in the same or different modules).
    - `TypeCheck.conforms/2` and variants,
    - `TypeCheck.Type.build/1`

  `opaque!/1` accepts the same typedef expression as `type!/1`.
  """
  defmacro opaque!(typedef) do
    # The extra indirection here ensures we are able to support unquote fragments
    quote generated: true, location: :keep do
      unquote(Macro.escape(typedef, unquote: true))
      |> TypeCheck.Macros.define_type(:opaque, __ENV__)
      |> Code.eval_quoted(binding(__ENV__), __ENV__)
    end
  end

  @doc """
  Define a function specification.


  Usually invoked as `@spec!`

  A function specification will wrap the function
  with checks that each of its parameters are of the types it expects.
  as well as checking that the return type is as expected.

  ## Usage

  The syntax is essentially the same as for built-in `@spec` attributes:

  ```
  @spec! function_name(type1, type2) :: return_type
  ```

  It is also allowed to introduce named types:

  ```
  @spec! days_since_epoch(year :: integer, month :: integer, day :: integer) :: integer
  ```

  Note that `TypeCheck` does _not_ allow the `when` keyword to be used
  to restrict the types of recurring type variables (which Elixir's
  builtin Typespecs allow). This is because:

  - Usually it is more clear to give a recurring type
    an explicit name.
  - The `when` keyword is used instead for TypeCheck's type guards'.
    (See `TypeCheck.Builtin.guarded_by/2` for more information.)

  """
  defmacro spec!(specdef) do
    # The extra indirection here ensures we are able to support unquote fragments
    quote generated: true, location: :keep do
      unquote(Macro.escape(specdef, unquote: true))
      |> TypeCheck.Macros.define_spec(__ENV__)
      |> Code.eval_quoted(binding(__ENV__), __ENV__)
    end
  end

  @doc false
  def define_type(
         {:when, _, [named_type = {:"::", _, [name_with_maybe_params, _type]}, guard_ast]},
         kind,
         caller
       ) do
    define_type(
      {:"::", [], [name_with_maybe_params, {:when, [], [named_type, guard_ast]}]},
      kind,
      caller
    )
  end

  def define_type({:"::", _meta, [name_with_maybe_params, type]}, kind, caller) do
    clean_typedef = TypeCheck.Internals.ToTypespec.full_rewrite(type, caller)

    new_typedoc =
      case kind do
        :typep ->
          false

        _ ->
          append_typedoc(caller, """
          This type is managed by `TypeCheck`,
          which allows checking values against the type at runtime.

          Full definition:

          #{type_definition_doc(name_with_maybe_params, type, kind, caller)}
          """)
      end

    typecheck_options = Module.get_attribute(caller.module, TypeCheck.Options, TypeCheck.Options.new())
    type = TypeCheck.Internals.PreExpander.rewrite(type, caller, typecheck_options)

    res = type_fun_definition(name_with_maybe_params, type)

    quote generated: true, location: :keep do
      case unquote(kind) do
        :opaque ->
          @typedoc unquote(new_typedoc)
          @opaque unquote(name_with_maybe_params) :: unquote(clean_typedef)

        :type ->
          @typedoc unquote(new_typedoc)
          @type unquote(name_with_maybe_params) :: unquote(clean_typedef)

        :typep ->
          @typep unquote(name_with_maybe_params) :: unquote(clean_typedef)
      end

      unquote(res)
      Module.put_attribute(__MODULE__, TypeCheck.TypeDefs, unquote(Macro.escape(res)))
    end
  end

  defp append_typedoc(caller, extra_doc) do
    {_line, old_doc} = Module.get_attribute(caller.module, :typedoc) || {0, ""}
    newdoc = old_doc <> extra_doc
    Module.delete_attribute(caller.module, :typedoc)
    newdoc
  end

  defp type_definition_doc(name_with_maybe_params, type_ast, kind, caller) do
    head = Macro.to_string(name_with_maybe_params)

    if kind == :opaque do
      """
      `head` _(opaque type)_
      """
    else
      type_ast =
        Macro.prewalk(type_ast, fn
          lazy_ast = {:lazy, _, _} -> lazy_ast
          ast -> Macro.expand(ast, caller)
        end)

      """
      ```
      #{head} :: #{Macro.to_string(type_ast)}
      ```
      """
    end
  end

  defp type_fun_definition(name_with_params, type) do
    {_name, params} = Macro.decompose_call(name_with_params)

    params_check_code =
      params
      |> Enum.map(fn param ->
      quote generated: true, location: :keep do
          TypeCheck.Type.ensure_type!(unquote(param))
        end
      end)

    quote generated: true, location: :keep do
      @doc false
      def unquote(name_with_params) do
        unquote_splicing(params_check_code)
        # import TypeCheck.Builtin
        unquote(type_expansion_loop_prevention_code(name_with_params))
        unquote(type)
      end
    end
  end

  # If a type is refered to more than 1_000_000 times
  # we're probably in a type expansion loop
  defp type_expansion_loop_prevention_code(name_with_params) do
    key = {Macro.escape(name_with_params), :expansion_tracker}

    quote generated: true, location: :keep do
      expansion_tracker = Process.get({__MODULE__, unquote(key)}, 0)

      if expansion_tracker > 1_000_000 do
        IO.warn("""
        Potentially infinite type expansion loop detected while expanding `#{
          unquote(Macro.to_string(name_with_params))
        }`.
        You probably want to use `TypeCheck.Builtin.lazy` to defer type expansion to runtime.
        """)
      else
        Process.put({__MODULE__, unquote(key)}, expansion_tracker + 1)
      end
    end
  end

  @doc false
  def define_spec({:"::", _meta, [name_with_params_ast, return_type_ast]}, caller) do
    {name, params_ast} = Macro.decompose_call(name_with_params_ast)
    arity = length(params_ast)
    # return_type_ast = TypeCheck.Internals.PreExpander.rewrite(return_type_ast, caller)

    # require TypeCheck.Type
    # param_types = Enum.map(params_ast, &TypeCheck.Type.build_unescaped(&1, caller))
    # return_type = TypeCheck.Type.build_unescaped(return_type_ast, caller)

    clean_params = Macro.generate_arguments(arity, caller.module)

    quote generated: true, location: :keep do
      Module.put_attribute(
        __MODULE__,
        TypeCheck.Specs,
        {unquote(name), unquote(caller.line), unquote(arity), unquote(Macro.escape(clean_params)),
         unquote(Macro.escape(params_ast)), unquote(Macro.escape(return_type_ast))}
      )
    end
  end

  import Kernel, except: [@: 1]
  defmacro @ast do
    case ast do
      {name, _, expr} when name in ~w[type! typep! opaque! spec!]a ->
        quote generated: true, location: :keep do
          TypeCheck.Macros.unquote(name)(unquote_splicing(expr))
        end
      _ ->
        quote generated: true, location: :keep do
          Kernel.@(unquote(ast))
        end
      end
  end
end
