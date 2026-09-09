// This file is a part of Julia. License is MIT: https://julialang.org/license

#ifndef JL_JLOPTIONS_H
#define JL_JLOPTIONS_H

// NOTE: This struct needs to be kept in sync with JLOptions type in base/options.jl

typedef struct {
    int8_t quiet;
    int8_t banner;
    const char *julia_bindir;
    const char *julia_bin;
    const char **cmds;
    const char *image_file;
    const char *cpu_target;
    int8_t nthreadpools;
    int16_t nthreads;
    int16_t nmarkthreads;
    int8_t nsweepthreads;
    const int16_t *nthreads_per_pool;
    int32_t nprocs;
    const char *machine_file;
    const char *project;
    const char *program_file;
    int8_t isinteractive;
    int8_t color;
    int8_t historyfile;
    int8_t startupfile;
    int8_t compile_enabled;
    int8_t code_coverage;
    int8_t malloc_log;
    const char *tracked_path;
    int8_t opt_level;
    int8_t opt_level_min;
    int8_t debug_level;
    int8_t check_bounds;
    int8_t depwarn;
    int8_t warn_overwrite;
    int8_t can_inline;
    int8_t polly;
    const char *trace_compile;
    const char *trace_dispatch;
    int8_t fast_math;
    int8_t worker;
    const char *cookie;
    int8_t handle_signals;
    int8_t use_experimental_features;
    int8_t use_sysimage_native_code;
    int8_t use_compiled_modules;
    int8_t use_pkgimages;
    const char *bindto;
    const char *outputbc;
    const char *outputunoptbc;
    const char *outputo;
    const char *outputasm;
    const char *outputji;
    const char *output_code_coverage;
    int8_t incremental;
    int8_t image_file_specified;
    int8_t warn_scope;
    int8_t image_codegen;
    int8_t rr_detach;
    int8_t strip_metadata;
    int8_t strip_ir;
    int8_t permalloc_pkgimg;
    uint64_t heap_size_hint;
    uint64_t hard_heap_limit;
    uint64_t heap_target_increment;
    int8_t trace_compile_timing;
    int8_t trim;
    int8_t trace_eval;
    int8_t task_metrics;
    int16_t timeout_for_safepoint_straggler_s;
    int8_t gc_sweep_always_full;
    int8_t compress_sysimage;
    int8_t alert_on_critical_error;
    const char *reactive_server;
    // The reactive compiler's options (contrib/reactive-compiler, Stage H):
    // a flag sets the field; an unset field (-1, NULL) reads the variable
    // JULIA_REACTIVE_* of the same name, so a build tool drives a child
    // through either and the flag wins.
    int8_t reactive_reuse;            // JULIA_REACTIVE_REUSE
    int8_t reactive_image_format;     // JULIA_REACTIVE_IMAGE
    int8_t reactive_image_write;      // JULIA_REACTIVE_IMAGE_WRITE: 0 whole, 1 pages, 2 overlay
    int8_t reactive_delta_opt;        // JULIA_REACTIVE_DELTA_OPT: 0 to 3
    int8_t reactive_timings;          // JULIA_REACTIVE_TIMINGS: 0 to 2
    const char *reactive_trim_memo;   // JULIA_REACTIVE_TRIM_MEMO
    const char *reactive_heapdump;    // JULIA_REACTIVE_HEAPDUMP
    const char *reactive_dirty_pages; // JULIA_REACTIVE_DIRTY_PAGES
} jl_options_t;

#endif
