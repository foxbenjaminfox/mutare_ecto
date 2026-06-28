[
  # Just the Ecto surface, so a first run is small and focused. Listing only the
  # plugin (no `:all`) replaces Mutare's built-in mutators with it — add `:all`
  # back to also mutate the ordinary Elixir in `greet/1`.
  mutators: [
    {Mutare.Ecto, repo: Hello.Repo}
  ]
]
