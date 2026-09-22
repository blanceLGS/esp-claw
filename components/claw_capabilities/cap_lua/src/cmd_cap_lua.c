/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "cmd_cap_lua.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "argtable3/argtable3.h"
#include "cap_lua.h"
#include "claw_paths.h"
#include "esp_console.h"

static struct {
    struct arg_lit *run;
    struct arg_lit *run_async;
    struct arg_lit *jobs;
    struct arg_str *job;
    struct arg_str *eval_b64;
    struct arg_str *path;
    struct arg_str *args_json;
    struct arg_str *status;
    struct arg_int *timeout_ms;
    struct arg_end *end;
} lua_args;

static int b64_val(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

/* Decode standard base64 (padding optional) into a malloc'd buffer. */
static char *b64_decode_alloc(const char *in, size_t *out_len)
{
    size_t n;
    size_t o = 0;
    char *out;
    int vals[4];
    int vi = 0;

    if (!in) {
        return NULL;
    }
    n = strlen(in);
    if (n == 0) {
        return NULL;
    }
    /* strip padding; argtable also treats a trailing '=' as a value terminator */
    while (n > 0 && in[n - 1] == '=') {
        n--;
    }
    if (n == 0) {
        return NULL;
    }
    out = malloc((n + 3) / 4 * 3 + 1);
    if (!out) {
        return NULL;
    }
    for (size_t i = 0; i < n; i++) {
        int v = b64_val(in[i]);
        if (v < 0) {
            free(out);
            return NULL;
        }
        vals[vi++] = v;
        if (vi == 4) {
            out[o++] = (char)((vals[0] << 2) | (vals[1] >> 4));
            out[o++] = (char)(((vals[1] & 0x0F) << 4) | (vals[2] >> 2));
            out[o++] = (char)(((vals[2] & 0x03) << 6) | vals[3]);
            vi = 0;
        }
    }
    if (vi == 2) {
        out[o++] = (char)((vals[0] << 2) | (vals[1] >> 4));
    } else if (vi == 3) {
        out[o++] = (char)((vals[0] << 2) | (vals[1] >> 4));
        out[o++] = (char)(((vals[1] & 0x0F) << 4) | (vals[2] >> 2));
    } else if (vi != 0) {
        free(out);
        return NULL;
    }
    out[o] = '\0';
    if (out_len) {
        *out_len = o;
    }
    return out;
}

static int lua_run_eval_b64(const char *b64, uint32_t timeout_ms, char *result)
{
    char dir[160];
    char path[192];
    char *code;
    size_t code_len = 0;
    FILE *fp;
    esp_err_t err;

    code = b64_decode_alloc(b64, &code_len);
    if (!code) {
        printf("invalid base64\n");
        return 1;
    }
    if (claw_paths_join(CLAW_PATH_DATA, "temp", dir, sizeof(dir)) != ESP_OK) {
        free(code);
        printf("data root not ready\n");
        return 1;
    }
    mkdir(dir, 0755);
    if (snprintf(path, sizeof(path), "%s/lua_eval.lua", dir) >= (int)sizeof(path)) {
        free(code);
        printf("path too long\n");
        return 1;
    }
    fp = fopen(path, "wb");
    if (!fp) {
        free(code);
        printf("cannot write eval file\n");
        return 1;
    }
    if (fwrite(code, 1, code_len, fp) != code_len) {
        fclose(fp);
        free(code);
        printf("short write eval file\n");
        return 1;
    }
    fclose(fp);
    free(code);
    err = cap_lua_run_script(path, NULL, timeout_ms, result, 4096);
    unlink(path);
    return err == ESP_OK ? 0 : 1;
}

static void print_lua_result(const char *result)
{
    if (result && result[0]) {
        printf("%s\n", result);
    }
}

static const char *lua_result_last_nonempty_line(const char *result, size_t *len_out)
{
    const char *line_start = NULL;
    const char *cursor = NULL;
    const char *last_start = NULL;
    size_t last_len = 0;

    if (len_out) {
        *len_out = 0;
    }
    if (!result || !result[0]) {
        return NULL;
    }

    line_start = result;
    cursor = result;
    while (1) {
        if (*cursor == '\n' || *cursor == '\0') {
            size_t line_len = (size_t)(cursor - line_start);
            if (line_len > 0) {
                last_start = line_start;
                last_len = line_len;
            }
            if (*cursor == '\0') {
                break;
            }
            line_start = cursor + 1;
        }
        cursor++;
    }

    if (len_out) {
        *len_out = last_len;
    }
    return last_start;
}

static void print_lua_run_tail(const char *result, bool is_error)
{
    size_t line_len = 0;
    const char *line = NULL;

    if (!result || !result[0]) {
        return;
    }

    if (!is_error) {
        if (strcmp(result, "Lua script completed with no output.\n") == 0) {
            printf("%s", result);
            return;
        }
        line = strstr(result, "[output truncated]\n");
        if (line) {
            printf("%s", line);
        }
        return;
    }

    /* Prefer the first non-traceback error line; fall back to a short head. */
    {
        const char *nl;
        const char *head = result;
        size_t n;
        while (head && *head) {
            nl = strchr(head, '\n');
            n = nl ? (size_t)(nl - head) : strlen(head);
            if (n > 0 && strncmp(head, "\t/", 2) != 0 && strstr(head, "in main chunk") == NULL) {
                printf("%.*s\n", (int)n, head);
                return;
            }
            head = nl ? nl + 1 : NULL;
        }
    }
    line = lua_result_last_nonempty_line(result, &line_len);
    if (!line || line_len == 0) {
        return;
    }
    printf("%.*s\n", (int)line_len, line);
}

static int lua_func(int argc, char **argv)
{
    int nerrors = arg_parse(argc, argv, (void **)&lua_args);
    int operation_count;
    char *result = NULL;
    esp_err_t err = ESP_OK;
    uint32_t timeout_ms = 0;
    bool sync_run = false;

    if (nerrors != 0) {
        arg_print_errors(stderr, lua_args.end, argv[0]);
        return 1;
    }

    operation_count = lua_args.run->count + lua_args.run_async->count + lua_args.jobs->count +
                      lua_args.job->count + lua_args.eval_b64->count;
    if (operation_count != 1) {
        printf("Exactly one operation must be specified\n");
        return 1;
    }

    result = calloc(1, 4096);
    if (!result) {
        printf("failed to allocate output buffer\n");
        return 1;
    }

    if (lua_args.timeout_ms->count) {
        if (lua_args.timeout_ms->ival[0] <= 0) {
            printf("'--timeout-ms' must be a positive integer\n");
            free(result);
            return 1;
        }
        timeout_ms = (uint32_t)lua_args.timeout_ms->ival[0];
    }

    if (lua_args.eval_b64->count) {
        sync_run = true;
        err = lua_run_eval_b64(lua_args.eval_b64->sval[0],
                               timeout_ms ? timeout_ms : 15000,
                               result) == 0 ? ESP_OK : ESP_FAIL;
    } else if (lua_args.run->count) {
        sync_run = true;
        if (!lua_args.path->count) {
            printf("'--run' requires '--path'\n");
            free(result);
            return 1;
        }
        err = cap_lua_run_script(lua_args.path->sval[0],
                                 lua_args.args_json->count ? lua_args.args_json->sval[0] : NULL,
                                 timeout_ms,
                                 result,
                                 4096);
    } else if (lua_args.run_async->count) {
        if (!lua_args.path->count) {
            printf("'--run-async' requires '--path'\n");
            free(result);
            return 1;
        }
        err = cap_lua_run_script_async(lua_args.path->sval[0],
                                       lua_args.args_json->count ? lua_args.args_json->sval[0] : NULL,
                                       timeout_ms,
                                       NULL,
                                       NULL,
                                       false,
                                       result,
                                       4096);
    } else if (lua_args.jobs->count) {
        err = cap_lua_list_jobs(lua_args.status->count ? lua_args.status->sval[0] : NULL,
                                result,
                                4096);
    } else {
        err = cap_lua_get_job(lua_args.job->sval[0], result, 4096);
    }

    if (err != ESP_OK) {
        if (sync_run) {
            print_lua_run_tail(result, true);
        } else {
            print_lua_result(result);
        }
        printf("lua command failed: %s\n", esp_err_to_name(err));
        free(result);
        return 1;
    }

    if (sync_run) {
        print_lua_run_tail(result, false);
    } else {
        print_lua_result(result);
    }
    free(result);
    return 0;
}

void register_cap_lua(void)
{
    lua_args.run = arg_lit0("r", "run", "Run a managed Lua script synchronously");
    lua_args.run_async = arg_lit0(NULL, "run-async", "Run a managed Lua script asynchronously");
    lua_args.jobs = arg_lit0(NULL, "jobs", "List async Lua jobs");
    lua_args.job = arg_str0(NULL, "job", "<job_id>", "Show one async Lua job");
    lua_args.eval_b64 = arg_str0(NULL, "eval-b64", "<b64>",
                                 "Base64-encoded Lua chunk, written to DATA temp and run");
    lua_args.path = arg_str0("p", "path", "<path>", "Relative Lua file path, for example temp/foo.lua");
    lua_args.args_json = arg_str0(NULL, "args-json", "<json>", "JSON object/array passed to the script");
    lua_args.status = arg_str0(NULL, "status", "<status>", "Job status filter: all|queued|running|done|failed|timeout");
    lua_args.timeout_ms = arg_int0("t", "timeout-ms", "<ms>", "Execution timeout in milliseconds");
    lua_args.end = arg_end(10);

    const esp_console_cmd_t lua_cmd = {
        .command = "lua",
        .help = "Lua script operations.\n"
        "Examples:\n"
        " lua --run --path blink.lua --args-json \"{\\\"pin\\\":2}\" --timeout-ms 3000\n"
        " lua --run-async --path blink.lua\n"
        " lua --eval-b64 cHJpbnQoNDIrMik=\n"
        " lua --jobs --status running\n"
        " lua --job abcdef12\n",
        .func = lua_func,
        .argtable = &lua_args,
    };

    ESP_ERROR_CHECK(esp_console_cmd_register(&lua_cmd));
}
