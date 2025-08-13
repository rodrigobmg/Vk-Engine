#import "Common";
#import "Compiler";
#import "Hash_Set";
#import "Metaprogram_Plugins";
#import "File";
#import "File_Utilities";
#import "Thread";
#import "Process";

Basic :: #import "Basic";
using, only(.["+","-","*","/","<",">"]) Basic;

String :: #import "String";

#load "Source/Build/entity.jai";
#load "Source/Build/asset.jai";
#load "Source/Build/shader_codegen.jai";
#load "Source/Build/renderer.jai";

Default_Plugins :: string.[
    "Check(CHECK_BINDINGS=false)",
];

Bindings_To_Generate :: string.[
    "Modules/ImGui",
    "Source/Modules/Vulkan",
];

Append   :: StringBuilderAppend;
Appendln :: StringBuilderAppendLine;

g_report_all_undeclared_identifiers := false;
g_verbose_tests := false;
g_execute_tests := true;
g_tests_to_execute : [..]string;

g_generated_runtime_tests_code := false;
g_runtime_tests : [..]string;

g_all_loaded_files : [..]string;

ReportErrorsForUnresolvedIdentifiersInAllFiles :: (workspace : Workspace) {
    for g_all_loaded_files {
        compiler_report_errors_for_unresolved_identifiers(it, workspace);
    }
}

GenerateBindings :: (module_name : string) {
    ws := compiler_create_workspace(module_name);

    options := get_build_options(ws);
    compiler_begin_intercept(ws);

    add_build_file(SPrint("%/generate.jai", module_name), ws);

    working_dir := Basic.get_working_directory();
    defer Basic.set_working_directory(working_dir);

    Basic.set_working_directory(SPrint("%/%", working_dir, module_name));

    while true {
        msg := compiler_wait_for_message();
        if msg.kind == .COMPLETE {
            if (cast(*Message_Complete) msg).error_code != .NONE {
                LogError("Could not generate bindings for %", module_name);
            } else {
                LogMessage("Generated bindings for %", module_name);
            }

            break;
        }
    }

    compiler_end_intercept(ws);
}

GetRootDirectory :: inline () -> string {
    filename := path_strip_filename(#file);

    return filename;
}

HandleCompilerMessage :: (msg : *Message) {
    if msg.kind == {
    case .ERROR;
        if g_report_all_undeclared_identifiers {
            ReportErrorsForUnresolvedIdentifiersInAllFiles(msg.workspace);
        } else {
            LogMessage("If this seems like an error caused by code not being generated, consider building using the -verbose_error option to report all undeclared identifiers in the main program.");
        }

    case .FILE;
        file := cast(*Message_File) msg;
        if file.enclosing_import && file.enclosing_import.module_type == .MAIN_PROGRAM {
            ArrayPushUnique(*g_all_loaded_files, file.fully_pathed_filename);
        }

    case .TYPECHECKED;
        typechecked := cast(*Message_Typechecked) msg;
        for typechecked.declarations {
            decl := it.expression;
            if !decl {
                continue;
            }

            HandleDeclarationForEntity(decl);
            HandleDeclarationForAsset(decl);
            HandleDeclarationForRenderer(decl);
            HandleDeclarationForShaderCodegen(decl);
        }

        if g_execute_tests {
            for typechecked.procedure_headers {
                header := it.expression;
                if !header {
                    continue;
                }

                for note : header.notes {
                    if note.text == "Test" {
                        ArrayPush(*g_tests_to_execute, header.name);
                    }
                    if note.text == "RuntimeTest" {
                        ArrayPush(*g_runtime_tests, header.name);
                    }
                }
            }
        }

    case .PHASE;
        phase := cast(*Message_Phase) msg;
        if phase.phase == .TYPECHECKED_ALL_WE_CAN {
            GenerateEntityCode(msg.workspace);
            GenerateAssetCode(msg.workspace);
            GenerateRendererCode(msg.workspace);

            if !g_generated_runtime_tests_code {
                defer {
                    g_generated_runtime_tests_code = true;
                    ArrayClear(*g_runtime_tests);
                }

                builder : StringBuilder;
                Appendln(*builder, "Runtime_Tests :: string.[");
                for g_runtime_tests {
                    Appendln(*builder, "    \"%\",", it);
                }
                Appendln(*builder, "];");

                add_build_string(StringBuilderBuild(*builder), msg.workspace);
            }

            if g_execute_tests && g_tests_to_execute.count > 0 {
                builder : StringBuilder;
                Append(*builder, "#run, stallable {\n");

                Append(*builder,
#string JAI
    console_logger : ConsoleLogger;
    InitConsoleLogger(*console_logger);
    SetContextLogger(*console_logger, ConsoleLoggerProc);
JAI
                );

                for g_tests_to_execute {
                    Append(*builder, "    {\n");
                    Append(*builder, "        log_section := Log_Section.{\"Tests/%\"};\n", it);
                    Append(*builder, "        LogSectionScope(*log_section);\n");
                    Append(*builder, "        %(%);\n", it, g_verbose_tests);
                    Append(*builder, "    }\n");
                }

                Append(*builder, "}");

                test_code := StringBuilderBuild(*builder);
                add_build_string(test_code, msg.workspace);

                ArrayClear(*g_tests_to_execute);
            }
        }

    case .COMPLETE;
        complete := cast(*Message_Complete, msg);

        if complete.error_code == .NONE {
            GenerateShaderCode(msg.workspace);
        }
    }
}

Build :: () {
    compilation_failed := false;

    begin_time := Basic.current_time_monotonic();
    defer if !compilation_failed {
        end_time := Basic.current_time_monotonic();
        total_time := end_time - begin_time;
        Println("\n    Compiled program in % s", Basic.to_float64_seconds(total_time));
    }

    set_build_options_dc(.{do_output=false, write_added_strings=false});

    log_section := Log_Section.{"Metaprogram"};
    LogSectionScope(*log_section);

    console_logger : ConsoleLogger;
    InitConsoleLogger(*console_logger);
    SetContextLogger(*console_logger, ConsoleLoggerProc);

    ws := compiler_create_workspace("Vk");

    args := get_build_options().compile_time_command_line;
    arg_index := 0;
    arg_error := false;
    plugin_start_index := -1;

    generate_bindings : bool;

    while arg_index < args.count {
        defer arg_index += 1;

        if args[arg_index][0] == #char "+" {
            plugin_start_index = arg_index;
            break;
        } else if args[arg_index] == {
        case "-generate_bindings";
            generate_bindings = true;

        case "-no_tests";
            g_execute_tests = false;

        case "-verbose_tests";
            g_verbose_tests = true;

        case "-verbose_error";
            g_report_all_undeclared_identifiers = true;

        case;
            LogError("Unknown argument '%'.", args[arg_index]);
            arg_error = true;
            break;
        }
    }

    if generate_bindings {
        for Bindings_To_Generate {
            GenerateBindings(it);
        }
    }

    plugins_to_create : [..]Plugin_To_Create;

    if plugin_start_index >= 0 {
        success:, plugins_to_create = parse_plugin_arguments(args, plugin_start_index);
        if !success {
            Basic.exit(1);
        }
    }

    for Default_Plugins {
        ArrayPush(*plugins_to_create, .{name=it});
    }

    plugins : [..]*Metaprogram_Plugin;
    init_plugins(plugins_to_create, *plugins, ws);

    if arg_error {
        Basic.exit(1);
    }

    options := get_build_options(ws);
    options.output_type = .EXECUTABLE;
    options.output_executable_name = "Vk";
    options.intermediate_path = "Source/.build";
    options.import_path = get_build_options().import_path;
    options.Commonly_Propagated = get_build_options().Commonly_Propagated;
    options.write_added_strings = true;
    options.stack_trace = true;
    options.text_output_flags = 0;

    #if OS == .LINUX {
        #import "POSIX";

        options.additional_linker_arguments = .[
            TPrint("-L%/lib", MakeString(getenv("VULKAN_SDK"))),
        ];
    }

    set_build_options(options, ws);

    intercept_flags : Intercept_Flags;
    for plugins {
        if it.before_intercept {
            it.before_intercept(it, *intercept_flags);
        }
    }

    compiler_begin_intercept(ws, intercept_flags);

    for plugins {
        if it.add_source {
            it.add_source(it);
        }
    }

    add_build_file("Source/main.jai", ws);

    while true {
        msg := compiler_wait_for_message();

        for plugins {
            if it.message {
                it.message(it, msg);
            }
        }

        HandleCompilerMessage(msg);

        if msg.kind == .COMPLETE {
            complete := cast(*Message_Complete) msg;
            if complete.error_code != .NONE {
                LogError("Compilation failed");
                compilation_failed = true;
            }

            break;
        }
    }

    compiler_end_intercept(ws);

    for plugins {
        if it.finish {
            it.finish(it);
        }
    }

    for plugins {
        if it.shutdown {
            it.shutdown(it);
        }
    }
}

#run, stallable Build(); // If plugins have assertions, they may stall
