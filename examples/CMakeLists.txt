function(NoGraphicsAPI_add_example target)
    add_executable(${target} ${ARGN})
    foreach(source IN LISTS ARGN)
        if(source MATCHES "\\.slang$")
            set_source_files_properties(${source} PROPERTIES HEADER_FILE_ONLY TRUE)
            source_group("Shaders" FILES ${source})
        endif()
    endforeach()
    NoGraphicsAPI_disable_exceptions(${target})
    target_link_libraries(${target} PRIVATE NoGraphicsAPI_example_support)
endfunction()

add_library(NoGraphicsAPI_example_support STATIC
    common/example_support.cpp
    common/example_support.hpp
)
if(APPLE)
    target_sources(NoGraphicsAPI_example_support PRIVATE common/example_window_macos.mm)
    target_link_libraries(NoGraphicsAPI_example_support PRIVATE "-framework AppKit" "-framework QuartzCore")
    target_compile_options(NoGraphicsAPI_example_support PRIVATE -fno-objc-arc)
else()
    target_sources(NoGraphicsAPI_example_support PRIVATE common/example_window_win32.cpp)
endif()
NoGraphicsAPI_disable_exceptions(NoGraphicsAPI_example_support)
target_link_libraries(NoGraphicsAPI_example_support PUBLIC NoGraphicsAPI::NoGraphicsAPI)
target_include_directories(NoGraphicsAPI_example_support PUBLIC common)
if(WIN32)
    target_link_libraries(NoGraphicsAPI_example_support PUBLIC user32)
    target_compile_definitions(NoGraphicsAPI_example_support PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

add_subdirectory(triangle)
add_subdirectory(cube)
add_subdirectory(deferred_renderer)

function(NoGraphicsAPI_make_release_gui target)
    if(WIN32)
        set_target_properties(${target} PROPERTIES
            WIN32_EXECUTABLE "$<$<CONFIG:Release>:TRUE>"
        )
        target_link_options(${target} PRIVATE
            "$<$<CONFIG:Release>:/ENTRY:mainCRTStartup>"
        )
    endif()
endfunction()

NoGraphicsAPI_make_release_gui(example_triangle)
NoGraphicsAPI_make_release_gui(example_cube)
NoGraphicsAPI_make_release_gui(example_deferred_renderer)
