defmodule Mix.Tasks.Uv.Install do
  @moduledoc """
  Installs uv under `_build`.

  ```bash
  $ mix uv.install
  $ mix uv.install --if-missing
  ```

  By default, it installs #{Uv.latest_version()} but you
  can configure it in your config files, such as:

      config :uv, :version, "#{Uv.latest_version()}"

  ## Options

      * `--if-missing` - install only if the given version
        does not exist
  """

  @shortdoc "Installs uv under _build"
  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(args) do
    valid_options = [runtime_config: :boolean, if_missing: :boolean]

    case OptionParser.parse_head!(args, strict: valid_options) do
      {opts, []} ->
        if opts[:if_missing] && latest_version?() do
          :ok
        else
          Uv.install()
        end

      {_, _} ->
        Mix.raise("""
        Invalid arguments to uv.install, expected one of:

            mix uv.install
            mix uv.install --if-missing
        """)
    end
  end

  defp latest_version?() do
    version = Uv.configured_version()
    match?({:ok, ^version}, Uv.bin_version())
  end
end
