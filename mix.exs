defmodule Jido.Chat.Mattermost.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_chat_mattermost"

  def project do
    [
      app: :jido_chat_mattermost,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Jido Chat Mattermost",
      description: "Mattermost adapter package for Jido.Chat",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
      {:req, "~> 0.5"},
      {:fresh, "~> 0.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ]
    ]
  end
end
