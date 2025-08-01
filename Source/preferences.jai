Preferences :: struct {
    startup_scene : string;
    startup_window_width : u32 = 1600;
    startup_window_height : u32 = 900;

    environment_map_resolution : u32 = 1024;
    environment_map_num_samples : u32 = 128;
    irradiance_map_resolution : u32 = 256;
    irradiance_map_sample_delta : float = 0.025;
}

Log_Preferences :: Log_Section.{name="Preferences"};

LoadPreferences :: (preferences : *Preferences, filename : string, str : string) {
    LogSectionScope(*Log_Preferences);

    info := type_info(Preferences);
    for info.members {
        if it.type.type != .STRING {
            continue;
        }

        str := cast(*string, cast(*void, preferences) + it.offset_in_bytes);
        if str.data {
            str.* = StringClone(str.*);
        }
    }

    lines := StringSplit(str, #char "\n" ,, Temp);
    for it, line_index : lines {
        line := trim(it);

        if line.count <= 0 || line[0] == #char "#" {
            continue;
        }

        ident := parse_token(*line);
        for c : ident {
            if it_index == 0 && !Basic.is_alpha(c) {
                LogError("%:%: Expected identifier", filename, line_index + 1);
                continue it;
            }

            if !Basic.is_alnum(c) {
                LogError("%:%: Expected identifier", filename, line_index + 1);
                continue it;
            }
        }

        value : Any;
        for member : info.members {
            if member.name == ident {
                value.type = member.type;
                value.value_pointer = cast(*void, preferences) + member.offset_in_bytes;
                break;
            }
        }

        if !value.value_pointer {
            LogError("%:%: Unknown variable %", filename, line_index + 1, ident);
            continue it;
        }

        line = trim(line);
        if line.count <= 0 || line[0] != #char "=" {
            LogError("%:%: Expected = after identifier", filename, line_index + 1);
            continue it;
        }

        line = StringAdvance(line, 1);
        line = trim(line);

        if value.type.type == {
        case .STRING;
            if line.count < 2 || line[0] != #char "\"" {
                LogError("%:%: Expected a string literal", filename, line_index + 1);
                continue it;
            }

            result : [..]u8;
            ArrayReserve(*result, line.count - 2);

            i := 1;
            while i < line.count {
                defer i += 1;

                if line[i] == #char "\"" {
                    i += 1;

                    str := cast(*string, value.value_pointer);
                    Free(str.data);
                    str.* = xx result;
                    if i != line.count {
                        LogError("%:%: Unexpected characters after string literal", filename, line_index + 1);
                    }

                    continue it;
                }

                if line[i] == #char "\\" {
                    i += 1;

                    if i == line.count {
                        break;
                    }

                    if line[i] == {
                    case #char "\""; ArrayPush(*result, #char "\"");
                    case #char "\\"; ArrayPush(*result, #char "\\");
                    case #char "t"; ArrayPush(*result, #char "\t");
                    case #char "r"; ArrayPush(*result, #char "\r");
                    case #char "n"; ArrayPush(*result, #char "\n");
                    case;
                        ArrayFree(*result);
                        LogError("%:%: Invalid escape sequence in string literal", filename, line_index + 1);

                        continue it;
                    }
                } else {
                    ArrayPush(*result, line[i]);
                }
            }

            ArrayFree(*result);
            LogError("%:%: Unclosed string literal", filename, line_index + 1);

        case .INTEGER;
            Parse :: (value : Any, line : string, $T : Type) #expand {
                int_value, ok, remainder := Basic.string_to_int(line, T=T);
                if !ok {
                    LogError("%:%: Expected int value", filename, line_index + 1);
                    return;
                }

                if remainder.count > 0 {
                    LogError("%:%: Unexpected characters after int value", filename, line_index + 1);
                }

                cast(*T, value.value_pointer).* = int_value;
            }

            info_int := cast(*Type_Info_Integer, value.type);

            if info_int.signed {
                if info_int.runtime_size == {
                case 1; Parse(value, line, s8);
                case 2; Parse(value, line, s16);
                case 4; Parse(value, line, s32);
                case 8; Parse(value, line, s64);
                case; Panic("Corrupt type info");
                }
            } else {
                if info_int.runtime_size == {
                case 1; Parse(value, line, u8);
                case 2; Parse(value, line, u16);
                case 4; Parse(value, line, u32);
                case 8; Parse(value, line, u64);
                case; Panic("Corrupt type info");
                }
            }

        case .FLOAT;
            if value.type.runtime_size == {
            case 4;
                float_value, ok, remainder := Basic.string_to_float(line);
                if !ok {
                    LogError("%:%: Expected float value", filename, line_index + 1);
                    continue it;
                }

                if remainder.count > 0 {
                    LogError("%:%: Unexpected characters after float value", filename, line_index + 1);
                }

                cast(*float, value.value_pointer).* = float_value;

            case 8;
                float_value, ok, remainder := Basic.string_to_float64(line);
                if !ok {
                    LogError("%:%: Expected float value", filename, line_index + 1);
                    continue it;
                }

                if remainder.count > 0 {
                    LogError("%:%: Unexpected characters after float value", filename, line_index + 1);
                }

                cast(*float64, value.value_pointer).* = float_value;

            case;
                Panic("Corrupt type info");
            }

        case .BOOL;
            if line == "true" {
                cast(*bool, value.value_pointer).* = true;
            } else if line == "false" {
                cast(*bool, value.value_pointer).* = false;
            } else {
                LogError("%:%: Expected bool value (true or false)", filename, line_index + 1);
            }

        case;
            LogError("%:%: Unhandled type % for preferences file", filename, line_index + 1, get_type(value.type));
        }
    }
}

LoadPreferences :: (preferences : *Preferences, filename : string) -> bool {
    LogSectionScope(*Log_Preferences);

    file_contents, ok := read_entire_file(filename);
    if !ok {
        return false;
    }

    defer Free(file_contents.data);

    LoadPreferences(preferences, filename, file_contents);

    return true;
}

FreePreferences :: (preferences : *Preferences) {
    info := type_info(Preferences);
    for info.members {
        if it.type.type == .STRING {
            str := cast(*string, cast(*void, preferences) + it.offset_in_bytes).*;
            Free(str.data);
        }
    }

    preferences.* = .{};
}
