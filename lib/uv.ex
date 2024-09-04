defmodule Uv do
  # https://github.com/astral-sh/uv/releases
  @latest_version "0.4.2"

  @moduledoc """
  Uv is an installer and runner for [`uv`](https://docs.astral.sh/uv/).

  ## Profiles

  You can define multiple uv profiles. These correspond to uv projects.
  By default, there is a profile called `:default` for which you can 
  configure its current directory and environment:

      config :uv,
        version: "#{@latest_version}",
        default: [
          cd: Path.expand("../python_project", __DIR__),
          env: %{}
        ]

  ## Uv configuration

  There are three global configurations for the uv application:

    * `:version` - the expected uv version

    * `:cacerts_path` - the directory to find certificates for
      https connections

    * `:path` - the path to find the uv executable at. By
      default, it is automatically downloaded and placed inside
      the `_build` directory of your current app

  If you would prefer to use your system `uv`, you can store it in a
  `MIX_UV_PATH` environment variable, which you can then read in
  your configuration file:

      config :uv, path: System.get_env("MIX_UV_PATH")

  """

  use Application
  require Logger

  @doc false
  def start(_, _) do
    unless Application.get_env(:uv, :version) do
      Logger.warning("""
      uv version is not configured. Please set it in your config files:

          config :uv, :version, "#{latest_version()}"
      """)
    end

    configured_version = configured_version()

    case bin_version() do
      {:ok, ^configured_version} ->
        :ok

      {:ok, version} ->
        Logger.warning("""
        Outdated uv version. Expected #{configured_version}, got #{version}. \
        Please run `mix uv.install` or update the version in your config files.\
        """)

      :error ->
        :ok
    end

    Supervisor.start_link([], strategy: :one_for_one)
  end

  @doc false
  # Latest known version at the time of publishing.
  def latest_version, do: @latest_version

  @doc """
  Returns the configured uv version.
  """
  def configured_version do
    Application.get_env(:uv, :version, latest_version())
  end

  @doc """
  Returns the configuration for the given profile.

  Returns nil if the profile does not exist.
  """
  def config_for!(profile) when is_atom(profile) do
    Application.get_env(:uv, profile) ||
      raise ArgumentError, """
      unknown uv profile. Make sure the profile is defined in your config/config.exs file, such as:

          config :uv,
            #{profile}: [
              cd: Path.expand("../python_path", __DIR__),
              env: %{"ENV_VAR" => "value"}
            ]
      """
  end

  @doc """
  Returns the path to the executable.

  The executable may not be available if it was not yet installed.
  """
  def bin_path do
    name = "uv"

    Application.get_env(:uv, :path) ||
      if Code.ensure_loaded?(Mix.Project) do
        Path.join(Path.dirname(Mix.Project.build_path()), name)
      else
        Path.expand("_build/#{name}")
      end
  end

  @doc """
  Returns the version of the uv executable.

  Returns `{:ok, version_string}` on success or `:error` when the executable
  is not available.
  """
  def bin_version do
    path = bin_path()

    with true <- File.exists?(path),
         {result, 0} <- System.cmd(path, ["--version"]) do
      {:ok, String.trim(result)}
    else
      _ -> :error
    end
  end

  @doc """
  Runs the given command with `args`.

  The given args will be appended to the configured args.
  The task output will be streamed directly to stdio. It
  returns the status of the underlying call.
  """
  def run(profile, extra_args) when is_atom(profile) and is_list(extra_args) do
    config = config_for!(profile)
    args = (config[:args] || []) ++ extra_args

    {_, exit_status} =
      run_uv_command(args,
        cd: config[:cd] || File.cwd!(),
        env: config[:env] || %{},
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    exit_status
  end

  defp run_uv_command([], _opts) do
    raise "no arguments passed to uv"
  end

  defp run_uv_command(args, opts) do
    System.cmd(bin_path(), args, opts)
  end

  @doc """
  Installs, if not available, and then runs `uv`.

  Returns the same as `run/1`.
  """
  def install_and_run(profile, args) do
    unless File.exists?(bin_path()) do
      install()
    end

    run(profile, args)
  end

  def install do
    version = @latest_version

    tmp_dir =
      freshdir_p(Path.join(System.tmp_dir!(), "phx-ux")) ||
        raise "could not install uv. Set MIX_XGD=1 and then set XDG_CACHE_HOME to the path you want to use as cache"

    url = "https://github.com/astral-sh/uv/releases/download/#{version}/uv-#{target()}.tar.gz"

    binary = fetch_body!(url)

    download_path =
      case :erl_tar.extract({:binary, binary}, [{:cwd, tmp_dir}, :compressed]) do
        :ok ->
          Path.join([tmp_dir, "uv-#{target()}", "uv"])

        other ->
          raise "couldn't unpack archive: #{inspect(other)}"
      end

    bin_path = bin_path()
    File.mkdir_p!(Path.dirname(bin_path))

    File.cp!(download_path, bin_path)
    File.chmod(bin_path, 0o755)
  end

  defp freshdir_p(path) do
    with {:ok, _} <- File.rm_rf(path),
         :ok <- File.mkdir_p(path) do
      path
    else
      _ -> nil
    end
  end

  defp target do
    :erlang.system_info(:system_architecture)
  end

  defp fetch_body!(url) do
    scheme = URI.parse(url).scheme
    url = String.to_charlist(url)
    Logger.debug("Downloading uv from #{url}")

    Mix.ensure_application!(:inets)
    Mix.ensure_application!(:ssl)

    if proxy = proxy_for_scheme(scheme) do
      %{host: host, port: port} = URI.parse(proxy)
      Logger.debug("Using #{String.upcase(scheme)}_PROXY: #{proxy}")
      set_option = if "https" == scheme, do: :https_proxy, else: :proxy
      :httpc.set_options([{set_option, {{String.to_charlist(host), port}, []}}])
    end

    # https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/inets
    cacertfile = cacertfile() |> String.to_charlist()

    http_options =
      [
        ssl: [
          verify: :verify_peer,
          cacertfile: cacertfile,
          depth: 2,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
      |> maybe_add_proxy_auth(scheme)

    options = [body_format: :binary]

    case :httpc.request(:get, {url, []}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        body

      other ->
        raise """
        couldn't fetch #{url}: #{inspect(other)}
        """
    end
  end

  defp proxy_for_scheme("http") do
    System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
  end

  defp proxy_for_scheme("https") do
    System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")
  end

  defp maybe_add_proxy_auth(http_options, scheme) do
    case proxy_auth(scheme) do
      nil -> http_options
      auth -> [{:proxy_auth, auth} | http_options]
    end
  end

  defp proxy_auth(scheme) do
    with proxy when is_binary(proxy) <- proxy_for_scheme(scheme),
         %{userinfo: userinfo} when is_binary(userinfo) <- URI.parse(proxy),
         [username, password] <- String.split(userinfo, ":") do
      {String.to_charlist(username), String.to_charlist(password)}
    else
      _ -> nil
    end
  end

  defp cacertfile() do
    Application.get_env(:uv, :cacerts_path) || CAStore.file_path()
  end
end
