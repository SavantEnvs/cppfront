// libFuzzer harness for the cppfront compiler front end: the pipeline cppfront's main()
// runs per source file (load, lex, parse, sema, lower to Cpp1, error printing), fed from
// memory through the compiler's own "stdin" input path.
// Built twice: mixed Cpp1/Cpp2 mode (default) and -pure-cpp2 (-DPURE_CPP2).

#include "to_cpp1.h"

#include <cstdint>
#include <iostream>
#include <sstream>
#include <string>

namespace {

struct null_buf : std::streambuf {
    int overflow(int c) override { return c; }
    std::streamsize xsputn(char const*, std::streamsize n) override { return n; }
};

null_buf sink;

}

extern "C" int LLVMFuzzerInitialize(int*, char***)
{
    std::cout.rdbuf(&sink);
    std::cerr.rdbuf(&sink);
#ifdef PURE_CPP2
    // what `cppfront -pure-cpp2 -include-std` sets
    cpp2::flag_cpp2_only   = true;
    cpp2::flag_import_std  = true;
    cpp2::flag_include_std = true;
#endif
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(uint8_t const* data, size_t size)
{
    std::istringstream in(std::string(reinterpret_cast<char const*>(data), size));
    auto* saved = std::cin.rdbuf(in.rdbuf());
    std::cin.clear();

    {
        cpp2::cppfront c("stdin");
        c.lower_to_cpp1();
        if (!c.had_no_errors()) {
            c.print_errors();
        }
    }

    std::cin.rdbuf(saved);

    // Everything cppfront keeps across compilations, reset so each input's result depends only on
    // that input. File-scope statics (marked "TODO: static" upstream):
    cpp2::generated_text         = {};
    cpp2::generated_lines        = {};
    cpp2::multiline_raw_strings  = {};   // lex_line() reads the previous compilation's .back()
    cpp2::generated_lexers       = {};
    // Sticky globals: set once a compilation hits a lifetime-safety violation / pretty-prints.
    cpp2::violates_lifetime_safety = false;
    cpp2::indent_spaces            = 2;
    // Function-local statics (lex.h labelized_position, parse.h last_parent_type), hoisted to
    // namespace scope in the copy of source/ that mayhem/build.sh compiles against. They are keyed
    // by / compared with addresses of the freed parse tree, and `ordinal` numbers generated names.
    cpp2::fuzz_labels            = {};
    cpp2::fuzz_label_ordinal     = 0;
    cpp2::fuzz_last_parent_type  = nullptr;
    // Left alone on purpose: cpp2::flag_* (set once in LLVMFuzzerInitialize, never by input),
    // expression_node::current_expressions / expression_statement_node::current_expression_statements
    // (push/pop under a scope guard, empty between compilations), cpp2::timers and stackinstr
    // (only used by CPP2_DEBUG_BUILD / commented-out code).
    return 0;
}
