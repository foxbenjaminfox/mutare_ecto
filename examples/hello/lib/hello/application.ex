defmodule Hello.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Hello.Repo]
    Supervisor.start_link(children, strategy: :one_for_one, name: Hello.Supervisor)
  end
end
