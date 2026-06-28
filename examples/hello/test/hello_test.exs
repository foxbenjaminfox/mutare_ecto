defmodule HelloTest do
  use Hello.DataCase

  # `greetings_in/1` is pinned down: the fixtures put a French greeting alongside
  # the English ones and assert the exact, ordered result. That kills the
  # comparison swap (`==` → `!=` would return the French row and drop the English
  # ones) and the sort direction (`:asc` → `:desc` would reverse the names).
  describe "greetings_in/1" do
    setup do
      {:ok, _} = Hello.add_greeting(%{name: "Zara", language: "en"})
      {:ok, _} = Hello.add_greeting(%{name: "Ada", language: "en"})
      {:ok, _} = Hello.add_greeting(%{name: "Margot", language: "fr"})
      :ok
    end

    test "returns only the chosen language, sorted by name" do
      names = Hello.greetings_in("en") |> Enum.map(& &1.name)
      assert names == ["Ada", "Zara"]
    end
  end

  # `recent_greetings/1` is only *loosely* tested — we check that it comes back
  # non-empty, but never assert the order or that the limit bites. So Mutare's
  # ordering (`:desc` → `:asc`), limit (`5` → `4`/`6`), and limit-drop mutants all
  # survive: nothing here would notice.
  describe "recent_greetings/1" do
    test "returns the greetings" do
      {:ok, _} = Hello.add_greeting(%{name: "Bo", language: "en"})
      {:ok, _} = Hello.add_greeting(%{name: "Cy", language: "en"})

      assert length(Hello.recent_greetings()) == 2
    end
  end

  # The changeset is tested for the *presence* of a name but not its *length*, so
  # dropping `validate_required` is caught while dropping `validate_length`
  # survives — no test ever submits a one-character name.
  describe "add_greeting/1 validation" do
    test "requires a name" do
      assert {:error, changeset} = Hello.add_greeting(%{language: "en"})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
