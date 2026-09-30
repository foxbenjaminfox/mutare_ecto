defmodule Mutare.Ecto.QueryMacros do
  @moduledoc false
  # An author's query macro whose expansion carries syntax the call site does not show: a
  # fragment `splice/1`, which Ecto's dynamic path binds once per placeholder
  # (`Mutare.Ecto.StaticCondition`, "A call Ecto can only be expanding").

  defmacro member_sql(value, values) do
    quote do: fragment("? IN (?)", unquote(value), splice(unquote(values)))
  end
end
