defmodule Bugsnag.Logger do
  require Bugsnag
  require Logger

  @behaviour :gen_event

  def init([]), do: {:ok, []}

  def handle_call({:configure, new_keys}, _state) do
    {:ok, :ok, new_keys}
  end

  def handle_event({_level, gl, _event}, state)
      when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({:error, _gl, {_pid, format, data}}, state) do
    try do
      case handle_error_format(format, data) do
        {exception, stacktrace, metadata} ->
          Bugsnag.report(exception, stacktrace: stacktrace, metadata: metadata)

        _ ->
          :ok
      end
    rescue
      ex ->
        error_message = Exception.format(:error, ex)
        Logger.warn("Unable to notify Bugsnag. #{error_message}")
    end

    {:ok, state}
  end

  def handle_event({_level, _gl, _event}, state) do
    {:ok, state}
  end

  def handle_event(:error, {_pid, format, data}) do
    handle_error_format(format, data)
  end

  # Errors in a GenServer.
  defp handle_error_format('** Generic server ' ++ _, [name, last_message, state, reason]) do
    {class, message, stacktrace} = format_as_exception(reason, "GenServer terminating")

    {
      %Bugsnag.Exception{
        error_class: class,
        message: message
      },
      stacktrace,
      %{
        "name" => inspect(name),
        "last_message" => inspect(last_message),
        "state" => inspect(state)
      }
    }
  end

  # Errors in a GenEvent handler.
  defp handle_error_format('** gen_event handler ' ++ _, [
         name,
         manager,
         last_message,
         state,
         reason
       ]) do
    {class, message, stacktrace} = format_as_exception(reason, "gen_event handler terminating")

    {
      %Bugsnag.Exception{
        error_class: class,
        message: message
      },
      stacktrace,
      %{
        "name" => inspect(name),
        "manager" => inspect(manager),
        "last_message" => inspect(last_message),
        "state" => inspect(state)
      }
    }
  end

  # Errors in a task.
  defp handle_error_format('** Task ' ++ _, [name, starter, function, arguments, reason]) do
    {class, message, stacktrace} = format_as_exception(reason, "Task terminating")

    {
      %Bugsnag.Exception{
        error_class: class,
        message: message
      },
      stacktrace,
      %{
        "name" => inspect(name),
        "started_from" => inspect(starter),
        "function" => inspect(function),
        "arguments" => inspect(arguments)
      }
    }
  end

  defp handle_error_format('** State machine ' ++ _ = message, data) do
    if charlist_contains?(message, 'Callback mode') do
      :ok
    else
      handle_gen_fsm_error(data)
    end
  end

  # Errors in a regular process.
  defp handle_error_format('Error in process ' ++ _, [pid, {reason, stacktrace}]) do
    exception = Exception.normalize(:error, reason)

    {
      %Bugsnag.Exception{
        error_class: "error in process (#{inspect(exception.__struct__)})",
        message: Exception.message(exception)
      },
      stacktrace,
      %{
        "pid" => inspect(pid)
      }
    }
  end

  # Any other error (for example, the ones logged through
  # :error_logger.error_msg/1). This reporter doesn't report those to Rollbar.
  defp handle_error_format(_format, _data) do
    :ok
  end

  defp handle_gen_fsm_error([name, last_event, state, data, reason]) do
    {class, message, stacktrace} = format_as_exception(reason, "State machine terminating")

    {
      %Bugsnag.Exception{
        error_class: class,
        message: message
      },
      stacktrace,
      %{
        "name" => inspect(name),
        "last_event" => inspect(last_event),
        "state" => inspect(state),
        "data" => inspect(data)
      }
    }
  end

  defp handle_gen_fsm_error(_data) do
    :next
  end

  defp format_as_exception({maybe_exception, [_ | _] = maybe_stacktrace} = reason, class) do
    # We do this &Exception.format_stacktrace_entry/1 dance just to ensure that
    # "maybe_stacktrace" is a valid stacktrace. If it's not,
    # Exception.format_stacktrace_entry/1 will raise an error and we'll treat it
    # as not a stacktrace.
    try do
      Enum.each(maybe_stacktrace, &Exception.format_stacktrace_entry/1)
    catch
      :error, _ ->
        format_stop_as_exception(reason, class)
    else
      :ok ->
        format_error_as_exception(maybe_exception, maybe_stacktrace, class)
    end
  end

  defp format_as_exception(reason, class) do
    format_stop_as_exception(reason, class)
  end

  defp format_stop_as_exception(reason, class) do
    {class <> " (stop)", Exception.format_exit(reason), _stacktrace = []}
  end

  defp format_error_as_exception(reason, stacktrace, class) do
    case Exception.normalize(:error, reason, stacktrace) do
      %ErlangError{} ->
        {class, Exception.format_exit(reason), stacktrace}

      exception ->
        class = class <> " (" <> inspect(exception.__struct__) <> ")"
        {class, Exception.message(exception), stacktrace}
    end
  end

  defp charlist_contains?(charlist, part) do
    :string.str(charlist, part) != 0
  end
end
