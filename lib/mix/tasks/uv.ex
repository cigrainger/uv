defmodule Mix.Tasks.Uv do
  @moduledoc """
  Invokes uv with the given args.

  Usage:

      $ mix uv TASK_OPTIONS PROFILE UV_ARGS

  Example:

      $ mix uv default add numpy

  If uv is not installed, it is automatically downloaded.
  Note the arguments given to this task will be appended
  to any configured arguments.
  """

  @shortdoc "Invokes uv with the profile and args"
  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(args) do
    switches = []
    {_opts, remaining_args} = OptionParser.parse_head!(args, switches: switches)

    Application.ensure_all_started(:uv)

    Mix.Task.reenable("uv")
    install_and_run(remaining_args)
  end

  defp install_and_run([profile | args] = all) do
    case Uv.install_and_run(String.to_atom(profile), args) do
      0 -> :ok
      status -> Mix.raise("`mix uv #{Enum.join(all, " ")}` exited with #{status}")
    end
  end

  defp install_and_run([]) do
    Mix.raise("`mix uv` expects the profile as argument")
  end
end
