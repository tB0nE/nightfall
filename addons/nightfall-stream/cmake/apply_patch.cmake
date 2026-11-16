# Applies PATCH to the current source tree once (FetchContent may re-run the
# patch step on an already patched checkout).
execute_process(COMMAND git apply --reverse --check "${PATCH}" RESULT_VARIABLE already_applied OUTPUT_QUIET ERROR_QUIET)
if(already_applied EQUAL 0)
    message(STATUS "Already applied: ${PATCH}")
    return()
endif()
execute_process(COMMAND git apply "${PATCH}" RESULT_VARIABLE result)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Failed to apply ${PATCH}")
endif()
