defmodule Mutare.Ecto.OrderingTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Ordering

  # Unit tests for the shared ordering-flip catalog — `Ordering.flips/1` over a parsed `order_by`
  # value, rendered back as `{family, source}`. Delivery (whole-`from` via QueryTest, standalone via
  # ClauseTest) is tested there; here we pin which single-axis flips it offers and which list shapes
  # it accepts.

  defp flips(code) do
    code
    |> Sourceror.parse_string!()
    |> Ordering.flips()
    |> Enum.map(fn {family, node, _label} -> {family, Sourceror.to_string(node)} end)
  end

  # The `{family, rendered, finer_label}` triples, for asserting the per-axis label.
  defp labelled_flips(code) do
    code
    |> Sourceror.parse_string!()
    |> Ordering.flips()
    |> Enum.map(fn {family, node, label} -> {family, Sourceror.to_string(node), label} end)
  end

  test "a bare direction flips only its direction (no nulls placement declared)" do
    assert flips("[asc: u.name]") == [{:ordering, "[desc: u.name]"}]
    assert flips("[desc: u.name]") == [{:ordering, "[asc: u.name]"}]
  end

  test "each axis is labelled by the value it mutates (direction / placement)" do
    # The direction flip is labelled `asc`/`desc`; the nulls-placement flip `nulls_first`/
    # `nulls_last` — so `[ecto:asc]` and `[ecto:nulls_first]` each target one axis.
    assert labelled_flips("[asc: u.name]") == [{:ordering, "[desc: u.name]", "asc"}]

    assert labelled_flips("[asc_nulls_first: u.score]") == [
             {:ordering, "[desc_nulls_first: u.score]", "asc"},
             {:ordering_nulls, "[asc_nulls_last: u.score]", "nulls_first"}
           ]
  end

  test "a bare field (implicit ascending) re-tags its implicit asc to desc" do
    # `order_by: [p.id, asc: p.name]` — the bare `p.id` is `asc` by definition, so it re-tags to
    # `desc: p.id` (a non-trailing keyword pair renders as an explicit `{:desc, …}` tuple); the
    # keyed `asc: p.name` flips independently. One `:ordering` mutant per field.
    assert flips("[p.id, asc: p.name]") == [
             {:ordering, "[desc: p.id, asc: p.name]"},
             {:ordering, "[p.id, desc: p.name]"}
           ]
  end

  test "a bare single field re-tags to an explicit descending keyword list" do
    assert flips(":name") == [{:ordering, "[desc: :name]"}]
    assert flips("u.name") == [{:ordering, "[desc: u.name]"}]
    assert flips("as(:post).name") == [{:ordering, "[desc: as(:post).name]"}]
    assert flips("parent_as(:post).name") == [{:ordering, "[desc: parent_as(:post).name]"}]
  end

  test "a bare list of fields re-tags each field independently" do
    assert flips("[u.name, u.age]") == [
             {:ordering, "[{:desc, u.name}, u.age]"},
             {:ordering, "[u.name, desc: u.age]"}
           ]
  end

  test "the implicit-direction flip is labelled asc (matching an explicit asc flip)" do
    assert labelled_flips("u.name") == [{:ordering, "[desc: u.name]", "asc"}]
  end

  test "a term that isn't a plain field is left untouched (pin, fragment, computed expression)" do
    # A `^`-pinned runtime ordering is already a full ordering spec, and a fragment/computed value
    # is a value not a direction — re-tagging either would be wrong, so neither is a flippable axis.
    assert flips("^order") == []
    assert flips(~s|fragment("lower(?)", u.name)|) == []
    assert flips("u.a + u.b") == []
  end

  test "opaque module-qualified calls are not re-tagged as implicit field orderings" do
    # A helper macro/function can expand to a complete runtime ordering spec; wrapping that call as
    # `desc: Helper.order(...)` produces an invalid Ecto order expression.
    assert flips("Helper.order(:name)") == []
    assert flips("Helper.order()") == []
    assert flips("Helper.order") == []
  end
end
