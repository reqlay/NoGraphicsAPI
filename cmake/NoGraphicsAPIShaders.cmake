include_guard(GLOBAL)

if(APPLE)
    set(NOGRAPHICSAPI_SHADER_EXTENSION metallib CACHE INTERNAL "Native shader artifact extension" FORCE)
else()
    set(NOGRAPHICSAPI_SHADER_EXTENSION shader CACHE INTERNAL "Native shader artifact extension" FORCE)
endif()

function(NoGraphicsAPI_require_tool_version program argument name minimum pattern)
    string(SHA256 key "${program};${minimum}")
    get_property(checked GLOBAL PROPERTY "NoGraphicsAPI_shader_tool_${key}")
    if(checked)
        return()
    endif()
    execute_process(COMMAND "${program}" "${argument}" RESULT_VARIABLE result
        OUTPUT_VARIABLE output ERROR_VARIABLE error OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_STRIP_TRAILING_WHITESPACE)
    string(STRIP "${output}${error}" version_text)
    string(REGEX MATCH "${pattern}" match "${version_text}")
    if(NOT result EQUAL 0 OR NOT match OR CMAKE_MATCH_1 VERSION_LESS minimum)
        message(FATAL_ERROR "NoGraphicsAPI shaders require ${name} ${minimum} or newer; found '${version_text}' at ${program}")
    endif()
    set_property(GLOBAL PROPERTY "NoGraphicsAPI_shader_tool_${key}" TRUE)
endfunction()

function(NoGraphicsAPI_compile_slang output source entry stage)
    cmake_parse_arguments(SLANG "" "" "DEPENDS;DEFINES;OPTIONS;INCLUDE_DIRECTORIES" ${ARGN})
    if(SLANG_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "Unknown NoGraphicsAPI_compile_slang arguments: ${SLANG_UNPARSED_ARGUMENTS}")
    endif()
    cmake_path(ABSOLUTE_PATH output BASE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}" NORMALIZE)
    cmake_path(ABSOLUTE_PATH source BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE)
    get_filename_component(output_dir "${output}" DIRECTORY)
    find_program(NOGRAPHICSAPI_SLANGC NAMES slangc REQUIRED)
    set(options "-I${CMAKE_CURRENT_SOURCE_DIR}"
        "-I$<JOIN:$<TARGET_PROPERTY:NoGraphicsAPI::NoGraphicsAPI,INTERFACE_INCLUDE_DIRECTORIES>,;-I>")
    if(EXISTS "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../tools/compile_shader.py")
        set(compiler "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../tools/compile_shader.py")
        list(APPEND options "-I${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../utility/include")
    else()
        set(compiler "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/compile_shader.py")
    endif()
    foreach(directory IN LISTS SLANG_INCLUDE_DIRECTORIES)
        cmake_path(ABSOLUTE_PATH directory BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE)
        list(APPEND options "-I${directory}")
    endforeach()
    foreach(define IN LISTS SLANG_DEFINES)
        list(APPEND options "-D${define}")
    endforeach()
    list(APPEND options ${SLANG_OPTIONS})
    if(APPLE)
        NoGraphicsAPI_require_tool_version("${NOGRAPHICSAPI_SLANGC}" -version Slang 2026.18.2 "([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
        find_program(NOGRAPHICSAPI_XCRUN NAMES xcrun REQUIRED)
        if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
            set(sdk iphoneos)
            set(platform ios)
        else()
            set(sdk macosx)
            set(platform macos)
        endif()
        set(NOGRAPHICSAPI_METAL_SDK "${sdk}" CACHE INTERNAL "Metal SDK" FORCE)
        set(deployment_target "${CMAKE_OSX_DEPLOYMENT_TARGET}")
        if(NOT deployment_target)
            set(deployment_target 26.0)
        endif()
        set(NOGRAPHICSAPI_METAL_TARGET "air64-apple-${platform}${deployment_target}" CACHE INTERNAL "Metal target" FORCE)
        add_custom_command(OUTPUT "${output}"
            BYPRODUCTS "${output}.metal" "${output}.air"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${output_dir}"
            COMMAND "${NOGRAPHICSAPI_SLANGC}" "${source}" -target metal -DNOGRAPHICSAPI_METAL -fvk-use-c-layout -matrix-layout-row-major
                -entry "${entry}" -stage "${stage}" "${options}" -depfile "${output}.d" -o "${output}.metal"
            COMMAND "${NOGRAPHICSAPI_XCRUN}" -sdk "${sdk}" metal -std=metal4.0
                -target "${NOGRAPHICSAPI_METAL_TARGET}" -c "${output}.metal" -o "${output}.air"
            COMMAND "${NOGRAPHICSAPI_XCRUN}" -sdk "${sdk}" metallib "${output}.air" -o "${output}"
            DEPENDS "${source}" ${SLANG_DEPENDS} "${CMAKE_CURRENT_FUNCTION_LIST_FILE}"
            DEPFILE "${output}.d"
            COMMAND_EXPAND_LISTS VERBATIM
            COMMENT "Compiling Slang ${stage} shader ${entry} to metallib")
    else()
        NoGraphicsAPI_require_tool_version("${NOGRAPHICSAPI_SLANGC}" -version Slang 2026.14.1 "([0-9]+\\.[0-9]+(\\.[0-9]+)?)")
        find_program(NOGRAPHICSAPI_SPIRV_VAL NAMES spirv-val REQUIRED)
        NoGraphicsAPI_require_tool_version("${NOGRAPHICSAPI_SPIRV_VAL}" --version SPIRV-Tools 2026.3 "SPIRV-Tools v([0-9]+\\.[0-9]+)")
        find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)
        add_custom_command(OUTPUT "${output}"
            COMMAND "${Python3_EXECUTABLE}" "${compiler}" "${source}" -o "${output}" --entry "${entry}" --stage "${stage}"
                --slang "${NOGRAPHICSAPI_SLANGC}" --spirv-val "${NOGRAPHICSAPI_SPIRV_VAL}" --depfile "${output}.d" -- "${options}"
            DEPENDS "${source}" ${SLANG_DEPENDS} "${compiler}" "${CMAKE_CURRENT_FUNCTION_LIST_FILE}"
            DEPFILE "${output}.d"
            COMMAND_EXPAND_LISTS VERBATIM
            COMMENT "Compiling and validating NoGraphicsAPI shader ${entry}")
    endif()
endfunction()
