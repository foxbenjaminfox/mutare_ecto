defmodule HabitTracker.Search do
  @moduledoc """
  Build check-in queries dynamically.

  `check_ins/1` is the composable, pipe-through-the-query-macros style of
  Ecto: start from a base query and fold each filter in with `Enum.reduce`, so
  the SQL grows to fit whatever filters were actually given. The two
  habit-attribute filters (`:habit`, `:cadence`) need a join onto `habits` —
  added **once**, on demand, via `with_named_binding/3` so combining them
  doesn't join twice.

  `highlighted_check_ins/1` shows the other dynamic style: build a
  free-standing `dynamic/2` predicate one rule at a time, then splice the final
  predicate into a single `where(^predicate)`. That is a distinct mutator path
  from a normal `where` clause — the predicate is ordinary source until Ecto
  receives it, so the Ecto mutator rebuilds the whole `dynamic` call in place.

  Together, the two styles cover the query surface the Ecto mutator is built to
  exercise: drop a `where`, turn an `inner_join` into a `left_join`, flip a
  comparison inside `dynamic/2`, or swap an `or` for an `and` — each a question
  about whether a filter is really tested.
  """
  import Ecto.Query

  alias HabitTracker.{CheckIn, Repo}

  @doc """
  The check-ins matching every given filter, newest first.

  All filters are optional; an unknown one is ignored. Supported:

    * `:habit`     — only this habit's check-ins (joins `habits` by name)
    * `:cadence`   — only habits with this cadence (`:daily` / `:weekly`)
    * `:since`     — on or after this `Date`
    * `:until`     — on or before this `Date`
    * `:min_count` — a count of at least this
    * `:limit`     — cap the number of rows returned
  """
  def check_ins(filters \\ []) do
    filters
    |> Enum.reduce(base_query(), &apply_filter/2)
    |> order_by([check_in: c], desc: c.date)
    |> Repo.all()
  end

  @doc """
  Check-ins matching any highlight rule, newest and largest first.

  Supported rules:

    * `:since`     — checked in on or after this `Date`
    * `:min_count` — a count of at least this

  Unlike `check_ins/1`, this builds one free-standing `dynamic/2` predicate with
  `or` branches and applies it once. Unknown rules are ignored; if no supported
  rule is given, the starting `dynamic(false)` predicate returns no rows.
  """
  def highlighted_check_ins(rules \\ []) do
    rules
    |> Enum.reduce(dynamic(false), &highlight_predicate/2)
    |> highlighted_query()
    |> Repo.all()
  end

  defp base_query do
    from(c in CheckIn, as: :check_in)
  end

  defp highlighted_query(predicate) do
    base_query()
    |> where(^predicate)
    |> order_by([check_in: c], desc: c.date, desc: c.count)
  end

  defp highlight_predicate({:since, date}, predicate),
    do: dynamic([check_in: c], ^predicate or c.date >= ^date)

  defp highlight_predicate({:min_count, count}, predicate),
    do: dynamic([check_in: c], ^predicate or c.count >= ^count)

  defp highlight_predicate(_ignored, predicate), do: predicate

  # One clause per filter, each piping the query through a query macro and handing
  # the grown query back to the reduce. The habit-attribute filters bring the join
  # along; `join_habits/1` makes sure it's only added once.
  defp apply_filter({:habit, name}, query) do
    query
    |> join_habits()
    |> where([habit: h], h.name == ^name)
  end

  defp apply_filter({:cadence, cadence}, query) do
    query
    |> join_habits()
    |> where([habit: h], h.cadence == ^cadence)
  end

  defp apply_filter({:since, date}, query), do: where(query, [check_in: c], c.date >= ^date)
  defp apply_filter({:until, date}, query), do: where(query, [check_in: c], c.date <= ^date)

  defp apply_filter({:min_count, count}, query),
    do: where(query, [check_in: c], c.count >= ^count)

  defp apply_filter({:limit, n}, query), do: limit(query, ^n)
  defp apply_filter(_ignored, query), do: query

  # Join `habits` for the habit-attribute filters — but only once, however many of
  # them are present. `with_named_binding/3` runs the callback (adding the join)
  # only when the query doesn't already carry the `:habit` binding, so combining
  # `:habit` and `:cadence` joins a single time.
  defp join_habits(query) do
    with_named_binding(query, :habit, fn query, binding ->
      join(query, :inner, [check_in: c], h in assoc(c, :habit), as: ^binding)
    end)
  end
end
