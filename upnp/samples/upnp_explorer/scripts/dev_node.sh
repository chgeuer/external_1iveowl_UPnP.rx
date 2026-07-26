#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="${DEV_NODE_NAME:-$(basename "$PROJECT_DIR")}"
COOKIE="${DEV_NODE_COOKIE:-devcookie}"
HOSTNAME="$(hostname -s)"
FQDN="${APP_NAME}@${HOSTNAME}"
PIDFILE="${PROJECT_DIR}/.dev_node.pid"
LOGFILE="${DEV_NODE_LOG:-${PROJECT_DIR}/.dev_node.log}"

cd "$PROJECT_DIR"

case "${1:-help}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "Node already running (pid $(cat "$PIDFILE"))"
      exit 0
    fi

    rm -f "$PIDFILE"

    if epmd -names 2>/dev/null | grep -q "name ${APP_NAME} "; then
      echo "Node ${FQDN} is already running"
      exit 0
    fi

    PORT="${PORT:-$(phx-port)}"
    export PORT
    export ELIXIR_ERL_OPTIONS="-sname $APP_NAME -setcookie $COOKIE"

    echo "Starting node ${FQDN} on port ${PORT} ..."
    mix phx.server >"$LOGFILE" 2>&1 &
    echo $! >"$PIDFILE"

    for _attempt in $(seq 1 30); do
      if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        rm -f "$PIDFILE"
        echo "ERROR: Node exited during startup. Check ${LOGFILE}"
        exit 1
      fi

      if env -u ELIXIR_ERL_OPTIONS elixir --sname "probe_$$" --cookie "$COOKIE" --hidden -e "
        target = :\"${FQDN}\"
        connected? = Node.connect(target)
        supervisor = connected? && :rpc.call(target, Process, :whereis, [UpnpExplorer.Supervisor])
        if is_pid(supervisor), do: System.halt(0), else: System.halt(1)
      " 2>/dev/null; then
        echo "Node ${FQDN} is up (pid $(cat "$PIDFILE"))"
        exit 0
      fi
      sleep 1
    done

    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      kill "$(cat "$PIDFILE")"
    fi
    rm -f "$PIDFILE"
    echo "ERROR: Node did not become reachable within 30s. Check ${LOGFILE}"
    exit 1
    ;;

  stop)
    if epmd -names 2>/dev/null | grep -q "name ${APP_NAME} "; then
      "${SCRIPT_DIR}/dev_node.sh" rpc \
        "spawn(fn -> Process.sleep(100); System.stop() end); :ok" >/dev/null

      for _attempt in $(seq 1 50); do
        if ! epmd -names 2>/dev/null | grep -q "name ${APP_NAME} "; then
          rm -f "$PIDFILE"
          echo "Node ${FQDN} stopped"
          exit 0
        fi
        sleep 0.1
      done

      echo "ERROR: Node ${FQDN} did not stop gracefully"
      exit 1
    fi

    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      kill "$(cat "$PIDFILE")"
      echo "Node process stopped"
    else
      echo "Node ${FQDN} is not running"
    fi
    rm -f "$PIDFILE"
    ;;

  status)
    if epmd -names 2>/dev/null | grep -q "name ${APP_NAME} "; then
      echo "Node ${FQDN} is running"
      exit 0
    fi

    echo "Node ${FQDN} is not running"
    exit 1
    ;;

  await)
    TIMEOUT="${2:-30}"
    echo "Waiting for node ${FQDN} ..."

    for _attempt in $(seq 1 "$TIMEOUT"); do
      if env -u ELIXIR_ERL_OPTIONS elixir --sname "probe_$$" --cookie "$COOKIE" --hidden -e "
        target = :\"${FQDN}\"
        connected? = Node.connect(target)
        supervisor = connected? && :rpc.call(target, Process, :whereis, [UpnpExplorer.Supervisor])
        if is_pid(supervisor), do: System.stop(0), else: System.stop(1)
      " 2>/dev/null; then
        echo "Node ${FQDN} is reachable"
        exit 0
      fi
      sleep 1
    done

    echo "ERROR: Node ${FQDN} did not become reachable within ${TIMEOUT}s"
    exit 1
    ;;

  rpc)
    shift
    EXPR="$*"
    env -u ELIXIR_ERL_OPTIONS elixir --sname "rpc_$$" --cookie "$COOKIE" --hidden --no-halt -e "
      target = :\"${FQDN}\"
      if Node.connect(target) do
        case :rpc.call(target, Code, :eval_string, [\"\"\"
          ${EXPR}
        \"\"\"]) do
          {result, _binding} ->
            IO.inspect(result, pretty: true, limit: 200, printable_limit: 4096)
            System.stop(0)

          {:badrpc, reason} ->
            IO.puts(:stderr, \"RPC failed: #{inspect(reason)}\")
            System.stop(1)
        end
      else
        IO.puts(:stderr, \"Cannot connect to ${FQDN}\")
        System.stop(1)
      end
    "
    ;;

  eval_file)
    shift
    FILE="$1"
    env -u ELIXIR_ERL_OPTIONS elixir --sname "rpc_$$" --cookie "$COOKIE" --hidden --no-halt -e "
      target = :\"${FQDN}\"
      if Node.connect(target) do
        code = File.read!(\"${FILE}\")

        case :rpc.call(target, Code, :eval_string, [code]) do
          {result, _binding} ->
            IO.inspect(result, pretty: true, limit: 200, printable_limit: 4096)
            System.stop(0)

          {:badrpc, reason} ->
            IO.puts(:stderr, \"RPC failed: #{inspect(reason)}\")
            System.stop(1)
        end
      else
        IO.puts(:stderr, \"Cannot connect to ${FQDN}\")
        System.stop(1)
      end
    "
    ;;

  help | *)
    echo "Usage: scripts/dev_node.sh {start|stop|status|await [timeout]|rpc <expr>|eval_file <path>}"
    echo ""
    echo "Commands:"
    echo "  start          - Start Phoenix on a background BEAM node"
    echo "  stop           - Gracefully stop the running BEAM node"
    echo "  status         - Check if the node is registered with epmd"
    echo "  await [secs]   - Wait for the node to become reachable"
    echo "  rpc <expr>     - Execute an Elixir expression on the node"
    echo "  eval_file <f>  - Evaluate an Elixir file on the node"
    echo ""
    echo "Environment variables:"
    echo "  DEV_NODE_NAME   - Short node name (default: project directory name)"
    echo "  DEV_NODE_COOKIE - Distribution cookie (default: devcookie)"
    ;;
esac
