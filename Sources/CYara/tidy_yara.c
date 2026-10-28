// See include/tidy_yara.h.
#include <string.h>
#include "tidy_yara.h"

typedef struct
{
  tidy_yara_message_fn on_message;
  void* context;
} message_target;

typedef struct
{
  tidy_yara_match_fn on_match;
  void* context;
} match_target;

int tidy_yara_initialize(void)
{
  return yr_initialize();
}

static void on_compiler_message(
    int error_level,
    const char* file_name,
    int line_number,
    const YR_RULE* rule,
    const char* message,
    void* user_data)
{
  message_target* target = (message_target*) user_data;
  if (target->on_message != NULL)
    target->on_message(
        target->context,
        error_level == YARA_ERROR_LEVEL_WARNING,
        file_name,
        line_number,
        message);
}

YR_RULES* tidy_yara_compile(
    const tidy_yara_source* sources,
    int count,
    tidy_yara_message_fn on_message,
    void* context)
{
  YR_COMPILER* compiler = NULL;
  YR_RULES* rules = NULL;
  message_target target = {on_message, context};
  int errors = 0;

  if (yr_compiler_create(&compiler) != ERROR_SUCCESS)
    return NULL;

  yr_compiler_set_callback(compiler, on_compiler_message, &target);

  // libyara can't add more rules to a compiler once one source had an error.
  for (int i = 0; i < count && errors == 0; i++)
  {
    const tidy_yara_source* source = &sources[i];
    if (source->text != NULL)
      errors = yr_compiler_add_string(compiler, source->text, source->rule_namespace);
    else
      errors = yr_compiler_add_fd(compiler, source->fd, source->rule_namespace, source->file_name);
  }

  if (errors == 0 && yr_compiler_get_rules(compiler, &rules) != ERROR_SUCCESS)
    rules = NULL;

  yr_compiler_destroy(compiler);
  return rules;
}

int tidy_yara_rule_count(YR_RULES* rules, const char* rule_namespace)
{
  const YR_RULE* rule;
  int count = 0;

  yr_rules_foreach(rules, rule)
  {
    if (RULE_IS_PRIVATE(rule))
      continue;
    if (rule_namespace == NULL || strcmp(rule->ns->name, rule_namespace) == 0)
      count++;
  }
  return count;
}

void tidy_yara_rules_free(YR_RULES* rules)
{
  if (rules != NULL)
    yr_rules_destroy(rules);
}

static int on_scan_message(YR_SCAN_CONTEXT* context, int message, void* message_data, void* user_data)
{
  if (message == CALLBACK_MSG_RULE_MATCHING)
  {
    const YR_RULE* rule = (const YR_RULE*) message_data;
    const YR_META* meta;
    const char* description = NULL;
    match_target* target = (match_target*) user_data;

    yr_rule_metas_foreach(rule, meta)
    {
      if (meta->type == META_TYPE_STRING && strcmp(meta->identifier, "description") == 0)
      {
        description = meta->string;
        break;
      }
    }
    target->on_match(target->context, rule->identifier, rule->ns->name, description);
  }
  return CALLBACK_CONTINUE;
}

int tidy_yara_scan_fd(YR_RULES* rules, int fd, int timeout_seconds, tidy_yara_match_fn on_match, void* context)
{
  match_target target = {on_match, context};
  return yr_rules_scan_fd(
      rules, fd, SCAN_FLAGS_REPORT_RULES_MATCHING, on_scan_message, &target, timeout_seconds);
}

int tidy_yara_scan_bytes(
    YR_RULES* rules,
    const uint8_t* bytes,
    size_t length,
    int timeout_seconds,
    tidy_yara_match_fn on_match,
    void* context)
{
  match_target target = {on_match, context};
  return yr_rules_scan_mem(
      rules, bytes, length, SCAN_FLAGS_REPORT_RULES_MATCHING, on_scan_message, &target, timeout_seconds);
}
