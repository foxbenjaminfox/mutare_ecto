defmodule Mutare.Ecto.Island.PolicyTest do
  use ExUnit.Case, async: true

  alias Mutare.Ecto.Island.Policy
  alias Mutare.Mutator.Spec

  @core %Spec{module: Mutare.Mutators.AtomLiteral, name: :atom}

  test "value interiors hold no structure" do
    assert allows?(:value, "[active: :score]", "[]")
    assert allows?(:value, ":score", ":mutare")
  end

  test "condition keys are held while their values remain mutable" do
    refute allows?(:condition, "[active: true]", "[mutare: true]")
    refute allows?(:condition, "[active: true]", "[]")
    assert allows?(:condition, "[active: true]", "[active: false]")
  end

  test "condition protection over-approximates incidental option keys" do
    refute allows?(:condition, "lookup(n, scope: :all)", "lookup(n, mutare: :all)")
    refute allows?(:condition, "lookup(n, scope: :all)", "lookup(n, [])")
    assert allows?(:value, "lookup(n, scope: :all)", "lookup(n, [])")
  end

  test "condition sets ignore multiplicity and which branch retains a key" do
    assert allows?(:condition, "[active: true, active: false]", "[active: false]")

    assert allows?(
             :condition,
             "if flag, do: [active: true], else: [active: false]",
             "if flag, do: [], else: [active: false]"
           )
  end

  for {form, original, mutated} <- [
        {:atom, ":score", ":mutare"},
        {:string, ~s|"score"|, ~s|"mutare"|},
        {:alias, "MyApp.Post", "MyApp.User"},
        {:list, "[:score, :views]", "[:score]"},
        {:pair, "{:array, :string}", "{:array, :integer}"},
        {:tuple, "{:array, :string, :score}", "{:array, :integer, :score}"},
        {:block, "(setup(:unused); :score)", "(setup(:unused); :mutare)"},
        {:or, "name || :score", "name || :mutare"},
        {:if, "if flag, do: :score, else: :views", "if flag, do: :mutare, else: :views"},
        {:unless, "unless flag, do: :score", "unless flag, do: :mutare"},
        {:case, "case name do :a -> :score; _ -> :views end",
         "case name do :a -> :mutare; _ -> :views end"},
        {:cond, "cond do flag -> :score; true -> :views end",
         "cond do flag -> :mutare; true -> :views end"}
      ] do
    test "structural results hold literals in #{form}" do
      refute allows?(:structural, unquote(original), unquote(mutated))
    end
  end

  test "structural protection leaves conditions, patterns and intermediate values mutable" do
    for {original, mutated} <- [
          {"if flag, do: :score, else: :views", "if !flag, do: :score, else: :views"},
          {"case name do :a -> :score end", "case name do :b -> :score end"},
          {"cond do name == :a -> :score end", "cond do name == :b -> :score end"},
          {"(:unused; :score)", "(:changed; :score)"}
        ] do
      assert allows?(:structural, original, mutated)
    end
  end

  test "structural protection under-approximates names returned through calls" do
    assert allows?(
             :structural,
             "Keyword.get(opts, :sort, :score)",
             "Keyword.get(opts, :sort, :mutare)"
           )
  end

  test "structural sets ignore multiplicity and location" do
    assert allows?(:structural, "[:score, :score]", "[:score]")

    assert allows?(
             :structural,
             "if flag, do: :score, else: :views",
             "if flag, do: :views, else: :score"
           )

    assert allows?(
             :structural,
             "if flag, do: :score, else: :score",
             "if flag, do: lookup(), else: :score"
           )
  end

  test "metadata does not change the held literals" do
    for {role, source} <- [condition: "[active: true]", structural: "MyApp.Post"] do
      original = Sourceror.parse_string!(source)
      moved = Sourceror.parse_string!("\n\n" <> source)
      assert Policy.allows?(@core, role, original, moved)
    end
  end

  test "only the Ecto producer is exempt, including when renamed" do
    original = Sourceror.parse_string!("from(p in Post, where: p.active)")
    mutated = Sourceror.parse_string!("from(p in Post)")

    for name <- [:ecto, :renamed] do
      producer = %Spec{module: Mutare.Ecto, name: name}
      assert Policy.allows?(producer, :condition, original, mutated)
      assert allows?(:structural, ":score", ":mutare", producer)
    end

    for producer <- [@core, %Spec{module: ThirdParty, name: :ecto}] do
      refute Policy.allows?(producer, :condition, original, mutated)
      refute allows?(:structural, ":score", ":mutare", producer)
    end
  end

  defp allows?(role, original, mutated, producer \\ @core) do
    Policy.allows?(
      producer,
      role,
      Sourceror.parse_string!(original),
      Sourceror.parse_string!(mutated)
    )
  end
end
