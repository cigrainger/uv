defmodule Uv do
  # https://github.com/astral-sh/uv/releases
  @latest_version "0.4.2"

  require Logger

  @doc """
  Returns the path to the executable.

  The executable may not be available if it was not yet installed.
  """
  def bin_path do
    name = "uv"
    Path.expand("_python/#{name}")
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
  def run(args, opts \\ []) when is_list(args) do
    opts =
      Keyword.validate!(
        opts,
        [
          :into,
          :lines,
          :arg0,
          :use_stdio,
          :parallelism,
          cd: File.cwd!(),
          env: %{},
          into: IO.stream(:stdio, :line),
          stderr_to_stdout: true
        ]
      )

    {_, exit_status} =
      System.cmd(bin_path(), args, opts)

    exit_status
  end

  @doc """
  Installs, if not available, and then runs `uv`.

  Returns the same as `run/1`.
  """
  def install_and_run(args) do
    unless File.exists?(bin_path()) do
      install()
    end

    run(args)
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
    cacertfile = CAStore.file_path() |> String.to_charlist()

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
end
