defmodule Mix.Tasks.Compile.Dynamo do
  use Mix.Task

  @hidden true
  @shortdoc "Compile Dynamo source files"
  @recursive true
  @manifest ".compile.dynamo"

  @moduledoc """
  A task to compile Dynamo source files.

  This task will compile all dynamos registered in
  your Mix project under the `dynamos` configuration.
  If the current dynamo is set to `:compile_on_demand`
  compilation is actually skipped.

  ## Configuration

  * `:dynamos` - the dynamos registered in this project:

        [dynamos: Foo, Bar]

  This task also uses `:compile_path` and `:elixirc_options`
  options shared with other compilation tasks.

  ## Command line options

  * `--force` - forces compilation regardless of mod times;

  """

  @switches [ force: :boolean, docs: :boolean, ignore_module_conflict: :boolean,
              debug_info: :boolean, warnings_as_errors: :boolean ]

  @doc """
  Runs this task.
  """
  def run(args) do
    opts = OptionParser.parse(args, switches: @switches) |> elem(0)

    Enum.reduce Mix.Project.config[:dynamos], :noop, fn(dynamo, acc) ->
      if dynamo.config[:dynamo][:compile_on_demand] do
        acc
      else
        do_compile(dynamo, opts, acc)
      end
    end
  end

  @doc """
  The manifests for this compiler.
  """
  def manifests, do: [manifest]
  defp manifest, do: Path.join(Mix.Project.compile_path, @manifest)

  defp do_compile(mod, opts, acc) do
    root    = File.cwd!
    project = Mix.Project.config
    dynamo  = mod.config[:dynamo]

    compile_path = Mix.Project.compile_path
    compile_exts = [:ex]
    watch_exts   = [:ex, :eex, :exs]
    source_paths = dynamo[:source_paths]
    templates    = extract_templates(dynamo[:templates_paths])

    # Source files + Mix setup + Dynamo config + Templates
    to_watch = Mix.Utils.extract_files(source_paths, watch_exts)
    to_watch = Mix.Tasks.Compile.Elixir.manifests ++ to_watch
    to_watch = to_watch ++ Enum.map(templates, &template_mtime(&1))

    manifest = manifest()

    if opts[:force] || Mix.Utils.stale?(to_watch, [manifest]) do
      set_compiler_opts(project, opts)

      to_compile = Mix.Utils.extract_files(source_paths, compile_exts)
      File.mkdir_p!(compile_path)
      Code.prepend_path compile_path

      previous = read_manifest(manifest)
      Enum.each previous, fn entry ->
        Path.join(compile_path, entry <> ".beam") |> File.rm
      end

      compiled = compile_files to_compile, compile_path, root
      compiled = for { mod, _ } <- compiled, do: to_string(mod)

      write_manifest(manifest, compiled)
      compile_templates mod, dynamo[:compiled_templates], templates, compile_path

      :ok
    else
      acc
    end
  end

  defp set_compiler_opts(project, opts) do
    opts = Dict.take(opts, [:docs, :debug_info, :ignore_module_conflict, :warnings_as_errors])
    opts = Keyword.merge(project[:elixirc_options] || [], opts)
    Code.compiler_options(opts)
  end

  defp extract_templates(paths) do
    for path <- paths,
       not Dynamo.Templates.Finder.requires_precompilation?(path),
       templates = Dynamo.Templates.Finder.all(path),
       template <- templates, do: template
  end

  defp template_mtime(%Dynamo.Template{key: key, updated_at: updated_at}) do
    { key, updated_at }
  end

  defp compile_files(files, to, root) do
    Kernel.ParallelCompiler.files_to_path files, to, each_file: fn(original) ->
      relative = Path.relative_to(original, root)
      Mix.shell.info "Compiled #{relative}"
      original
    end
  end

  defp compile_templates(mod, name, templates, compile_path) do
    binary = Dynamo.Templates.compile_module(name, templates, [:conn],
               fn -> mod.templates_prelude end)
    File.write! Path.join(compile_path, "#{name}.beam"), binary
    Mix.shell.info "Generated #{inspect name}"
  end

  defp read_manifest(file) do
    case File.read(file) do
      {:ok, contents} -> String.split(contents, "\n")
      {:error, _} -> []
    end
  end

  def write_manifest(file, entries) do
    Path.dirname(file) |> File.mkdir_p!
    File.write!(file, Enum.join(entries, "\n"))
  end

end
