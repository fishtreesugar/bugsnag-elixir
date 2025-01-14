defmodule Bugsnag.Payload do
  require Logger

  @notifier_info %{
    name: "Bugsnag Elixir",
    version: Bugsnag.Mixfile.project()[:version],
    url: Bugsnag.Mixfile.project()[:package][:links][:GitHub]
  }

  defstruct api_key: nil, notifier: @notifier_info, events: nil

  def new(exception, stacktrace, options) when is_map(options) do
    new(exception, stacktrace, Map.to_list(options))
  end

  def new(exception, stacktrace, options) do
    __MODULE__
    |> struct(api_key: fetch_option(options, :api_key))
    |> add_event(exception, stacktrace, options)
  end

  def encode(%__MODULE__{api_key: api_key, notifier: notifier, events: events}) do
    json_library().encode!(%{apiKey: api_key, notifier: notifier, events: events})
  end

  defp json_library, do: Application.get_env(:bugsnag, :json_library, Jason)

  defp fetch_option(options, key, default \\ nil) do
    Keyword.get(options, key, Application.get_env(:bugsnag, key, default))
  end

  defp add_event(payload, exception, stacktrace, options) do
    event =
      Map.new()
      |> add_payload_version
      |> add_exception(exception, stacktrace, options)
      |> may_add_grouping_hash(exception, stacktrace)
      |> add_severity(Keyword.get(options, :severity))
      |> add_context(Keyword.get(options, :context))
      |> add_user(Keyword.get(options, :user))
      |> add_device(
        Keyword.get(options, :os_version),
        fetch_option(options, :hostname, "unknown")
      )
      |> add_metadata(Keyword.get(options, :metadata))
      |> add_release_stage(fetch_option(options, :release_stage, "production"))
      |> add_notify_release_stages(fetch_option(options, :notify_release_stages, ["production"]))
      |> add_app_type(fetch_option(options, :app_type))
      |> add_app_version(fetch_option(options, :app_version))

    Map.put(payload, :events, [event])
  end

  defp add_exception(
         event,
         %Bugsnag.Exception{error_class: error_class, message: message},
         stacktrace,
         options
       ) do
    Map.put(event, :exceptions, [
      %{
        errorClass: error_class,
        message: sanitize(message),
        stacktrace: format_stacktrace(stacktrace, options)
      }
    ])
  end

  defp add_exception(event, exception, stacktrace, options) do
    exception = Exception.normalize(:error, exception)

    Map.put(event, :exceptions, [
      %{
        errorClass: Keyword.get(options, :error_class, exception.__struct__),
        message: sanitize(Exception.message(exception)),
        stacktrace: format_stacktrace(stacktrace, options)
      }
    ])
  end

  defp may_add_grouping_hash(event, _exception, []) do
    event
  end

  defp may_add_grouping_hash(event, exception, stacktrace) do
    grouping_key =
      [inspect(error_class(exception)) | extract_file_and_method_names(stacktrace)]
      |> List.flatten()

    grouping_hash =
      :crypto.hash(:sha, grouping_key)
      |> Base.encode16(case: :lower)

    Map.put_new(event, :groupingHash, grouping_hash)
  end

  defp error_class(%Bugsnag.Exception{error_class: error_class}), do: error_class
  defp error_class(exception), do: exception.__struct__

  defp extract_file_and_method_names(stacktrace) do
    Enum.flat_map(stacktrace, fn
      {module, fun, arity, location} when is_integer(arity) ->
        [file_name_from_location(location), Exception.format_mfa(module, fun, arity)]

      {module, fun, args, location} when is_list(args) ->
        [file_name_from_location(location), Exception.format_mfa(module, fun, length(args))]

      {fun, arity, location} when is_integer(arity) ->
        [file_name_from_location(location), Exception.format_fa(fun, arity)]

      {fun, args, location} when is_list(args) ->
        [file_name_from_location(location), Exception.format_fa(fun, length(args))]
    end)
  end

  defp file_name_from_location([]), do: "unknown"
  defp file_name_from_location(file: file, line: _line), do: file

  defp add_payload_version(event), do: Map.put(event, :payloadVersion, "2")

  defp add_severity(event, severity) when severity in ~w(error warning info),
    do: Map.put(event, :severity, severity)

  defp add_severity(event, severity) when severity in ~w(error warning info)a,
    do: Map.put(event, :severity, "#{severity}")

  defp add_severity(event, _), do: Map.put(event, :severity, "error")

  defp add_release_stage(event, release_stage),
    do: Map.put(event, :app, %{releaseStage: release_stage})

  defp add_notify_release_stages(event, notify_release_stages),
    do: Map.put(event, :notifyReleaseStages, notify_release_stages)

  defp add_context(event, nil), do: event
  defp add_context(event, context), do: Map.put(event, :context, context)

  defp add_user(event, nil), do: event
  defp add_user(event, user), do: Map.put(event, :user, user)

  defp add_device(event, os_version, hostname) do
    device =
      %{}
      |> Map.merge(if os_version, do: %{osVersion: os_version}, else: %{})
      |> Map.merge(if hostname, do: %{hostname: hostname}, else: %{})

    if Enum.empty?(device),
      do: event,
      else: Map.put(event, :device, device)
  end

  defp add_app_type(event, type) do
    event
    |> Map.put_new(:app, %{})
    |> put_in([:app, :type], type)
  end

  defp add_app_version(event, nil), do: event

  defp add_app_version(event, version) do
    event
    |> Map.put_new(:app, %{})
    |> put_in([:app, :version], version)
  end

  defp add_metadata(event, nil), do: event
  defp add_metadata(event, metadata), do: Map.put(event, :metaData, metadata)

  defp format_stacktrace(stacktrace, options) do
    in_project_fn = get_in_project_fn(options)

    stacktrace
    |> Enum.reverse()
    |> Enum.reduce([], fn
      {module, function, args, []}, acc ->
        # this happens when the function was not found,
        # since there is no file/line data, let's use the last known location instead,
        # because by default Bugsnag will group by the top frame's location
        last_frame = List.first(acc) || %{file: "unknown", lineNumber: 0, inProject: false}

        [
          %{
            file: last_frame.file,
            lineNumber: last_frame.lineNumber,
            inProject: last_frame.inProject,
            method: sanitize(Exception.format_mfa(module, function, args))
          }
          | acc
        ]

      {module, function, args, [error_info: _reason]}, acc ->
        # this is generated by Erlang 24 in many places (stdlib, erts, maps, binary, etc),
        # but we can behave just as above
        last_frame = List.first(acc) || %{file: "unknown", lineNumber: 0, inProject: false}

        [
          %{
            file: last_frame.file,
            lineNumber: last_frame.lineNumber,
            inProject: last_frame.inProject,
            method: sanitize(Exception.format_mfa(module, function, args))
          }
          | acc
        ]

      {module, function, args, [file: file, line: line_number]}, acc ->
        file = to_string(file)

        [
          %{
            file: file,
            lineNumber: line_number,
            inProject: in_project_fn.({module, function, args, file}),
            method: sanitize(Exception.format_mfa(module, function, args)),
            code: get_file_contents(file, line_number)
          }
          | acc
        ]
    end)
  end

  defp get_in_project_fn(options) do
    case fetch_option(options, :in_project, nil) do
      func when is_function(func) ->
        func

      {mod, fun, args} ->
        fn stack_frame -> apply(mod, fun, [stack_frame | args]) end

      %Regex{} = re ->
        fn {_m, _f, _a, file} -> Regex.match?(re, file) end

      str when is_binary(str) ->
        fn {_m, _f, _a, file} -> String.contains?(file, str) end

      _other ->
        fn _ -> false end
    end
  end

  defp get_file_contents(file, line_number) do
    file = File.cwd!() |> Path.join(file)

    if File.exists?(file) do
      file
      |> File.stream!()
      |> Stream.with_index()
      |> Stream.map(fn {line, index} -> {to_string(index + 1), line} end)
      |> Enum.slice(if(line_number - 4 > 0, do: line_number - 4, else: 0), 7)
      |> Enum.into(%{})
    end
  end

  defp sanitize(value) do
    sanitizer = Application.get_env(:bugsnag, :sanitizer)

    if sanitizer do
      {module, function} = sanitizer
      apply(module, function, [value])
    else
      value
    end
  rescue
    _ ->
      Logger.warn("Bugsnag Sanitizer failed to sanitize a value")

      "[CENSORED DUE TO SANITIZER EXCEPTION]"
  end
end
