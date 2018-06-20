defmodule Mg.DNS.Server do
  require Logger

  use GenServer
  alias OCCI.Store
  alias Mg.DNS
  alias Mg.Utils

  alias Mg.Model.Platform

  def start_link(name, opts) do
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # Callbacks
  def init(opts) do
    s = %{
      nameservers: Keyword.get(opts, :nameservers)
    }

    Logger.debug("Start DNS")
    {:ok, s}
  end

  def handle_call({:query, from, port, data}, _from, s) do
    case DNS.Record.decode(data) do
      {:ok, q} ->
        ans = handle_msg(q, {from, port}, s)
        {:reply, {:ok, DNS.Record.encode!(ans)}, s}

      {:error, _} = e ->
        {:reply, e, s}
    end
  end

  #
  # Private
  #
  defp handle_msg(msg, from, s) do
    ans =
      msg.qdlist
      |> Enum.reduce([], fn q, acc ->
        case handle_query(q, from, s) do
          nil -> acc
          rec -> [rec | acc]
        end
      end)

    %{msg | anlist: ans}
  end

  defp handle_query(q, {host, _port} = from, s) do
    ctx =
      case Store.lookup(kind: Platform.Application, "occi.app.ip": "#{:inet.ntoa(host)}") do
        [] -> Platform.Application.new([])
        [ctx] -> ctx
      end

    handle_query_in_ctx(ctx, q, from, s)
  end

  defp handle_query_in_ctx(ctx, q, from, s) do
    case Store.lookup(kind: Platform.Proxy, "occi.app.fqdn": "#{q.domain}", source: ctx.id) do
      [] ->
        # No proxy for the requested app
        handle_query_no_ctx(q, from, s)

      [proxy] ->
        handle_query_reply(proxy, q, from, s)
    end
  end

  defp handle_query_no_ctx(q, from, s) do
    case Store.lookup(kind: Platform.Application, "occi.app.fqdn": "#{q.domain}") do
      [] ->
        # Transfer request
        handle_query_transfer(q, from, s)

      [app] ->
        handle_query_reply(app, q, from, s)
    end
  end

  defp handle_query_transfer(q, {host, _port}, s) do
    Logger.debug("QUERY from #{:inet.ntoa(host)} -> #{q.class}/#{q.domain}: TRANSFER")
    DNS.query(q, nameservers: s.nameservers)
  end

  defp handle_query_reply(res, q, {host, _port}, _s) do
    ip = res.attributes[:"occi.app.ip"]
    Logger.debug("QUERY from #{:inet.ntoa(host)} -> #{q.class}/#{q.domain}: #{ip}")

    %DNS.Resource{
      domain: q.domain,
      class: q.class,
      type: q.type,
      ttl: 300,
      data: Utils.parse_address!(ip)
    }
  end
end
