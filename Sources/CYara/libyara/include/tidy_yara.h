// Tidy's small C layer over libyara: a few plain functions with callbacks, so the Swift side never
// handles libyara's structs and macros. Everything else in this target is libyara as released.
#ifndef TIDY_YARA_H
#define TIDY_YARA_H

#include <stddef.h>
#include <stdint.h>
#include "yara.h"

/// A compile error or warning. `file` is NULL for rules given as text.
typedef void (*tidy_yara_message_fn)(void* context, int is_warning, const char* file, int line, const char* message);

/// A rule that matched: its name, its namespace, and its `description` meta (NULL if it has none).
typedef void (*tidy_yara_match_fn)(void* context, const char* rule, const char* rule_namespace, const char* description);

/// Rules as text, or an open rules file (`text` NULL). `file_name` names the file in messages and
/// is where `include` statements are resolved from.
typedef struct
{
  const char* rule_namespace;
  const char* text;
  int fd;
  const char* file_name;
} tidy_yara_source;

/// Starts libyara. Call it once before anything else. Returns 0 (ERROR_SUCCESS) or a libyara error code.
int tidy_yara_initialize(void);

/// Compiles the sources into one set of rules, or returns NULL if any of them has an error (or
/// memory runs out). Every error and warning is passed to `on_message` before this returns.
YR_RULES* tidy_yara_compile(
    const tidy_yara_source* sources,
    int count,
    tidy_yara_message_fn on_message,
    void* context);

/// Rules that can match; private rules are only building blocks and never reported.
/// A NULL namespace counts them all.
int tidy_yara_rule_count(YR_RULES* rules, const char* rule_namespace);

void tidy_yara_rules_free(YR_RULES* rules);

/// Both return 0 (ERROR_SUCCESS) or a libyara error code, such as ERROR_SCAN_TIMEOUT.
/// Matches are passed to `on_match` before they return.
int tidy_yara_scan_fd(YR_RULES* rules, int fd, int timeout_seconds, tidy_yara_match_fn on_match, void* context);
int tidy_yara_scan_bytes(
    YR_RULES* rules,
    const uint8_t* bytes,
    size_t length,
    int timeout_seconds,
    tidy_yara_match_fn on_match,
    void* context);

#endif
