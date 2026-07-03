defmodule HabitTracker.CLI do
  @moduledoc """
  The command-line interface.

  This is plain argument-parsing and printing — it delegates every bit of
  behaviour to `HabitTracker.Tracker` / `HabitTracker.Stats`, which is where the
  interesting (and mutated) logic lives. `.mutare.exs` excludes this file from
  mutation for that reason.
  """
  alias HabitTracker.{Habit, Repo, Search, Stats, Tracker}

  @doc "Entry point. Parses `argv` and runs the matching command."
  def main(argv) do
    case argv do
      ["add", name | rest] -> add(name, rest)
      ["list" | rest] -> list(rest)
      ["check", name | rest] -> check(name, rest)
      ["set", name | rest] -> set(name, rest)
      ["streak", name] -> streak(name)
      ["stats" | _] -> stats()
      ["progress" | rest] -> progress(rest)
      ["active" | rest] -> active(rest)
      ["history" | rest] -> history(rest)
      ["rm", name] -> remove(name)
      _ -> usage()
    end
  end

  defp add(name, rest) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [cadence: :string, target: :integer]
      )

    attrs = %{
      name: name,
      cadence: opts[:cadence] || "daily",
      target: opts[:target] || 1
    }

    case Tracker.create_habit(attrs) do
      {:ok, habit} ->
        puts("added habit ##{habit.id}: #{habit.name} (#{habit.cadence}, target #{habit.target})")

      {:error, changeset} ->
        puts("could not add habit:")
        for {field, msg} <- errors(changeset), do: puts("  #{field} #{msg}")
    end
  end

  defp list(rest) do
    {opts, _} = OptionParser.parse!(rest, strict: [all: :boolean, cadence: :keep])
    archived = opts[:all] || false

    with {:ok, cadences} <- parse_cadences(Keyword.get_values(opts, :cadence)) do
      habits =
        case cadences do
          [] -> Tracker.list_habits(archived: archived)
          _ -> Tracker.by_cadence(cadences, archived: archived)
        end

      if habits == [] do
        puts("no habits yet — add one with: habit add NAME")
      else
        for %Habit{} = habit <- habits do
          streak = Tracker.current_streak(habit)
          flag = if habit.archived, do: " [archived]", else: ""
          puts("#{pad(habit.name)} streak #{streak}  target #{habit.target}#{flag}")
        end
      end
    else
      {:error, reason} -> puts(reason)
    end
  end

  defp parse_cadences(raws) do
    Enum.reduce_while(raws, {:ok, []}, fn
      "daily", {:ok, acc} -> {:cont, {:ok, acc ++ [:daily]}}
      "weekly", {:ok, acc} -> {:cont, {:ok, acc ++ [:weekly]}}
      other, _ -> {:halt, {:error, "bad cadence (use daily|weekly): #{other}"}}
    end)
  end

  defp check(name, rest) do
    {opts, _} = OptionParser.parse!(rest, strict: [date: :string, count: :integer])

    with {:ok, habit} <- fetch(name),
         {:ok, date} <- parse_date(opts[:date]) do
      {:ok, check_in} = Tracker.check_in(habit, date, opts[:count] || 1)
      puts("checked in #{habit.name} on #{check_in.date} (count #{check_in.count})")
    else
      {:error, reason} -> puts(reason)
    end
  end

  defp set(name, rest) do
    {opts, _} = OptionParser.parse!(rest, strict: [target: :integer, cadence: :string])
    attrs = opts |> Keyword.take([:target, :cadence]) |> Map.new()

    with {:ok, habit} <- fetch(name),
         {:ok, updated} <- Tracker.update_habit(habit, attrs) do
      puts("updated #{updated.name} (#{updated.cadence}, target #{updated.target})")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        puts("could not update #{name}:")
        for {field, msg} <- errors(changeset), do: puts("  #{field} #{msg}")

      {:error, reason} when is_binary(reason) ->
        puts(reason)
    end
  end

  defp streak(name) do
    case fetch(name) do
      {:ok, habit} -> puts("#{habit.name}: #{Tracker.current_streak(habit)} day streak")
      {:error, reason} -> puts(reason)
    end
  end

  defp stats do
    case Stats.leaderboard() do
      [] ->
        puts("no check-ins yet")

      rows ->
        puts("most active habits:")
        for row <- rows, do: puts("  #{pad(row.name)} #{row.total} over #{row.days} day(s)")
    end
  end

  defp progress(rest) do
    {opts, _} = OptionParser.parse!(rest, strict: [since: :string, until: :string])
    today = Date.utc_today()

    default_since = today |> Date.add(-6) |> Date.to_iso8601()
    since_raw = opts[:since] || default_since
    through_raw = opts[:until] || Date.to_iso8601(today)

    with {:ok, since} <- parse_date(since_raw),
         {:ok, through} <- parse_date(through_raw) do
      case Stats.progress_report(since, through) do
        [] ->
          puts("no active habits")

        rows ->
          puts("progress from #{since} through #{through}:")

          for row <- rows do
            delta = if row.delta >= 0, do: "+#{row.delta}", else: to_string(row.delta)
            puts("  #{pad(row.name)} #{row.total}/#{row.target} (#{delta})")
          end
      end
    else
      {:error, reason} -> puts(reason)
    end
  end

  defp active(rest) do
    {opts, _} = OptionParser.parse!(rest, strict: [since: :string])

    case parse_date(opts[:since] || to_string(Date.add(Date.utc_today(), -7))) do
      {:ok, date} ->
        case Stats.active_since(date) do
          [] -> puts("no habits active since #{date}")
          names -> for name <- names, do: puts(name)
        end

      {:error, reason} ->
        puts(reason)
    end
  end

  defp history(rest) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [
          habit: :string,
          cadence: :string,
          since: :string,
          until: :string,
          min_count: :integer,
          limit: :integer
        ]
      )

    case history_filters(opts) do
      {:ok, filters} ->
        checks = filters |> Search.check_ins() |> Repo.preload(:habit)

        if checks == [] do
          puts("no matching check-ins")
        else
          for c <- checks, do: puts("#{c.date}  #{pad(c.habit.name)} x#{c.count}")
        end

      {:error, reason} ->
        puts(reason)
    end
  end

  # Turn the parsed CLI options into `Search` filters, validating the date and
  # cadence values (the rest pass straight through).
  defp history_filters(opts) do
    Enum.reduce_while(opts, {:ok, []}, fn opt, {:ok, acc} ->
      case history_filter(opt) do
        {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp history_filter({:cadence, "daily"}), do: {:ok, {:cadence, :daily}}
  defp history_filter({:cadence, "weekly"}), do: {:ok, {:cadence, :weekly}}
  defp history_filter({:cadence, other}), do: {:error, "bad cadence (use daily|weekly): #{other}"}

  defp history_filter({key, raw}) when key in [:since, :until] do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, {key, date}}
      {:error, _} -> {:error, "bad date (use YYYY-MM-DD): #{raw}"}
    end
  end

  defp history_filter(filter), do: {:ok, filter}

  defp remove(name) do
    case fetch(name) do
      {:ok, habit} ->
        {:ok, _} = Tracker.delete_habit(habit)
        puts("removed #{habit.name}")

      {:error, reason} ->
        puts(reason)
    end
  end

  defp usage do
    puts("""
    habit — a tiny habit tracker

      habit add NAME [--cadence daily|weekly] [--target N]
      habit list [--all] [--cadence daily|weekly]
      habit check NAME [--date YYYY-MM-DD] [--count N]
      habit set NAME [--target N] [--cadence daily|weekly]
      habit streak NAME
      habit stats
      habit progress [--since DATE] [--until DATE]
      habit active [--since DATE]
      habit history [--habit NAME] [--cadence daily|weekly] [--since DATE] [--until DATE] [--min-count N] [--limit N]
      habit rm NAME
    """)
  end

  # --- helpers ---------------------------------------------------------------

  defp fetch(name) do
    case Tracker.get_habit(name) do
      nil -> {:error, "no such habit: #{name}"}
      habit -> {:ok, habit}
    end
  end

  defp parse_date(nil), do: {:ok, Date.utc_today()}

  defp parse_date(string) do
    case Date.from_iso8601(string) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "bad date (use YYYY-MM-DD): #{string}"}
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &{field, &1}) end)
  end

  defp pad(name), do: String.pad_trailing(name, 20)

  # Indirection so the suite can run commands without spraying stdout; the real
  # CLI just prints.
  defp puts(text), do: IO.puts(text)

  @doc false
  # Used by the bin/habit wrapper to be sure the database is migrated before a
  # command runs even if the app wasn't started the usual way.
  def ensure_started! do
    {:ok, _} = Application.ensure_all_started(:habit_tracker)
    Repo
  end
end
