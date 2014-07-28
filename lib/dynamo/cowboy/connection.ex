defmodule Dynamo.Cowboy.Connection do
  @moduledoc false

  use Dynamo.Connection.Behaviour, [:req, :scheme]
  require :cowboy_req, as: R

  @doc """
  Returns the underlying cowboy request. This is used
  internally by Dynamo but may also be used by other
  developers (with caution).
  """
  def cowboy_request(connection(req: req)) do
    req
  end

  @doc """
  Sets the underlying cowboy request.
  """
  def cowboy_request(req, conn) do
    connection(conn, req: req)
  end

  @doc false
  def new(main, req, scheme) do
    { verb, req } = R.method req
    { path, _ }   = R.path req

    segments = split_path(path)

    connection(
      main: main,
      before_send: Dynamo.Connection.default_before_send,
      method: verb,
      path_info_segments: segments,
      req: req,
      scheme: scheme
    )
  end

  ## Request API

  @doc false
  def peer(connection(req: req)) do
    {{peer,_}, _}  = R.peer req
    peer
  end

  @doc false
  def original_method(connection(req: req)) do
    { method, _ } = R.method req
    method
  end

  @doc false
  def query_string(connection(req: req)) do
    { query_string, _ } = R.qs req
    query_string
  end

  @doc false
  def path_segments(connection(req: req)) do
    { path, _ } = R.path req
    split_path path
  end

  @doc false
  def path(connection(req: req)) do
    { binary, _ } = R.path req
    binary
  end

  @doc false
  def version(connection(req: req)) do
    { version, _ } = R.version req
    version
  end

  @doc false
  def host(connection(req: req)) do
    case R.header("x-forwarded-host", req) do 
      { :undefined, _ } -> 
        { host, _ } = R.host req
        host
      { fhost, _ } ->
        [h | _] = String.split(fhost, ", ?", parts: 2)
        h
    end
  end

  @doc false
  def port(connection(req: req)) do
    case R.header("x-forwarded-port", req) do 
      { :undefined, _ } -> 
        { port, _ } = R.port req
        if is_integer(port) do 
          port 
        else
          port |> to_string |> String.to_integer
        end
      { fport, _ } -> 
        [p | _] = String.split(fport, ", ?", parts: 2)
        String.to_integer(p)
    end
  end

  @doc false
  def host_url(conn) do
    host = __MODULE__.host(conn)
    proto = __MODULE__.scheme(conn)
    port = __MODULE__.port(conn)

    uport = case {proto, port} do 
              {_, :undefined} -> ""
              {"http", 80} -> ""
              {"https", 443} -> ""
              _ -> ":#{port}"
            end

    "#{proto}://#{host}#{uport}"
  end

  @doc false
  def scheme(connection(scheme: scheme, req: req)) do
    case R.header("x-forwarded-proto", req) do 
      { :undefined, _ } -> 
        scheme
      { fsch, _ } ->
        [s | _] = String.split(fsch, ", ?", parts: 2)
        s
    end
  end

  ## Response API

  def already_sent?(_conn) do
    receive do
      { :cowboy_req, :resp_sent } = flag ->
        send self, flag
        true
    after
      0 ->
        false
    end
  end

  @doc false
  def send(status, body, connection(state: state) = conn) when state in [:unset, :set] and is_binary(body) do
    conn = run_before_send(connection(conn, status: status, resp_body: body, state: :set))
    connection(req: req, status: status, resp_body: body,
               resp_headers: headers, resp_cookies: cookies) = conn

    merged_resp_headers = Dynamo.Connection.Utils.merge_resp_headers(headers, cookies)
    { :ok, req } = R.reply(status, merged_resp_headers, body, req)

    connection(conn,
      req: req,
      resp_body: nil,
      state: :sent
    )
  end

  @doc false
  def send_chunked(status, connection(state: state) = conn)
      when is_integer(status) and state in [:unset, :set] do
    conn = run_before_send(connection(conn, status: status, state: :chunked))
    connection(status: status, req: req,
               resp_headers: headers, resp_cookies: cookies) = conn
    merged_resp_headers = Dynamo.Connection.Utils.merge_resp_headers(headers, cookies)

    { :ok, req } = R.chunked_reply(status, merged_resp_headers, req)

    connection(conn,
      req: req,
      resp_body: nil)
  end

  @doc false
  def chunk(body, connection(state: state, req: req) = conn) when state == :chunked do
    case R.chunk(body, req) do
      :ok   -> { :ok, conn }
      other -> other
    end
  end

  @doc false
  def sendfile(status, path, conn) do
    %File.Stat{type: :regular, size: size} = File.stat!(path)
    body_fun = fn (socket, transport) ->
                    case transport.sendfile(socket, path) do
                      {:ok, _sent} ->
                        :ok
                      {:error, :closed} ->
                        :ok
                      {:error, :etimedout} ->
                        :ok
                    end
               end

    conn = run_before_send(connection(conn, status: status, state: :sendfile))
    connection(req: req, status: status,
               resp_headers: headers, resp_cookies: cookies) = conn

    merged_resp_headers = Dynamo.Connection.Utils.merge_resp_headers(headers, cookies)
    req = R.set_resp_body_fun(size, body_fun, req)
    { :ok, req } = R.reply(status, merged_resp_headers, req)

    connection(conn,
      req: req,
      resp_body: nil,
      state: :sent
    )
  end

  ## Misc

  @doc false
  def fetch(list, conn) when is_list(list) do
    Enum.reduce list, conn, fn(item, acc) -> acc.fetch(item) end
  end

  def fetch(:body, connection(req: req, req_body: nil) = conn) do
    { :ok, body, req } = R.body req
    connection(conn, req: req, req_body: body)
  end

  def fetch(:params, connection(req: req, params: nil, route_params: route_params) = conn) do
    { query_string, req } = R.qs req
    params = Dynamo.Connection.QueryParser.parse(query_string)
    { params, req } = Dynamo.Cowboy.BodyParser.parse(params, req)
    connection(conn, req: req, params: merge_route_params(params, route_params))
  end

  def fetch(:cookies, connection(req: req, req_cookies: nil) = conn) do
    { cookies, req } = R.cookies req
    connection(conn, req: req, req_cookies: Binary.Dict.new(cookies))
  end

  def fetch(:headers, connection(req: req, req_headers: nil) = conn) do
    { headers, req } = R.headers req
    connection(conn, req: req, req_headers: Binary.Dict.new(headers))
  end

  # The given aspect was already loaded.
  def fetch(aspect, conn) when aspect in [:params, :cookies, :headers, :body] do
    conn
  end

  def fetch(aspect, connection(fetchable: fetchable) = conn) when is_atom(aspect) do
    case Keyword.get(fetchable, aspect) do
      nil -> raise Dynamo.Connection.UnknownFetchError, aspect: aspect
      fun -> fun.(conn)
    end
  end

  ## Helpers

  defp merge_route_params(params, []), do: params
  defp merge_route_params(params, route_params), do: Binary.Dict.merge(params, route_params)

  defp split_path(path) do
    case :binary.split(path, "/", [:global, :trim]) do
      [""|segments] -> segments
      segments -> segments
    end
  end

end

defimpl Inspect, for: Dynamo.Cowboy.Connection do
  def inspect(conn, _) do
    "#Dynamo.Connection<#{conn.method} #{conn.path} (cowboy)>"
  end
end
