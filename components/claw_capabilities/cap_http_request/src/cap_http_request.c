/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "cap_http_request.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "cJSON.h"
#include "claw_cap.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"

static const char *TAG = "cap_http_request";

#define CAP_HTTP_REQUEST_TIMEOUT_MS_DEFAULT 15000
#define CAP_HTTP_REQUEST_MAX_BODY_DEFAULT   (16 * 1024)
#define CAP_HTTP_REQUEST_MAX_BODY_LIMIT     ((64 * 1024) - 1)
#define CAP_HTTP_REQUEST_MULTIPART_MAX      (256 * 1024)
#define CAP_HTTP_REQUEST_MULTIPART_FIELDS   16
#define CAP_HTTP_REQUEST_MULTIPART_FILES    8
#define CAP_HTTP_REQUEST_BOUNDARY_PREFIX    "espclaw"
#define CAP_HTTP_REQUEST_MAX_FILE_LIMIT     2147483647
#define CAP_HTTP_REQUEST_ALLOWLIST_MAX      320
#define CAP_HTTP_REQUEST_REDIRECT_URL_MAX   512

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    size_t max_len;
    FILE *file;
    size_t file_bytes;
    size_t max_file_bytes;
    bool file_write_failed;
    bool truncated;
    bool check_redirect_allowlist;
    char redirect_location[CAP_HTTP_REQUEST_REDIRECT_URL_MAX];
} cap_http_request_buf_t;

typedef struct {
    char allowlist[CAP_HTTP_REQUEST_ALLOWLIST_MAX];
} cap_http_request_state_t;

static EXT_RAM_BSS_ATTR cap_http_request_state_t s_http_request = {0};

static bool cap_http_request_extract_url_host(const char *url, char *host, size_t host_size);
static bool cap_http_request_extract_redirect_host(const char *location,
                                                   esp_http_client_handle_t client,
                                                   char *host, size_t host_size);
static bool cap_http_request_host_allowed(const char *host);

static esp_err_t cap_http_request_event_handler(esp_http_client_event_t *event)
{
    cap_http_request_buf_t *buf = NULL;
    size_t append_len;

    if (!event) {
        return ESP_OK;
    }

    buf = (cap_http_request_buf_t *)event->user_data;

    switch (event->event_id) {
    case HTTP_EVENT_ON_HEADER:
        if (buf && buf->check_redirect_allowlist &&
                event->header_key && event->header_value &&
                strcasecmp(event->header_key, "Location") == 0) {
            strlcpy(buf->redirect_location, event->header_value, sizeof(buf->redirect_location));
        }
        break;

    case HTTP_EVENT_REDIRECT:
        if (buf && buf->check_redirect_allowlist) {
            char host[128] = {0};

            if (!buf->redirect_location[0] ||
                    !cap_http_request_extract_redirect_host(buf->redirect_location, event->client,
                            host, sizeof(host)) ||
                    !cap_http_request_host_allowed(host)) {
                ESP_LOGW(TAG, "Redirect to '%s' blocked by allowlist", buf->redirect_location);
                return ESP_FAIL;
            }
            ESP_LOGI(TAG, "Redirect to host '%s' allowed by allowlist", host);
            buf->redirect_location[0] = '\0';
            return esp_http_client_set_redirection(event->client);
        }
        break;

    case HTTP_EVENT_ON_DATA:
        if (!buf || event->data_len <= 0) {
            break;
        }
        append_len = (size_t)event->data_len;

        if (buf->file) {
            size_t write_len = append_len;

            if (buf->max_file_bytes > 0) {
                if (buf->file_bytes >= buf->max_file_bytes) {
                    buf->truncated = true;
                    break;
                }
                if (write_len > buf->max_file_bytes - buf->file_bytes) {
                    write_len = buf->max_file_bytes - buf->file_bytes;
                    buf->truncated = true;
                }
            }
            if (write_len > 0 && fwrite(event->data, 1, write_len, buf->file) != write_len) {
                buf->file_write_failed = true;
                return ESP_FAIL;
            }
            buf->file_bytes += write_len;
            break;
        }

        if (!buf->data) {
            break;
        }
        if (buf->max_len > 0 && buf->len + append_len > buf->max_len) {
            if (buf->len >= buf->max_len) {
                buf->truncated = true;
                break;
            }
            append_len = buf->max_len - buf->len;
            buf->truncated = true;
        }
        if (buf->len + append_len + 1 > buf->cap) {
            size_t new_cap = buf->cap * 2;
            char *new_data = NULL;

            if (new_cap < buf->len + append_len + 1) {
                new_cap = buf->len + append_len + 1;
            }
            new_data = realloc(buf->data, new_cap);
            if (!new_data) {
                return ESP_ERR_NO_MEM;
            }
            buf->data = new_data;
            buf->cap = new_cap;
        }
        memcpy(buf->data + buf->len, event->data, append_len);
        buf->len += append_len;
        buf->data[buf->len] = '\0';
        break;

    default:
        break;
    }

    return ESP_OK;
}

static bool cap_http_request_is_valid_method(const char *method, esp_http_client_method_t *out_method)
{
    if (!method || !method[0]) {
        *out_method = HTTP_METHOD_GET;
        return true;
    }

    if (strcasecmp(method, "GET") == 0) {
        *out_method = HTTP_METHOD_GET;
        return true;
    }
    if (strcasecmp(method, "POST") == 0) {
        *out_method = HTTP_METHOD_POST;
        return true;
    }
    if (strcasecmp(method, "PUT") == 0) {
        *out_method = HTTP_METHOD_PUT;
        return true;
    }
    if (strcasecmp(method, "PATCH") == 0) {
        *out_method = HTTP_METHOD_PATCH;
        return true;
    }
    if (strcasecmp(method, "DELETE") == 0) {
        *out_method = HTTP_METHOD_DELETE;
        return true;
    }
    if (strcasecmp(method, "HEAD") == 0) {
        *out_method = HTTP_METHOD_HEAD;
        return true;
    }

    return false;
}

static bool cap_http_request_extract_url_host(const char *url, char *host, size_t host_size)
{
    const char *scheme = NULL;
    const char *authority = NULL;
    const char *authority_end = NULL;
    const char *start = NULL;
    const char *at = NULL;
    const char *host_end = NULL;
    size_t host_len = 0;

    if (!url || !host || host_size == 0) {
        return false;
    }
    host[0] = '\0';

    scheme = strstr(url, "://");
    if (!scheme || (strncasecmp(url, "http://", 7) != 0 && strncasecmp(url, "https://", 8) != 0)) {
        return false;
    }
    authority = scheme + 3;
    authority_end = authority + strcspn(authority, "/?#");
    if (authority >= authority_end) {
        return false;
    }

    start = authority;
    for (const char *p = authority; p < authority_end; p++) {
        if (*p == '@') {
            at = p;
        }
    }
    if (at) {
        start = at + 1;
    }

    if (start >= authority_end) {
        return false;
    }

    if (*start == '[') {
        const char *closing = NULL;
        for (const char *p = start + 1; p < authority_end; p++) {
            if (*p == ']') {
                closing = p;
                break;
            }
        }
        if (!closing || closing == start + 1) {
            return false;
        }
        host_len = (size_t)(closing - (start + 1));
        if (host_len + 1 > host_size) {
            return false;
        }
        memcpy(host, start + 1, host_len);
        host[host_len] = '\0';
        return true;
    }

    host_end = start;
    while (host_end < authority_end && *host_end != ':') {
        host_end++;
    }
    if (host_end <= start) {
        return false;
    }
    host_len = (size_t)(host_end - start);
    if (host_len + 1 > host_size) {
        return false;
    }
    memcpy(host, start, host_len);
    host[host_len] = '\0';
    return true;
}

static bool cap_http_request_extract_redirect_host(const char *location,
                                                   esp_http_client_handle_t client,
                                                   char *host, size_t host_size)
{
    char current_url[CAP_HTTP_REQUEST_REDIRECT_URL_MAX];
    char protocol_relative_url[CAP_HTTP_REQUEST_REDIRECT_URL_MAX + 8];

    if (!location || !location[0] || !host || host_size == 0) {
        return false;
    }

    if (cap_http_request_extract_url_host(location, host, host_size)) {
        return true;
    }

    if (location[0] == '/' && location[1] == '/') {
        if (snprintf(protocol_relative_url, sizeof(protocol_relative_url), "https:%s", location) >=
                (int)sizeof(protocol_relative_url)) {
            return false;
        }
        return cap_http_request_extract_url_host(protocol_relative_url, host, host_size);
    }

    if (!client) {
        return false;
    }

    if (esp_http_client_get_url(client, current_url, sizeof(current_url)) != ESP_OK) {
        return false;
    }

    return cap_http_request_extract_url_host(current_url, host, host_size);
}

static bool cap_http_request_host_matches_allowlist_token(const char *host, const char *token)
{
    size_t host_len;
    size_t token_len;

    if (!host || !token || !host[0] || !token[0]) {
        return false;
    }

    host_len = strlen(host);
    token_len = strlen(token);

    if (token_len == 1 && token[0] == '*') {
        return true;
    }

    if (token_len >= 3 && token[0] == '*' && token[1] == '.') {
        const char *base = token + 2;
        const char *suffix = token + 1;
        size_t suffix_len = token_len - 1;

        if (strcasecmp(host, base) == 0) {
            return true;
        }
        return host_len > suffix_len &&
               strcasecmp(host + host_len - suffix_len, suffix) == 0;
    }

    if (token[0] == '.') {
        const char *exact = token + 1;
        size_t token_with_dot_len = token_len;

        if (strcasecmp(host, exact) == 0) {
            return true;
        }
        return host_len > token_with_dot_len &&
               strcasecmp(host + host_len - token_with_dot_len, token) == 0;
    }

    return strcasecmp(host, token) == 0;
}

static bool cap_http_request_host_allowed(const char *host)
{
    char allowlist_copy[CAP_HTTP_REQUEST_ALLOWLIST_MAX];
    char *saveptr = NULL;
    char *token = NULL;

    if (!host || !host[0] || !s_http_request.allowlist[0]) {
        return false;
    }

    strlcpy(allowlist_copy, s_http_request.allowlist, sizeof(allowlist_copy));
    for (token = strtok_r(allowlist_copy, ",", &saveptr);
            token;
            token = strtok_r(NULL, ",", &saveptr)) {
        char *start = token;
        char *end = NULL;

        while (*start == ' ' || *start == '\t' || *start == '\r' || *start == '\n') {
            start++;
        }
        end = start + strlen(start);
        while (end > start &&
                (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) {
            end--;
        }
        *end = '\0';
        if (!start[0]) {
            continue;
        }
        if (start[0] == '[' && end > start + 1 && end[-1] == ']') {
            start++;
            end[-1] = '\0';
        }
        if (cap_http_request_host_matches_allowlist_token(host, start)) {
            return true;
        }
    }

    return false;
}

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} cap_http_multipart_buf_t;

static bool cap_http_multipart_reserve(cap_http_multipart_buf_t *buf, size_t extra)
{
    size_t need;
    size_t new_cap;
    char *grown;

    if (!buf) {
        return false;
    }
    need = buf->len + extra + 1;
    if (need > CAP_HTTP_REQUEST_MULTIPART_MAX) {
        return false;
    }
    if (need <= buf->cap) {
        return true;
    }
    new_cap = buf->cap ? buf->cap : 1024;
    while (new_cap < need) {
        if (new_cap >= CAP_HTTP_REQUEST_MULTIPART_MAX / 2) {
            new_cap = CAP_HTTP_REQUEST_MULTIPART_MAX;
            break;
        }
        new_cap *= 2;
    }
    grown = realloc(buf->data, new_cap);
    if (!grown) {
        return false;
    }
    buf->data = grown;
    buf->cap = new_cap;
    return true;
}

static bool cap_http_multipart_append(cap_http_multipart_buf_t *buf, const void *data, size_t len)
{
    if (len == 0) {
        return true;
    }
    if (!data || !cap_http_multipart_reserve(buf, len)) {
        return false;
    }
    memcpy(buf->data + buf->len, data, len);
    buf->len += len;
    buf->data[buf->len] = '\0';
    return true;
}

static bool cap_http_multipart_append_str(cap_http_multipart_buf_t *buf, const char *text)
{
    return cap_http_multipart_append(buf, text, text ? strlen(text) : 0);
}

static bool cap_http_multipart_append_file(cap_http_multipart_buf_t *buf, const char *path)
{
    FILE *file;
    char chunk[1024];
    size_t n;

    file = fopen(path, "rb");
    if (!file) {
        return false;
    }
    while ((n = fread(chunk, 1, sizeof(chunk), file)) > 0) {
        if (!cap_http_multipart_append(buf, chunk, n)) {
            fclose(file);
            return false;
        }
    }
    fclose(file);
    return true;
}

/*
 * Build multipart/form-data body from:
 *   multipart.fields: { name: value, ... }  (text fields)
 *   multipart.files:  [ { name, path, filename?, content_type? }, ... ]
 */
static char *cap_http_request_build_multipart(const cJSON *multipart,
                                              const char *boundary,
                                              size_t *out_len,
                                              const char **out_error)
{
    cap_http_multipart_buf_t body = {0};
    const cJSON *fields = NULL;
    const cJSON *files = NULL;
    const cJSON *item = NULL;
    int file_count = 0;
    int field_count = 0;
    char line[512];

    *out_len = 0;
    *out_error = NULL;

    if (!cJSON_IsObject(multipart)) {
        *out_error = "multipart must be an object";
        return NULL;
    }
    fields = cJSON_GetObjectItem(multipart, "fields");
    files = cJSON_GetObjectItem(multipart, "files");
    if (fields && !cJSON_IsObject(fields)) {
        *out_error = "multipart.fields must be an object";
        return NULL;
    }
    if (files && !cJSON_IsArray(files)) {
        *out_error = "multipart.files must be an array";
        return NULL;
    }

    if (fields) {
        cJSON_ArrayForEach(item, fields) {
            if (!item->string || !cJSON_IsString(item) || !item->valuestring) {
                *out_error = "multipart.fields values must be strings";
                goto fail;
            }
            field_count++;
            if (field_count > CAP_HTTP_REQUEST_MULTIPART_FIELDS) {
                *out_error = "too many multipart fields";
                goto fail;
            }
            snprintf(line, sizeof(line), "--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n",
                     boundary, item->string);
            if (!cap_http_multipart_append_str(&body, line) ||
                    !cap_http_multipart_append_str(&body, item->valuestring) ||
                    !cap_http_multipart_append_str(&body, "\r\n")) {
                *out_error = "multipart body too large";
                goto fail;
            }
        }
    }

    if (files) {
        cJSON_ArrayForEach(item, files) {
            const cJSON *name_item;
            const cJSON *path_item;
            const cJSON *filename_item;
            const cJSON *ctype_item;
            const char *name;
            const char *path;
            const char *filename;
            const char *ctype;

            if (!cJSON_IsObject(item)) {
                *out_error = "multipart.files entries must be objects";
                goto fail;
            }
            file_count++;
            if (file_count > CAP_HTTP_REQUEST_MULTIPART_FILES) {
                *out_error = "too many multipart files";
                goto fail;
            }
            name_item = cJSON_GetObjectItem(item, "name");
            path_item = cJSON_GetObjectItem(item, "path");
            filename_item = cJSON_GetObjectItem(item, "filename");
            ctype_item = cJSON_GetObjectItem(item, "content_type");
            if (!cJSON_IsString(name_item) || !name_item->valuestring[0] ||
                    !cJSON_IsString(path_item) || !path_item->valuestring[0]) {
                *out_error = "multipart.files entries require name and path";
                goto fail;
            }
            name = name_item->valuestring;
            path = path_item->valuestring;
            filename = (cJSON_IsString(filename_item) && filename_item->valuestring[0])
                       ? filename_item->valuestring : path;
            ctype = (cJSON_IsString(ctype_item) && ctype_item->valuestring[0])
                    ? ctype_item->valuestring : "application/octet-stream";

            snprintf(line, sizeof(line),
                     "--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n",
                     boundary, name, filename, ctype);
            if (!cap_http_multipart_append_str(&body, line) ||
                    !cap_http_multipart_append_file(&body, path) ||
                    !cap_http_multipart_append_str(&body, "\r\n")) {
                *out_error = "multipart file missing or body too large";
                goto fail;
            }
        }
    }

    if (field_count == 0 && file_count == 0) {
        *out_error = "multipart requires fields and/or files";
        goto fail;
    }

    snprintf(line, sizeof(line), "--%s--\r\n", boundary);
    if (!cap_http_multipart_append_str(&body, line)) {
        *out_error = "multipart body too large";
        goto fail;
    }

    *out_len = body.len;
    return body.data;

fail:
    free(body.data);
    return NULL;
}

static esp_err_t cap_http_request_execute(const char *input_json,
                                          const claw_cap_call_context_t *ctx,
                                          char *output,
                                          size_t output_size)
{
    cJSON *input = NULL;
    cJSON *url_item = NULL;
    cJSON *method_item = NULL;
    cJSON *headers_item = NULL;
    cJSON *body_item = NULL;
    cJSON *multipart_item = NULL;
    cJSON *timeout_item = NULL;
    cJSON *max_body_item = NULL;
    cJSON *save_path_item = NULL;
    cJSON *max_file_item = NULL;
    cap_http_request_buf_t buf = {0};
    esp_http_client_config_t config = {0};
    esp_http_client_handle_t client = NULL;
    esp_http_client_method_t method = HTTP_METHOD_GET;
    esp_err_t err = ESP_OK;
    int status = 0;
    int timeout_ms = CAP_HTTP_REQUEST_TIMEOUT_MS_DEFAULT;
    int max_body_bytes = CAP_HTTP_REQUEST_MAX_BODY_DEFAULT;
    int max_file_bytes = 0;
    const char *save_path = NULL;
    char *save_path_copy = NULL;
    char *tmp_save_path = NULL;
    char *multipart_body = NULL;
    size_t multipart_len = 0;
    char multipart_boundary[48];
    char multipart_ctype[80];
    const char *multipart_error = NULL;
    char host[128] = {0};

    (void)ctx;

    if (!output || output_size == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    if (!s_http_request.allowlist[0]) {
        snprintf(output, output_size,
                 "Error: HTTP allowlist is empty; configure search_http_allowlist first");
        return ESP_ERR_INVALID_STATE;
    }

    input = cJSON_Parse(input_json);
    if (!input) {
        snprintf(output, output_size, "Error: invalid input JSON");
        return ESP_ERR_INVALID_ARG;
    }

    url_item = cJSON_GetObjectItem(input, "url");
    method_item = cJSON_GetObjectItem(input, "method");
    headers_item = cJSON_GetObjectItem(input, "headers");
    body_item = cJSON_GetObjectItem(input, "body");
    multipart_item = cJSON_GetObjectItem(input, "multipart");
    timeout_item = cJSON_GetObjectItem(input, "timeout_ms");
    max_body_item = cJSON_GetObjectItem(input, "max_body_bytes");
    save_path_item = cJSON_GetObjectItem(input, "save_path");
    max_file_item = cJSON_GetObjectItem(input, "max_file_bytes");

    if (!cJSON_IsString(url_item) || !url_item->valuestring || !url_item->valuestring[0]) {
        cJSON_Delete(input);
        snprintf(output, output_size, "Error: missing url");
        return ESP_ERR_INVALID_ARG;
    }
    if (strncasecmp(url_item->valuestring, "http://", 7) != 0 &&
            strncasecmp(url_item->valuestring, "https://", 8) != 0) {
        cJSON_Delete(input);
        snprintf(output, output_size, "Error: url must start with http:// or https://");
        return ESP_ERR_INVALID_ARG;
    }
    if (!cap_http_request_extract_url_host(url_item->valuestring, host, sizeof(host))) {
        cJSON_Delete(input);
        snprintf(output, output_size, "Error: invalid url host");
        return ESP_ERR_INVALID_ARG;
    }
    if (!cap_http_request_host_allowed(host)) {
        cJSON_Delete(input);
        snprintf(output, output_size, "Error: host '%s' is not in allowlist", host);
        return ESP_ERR_INVALID_STATE;
    }
    if (method_item && (!cJSON_IsString(method_item) ||
                        !cap_http_request_is_valid_method(method_item->valuestring, &method))) {
        cJSON_Delete(input);
        snprintf(output, output_size, "Error: method must be GET/POST/PUT/PATCH/DELETE/HEAD");
        return ESP_ERR_INVALID_ARG;
    }
    if (timeout_item) {
        if (!cJSON_IsNumber(timeout_item) ||
                timeout_item->valueint <= 0 ||
                timeout_item->valueint > 120000) {
            cJSON_Delete(input);
            snprintf(output, output_size, "Error: timeout_ms must be an integer in [1, 120000]");
            return ESP_ERR_INVALID_ARG;
        }
        timeout_ms = timeout_item->valueint;
    }
    if (max_body_item) {
        if (!cJSON_IsNumber(max_body_item) ||
                max_body_item->valueint <= 0 ||
                max_body_item->valueint > CAP_HTTP_REQUEST_MAX_BODY_LIMIT) {
            cJSON_Delete(input);
            snprintf(output,
                     output_size,
                     "Error: max_body_bytes must be an integer in [1, %d]",
                     CAP_HTTP_REQUEST_MAX_BODY_LIMIT);
            return ESP_ERR_INVALID_ARG;
        }
        max_body_bytes = max_body_item->valueint;
    }
    if (save_path_item) {
        if (!cJSON_IsString(save_path_item) ||
                !save_path_item->valuestring ||
                !save_path_item->valuestring[0]) {
            cJSON_Delete(input);
            snprintf(output, output_size, "Error: save_path must be a non-empty string");
            return ESP_ERR_INVALID_ARG;
        }
        save_path = save_path_item->valuestring;
        save_path_copy = strdup(save_path);
        if (!save_path_copy) {
            cJSON_Delete(input);
            snprintf(output, output_size, "Error: out of memory");
            return ESP_ERR_NO_MEM;
        }
    }
    if (max_file_item) {
        if (!save_path) {
            cJSON_Delete(input);
            free(tmp_save_path);
            free(save_path_copy);
            snprintf(output, output_size, "Error: max_file_bytes requires save_path");
            return ESP_ERR_INVALID_ARG;
        }
        if (!cJSON_IsNumber(max_file_item) ||
                max_file_item->valueint <= 0 ||
                max_file_item->valueint > CAP_HTTP_REQUEST_MAX_FILE_LIMIT) {
            cJSON_Delete(input);
            free(tmp_save_path);
            free(save_path_copy);
            snprintf(output,
                     output_size,
                     "Error: max_file_bytes must be an integer in [1, %d]",
                     CAP_HTTP_REQUEST_MAX_FILE_LIMIT);
            return ESP_ERR_INVALID_ARG;
        }
        max_file_bytes = max_file_item->valueint;
    }
    if (body_item && !cJSON_IsString(body_item)) {
        cJSON_Delete(input);
        free(tmp_save_path);
        free(save_path_copy);
        snprintf(output, output_size, "Error: body must be a string");
        return ESP_ERR_INVALID_ARG;
    }
    if (headers_item && !cJSON_IsObject(headers_item)) {
        cJSON_Delete(input);
        free(tmp_save_path);
        free(save_path_copy);
        snprintf(output, output_size, "Error: headers must be an object");
        return ESP_ERR_INVALID_ARG;
    }
    if (body_item && multipart_item) {
        cJSON_Delete(input);
        free(tmp_save_path);
        free(save_path_copy);
        snprintf(output, output_size, "Error: body and multipart are mutually exclusive");
        return ESP_ERR_INVALID_ARG;
    }
    if (body_item &&
            (method == HTTP_METHOD_GET || method == HTTP_METHOD_HEAD) &&
            body_item->valuestring &&
            body_item->valuestring[0]) {
        cJSON_Delete(input);
        free(tmp_save_path);
        free(save_path_copy);
        snprintf(output, output_size, "Error: GET/HEAD does not accept body");
        return ESP_ERR_INVALID_ARG;
    }
    if (multipart_item && (method == HTTP_METHOD_GET || method == HTTP_METHOD_HEAD)) {
        cJSON_Delete(input);
        free(tmp_save_path);
        free(save_path_copy);
        snprintf(output, output_size, "Error: GET/HEAD does not accept multipart");
        return ESP_ERR_INVALID_ARG;
    }
    if (multipart_item) {
        snprintf(multipart_boundary, sizeof(multipart_boundary),
                 "%s-%08lx%04x",
                 CAP_HTTP_REQUEST_BOUNDARY_PREFIX,
                 (unsigned long)esp_timer_get_time(),
                 (unsigned)(esp_random() & 0xffff));
        multipart_body = cap_http_request_build_multipart(multipart_item,
                                                          multipart_boundary,
                                                          &multipart_len,
                                                          &multipart_error);
        if (!multipart_body) {
            cJSON_Delete(input);
            free(tmp_save_path);
            free(save_path_copy);
            snprintf(output, output_size, "Error: %s",
                     multipart_error ? multipart_error : "failed to build multipart body");
            return ESP_ERR_INVALID_ARG;
        }
        snprintf(multipart_ctype, sizeof(multipart_ctype),
                 "multipart/form-data; boundary=%s", multipart_boundary);
    }

    if (save_path_copy) {
        size_t tmp_path_len = strlen(save_path_copy) + sizeof(".tmp");

        tmp_save_path = malloc(tmp_path_len);
        if (!tmp_save_path) {
            cJSON_Delete(input);
            free(multipart_body);
            free(save_path_copy);
            snprintf(output, output_size, "Error: out of memory");
            return ESP_ERR_NO_MEM;
        }
        snprintf(tmp_save_path, tmp_path_len, "%s.tmp", save_path_copy);

        buf.file = fopen(tmp_save_path, "wb");
        if (!buf.file) {
            cJSON_Delete(input);
            free(multipart_body);
            free(tmp_save_path);
            free(save_path_copy);
            snprintf(output, output_size, "Error: failed to open save_path");
            return ESP_FAIL;
        }
        buf.max_file_bytes = (size_t)max_file_bytes;
    } else {
        buf.cap = ((size_t)max_body_bytes + 1 < 4096) ? (size_t)max_body_bytes + 1 : 4096;
        buf.data = calloc(1, buf.cap);
        if (!buf.data) {
            cJSON_Delete(input);
            free(multipart_body);
            snprintf(output, output_size, "Error: out of memory");
            return ESP_ERR_NO_MEM;
        }
        buf.max_len = (size_t)max_body_bytes;
    }
    buf.check_redirect_allowlist = true;

    config.url = url_item->valuestring;
    config.event_handler = cap_http_request_event_handler;
    config.user_data = &buf;
    config.timeout_ms = timeout_ms;
    config.buffer_size = 4096;
    config.crt_bundle_attach = esp_crt_bundle_attach;
    config.disable_auto_redirect = true;

    client = esp_http_client_init(&config);
    if (!client) {
        cJSON_Delete(input);
        if (buf.file) {
            fclose(buf.file);
        }
        if (tmp_save_path) {
            remove(tmp_save_path);
        }
        free(buf.data);
        free(multipart_body);
        free(tmp_save_path);
        free(save_path_copy);
        snprintf(output, output_size, "Error: failed to init HTTP client");
        return ESP_FAIL;
    }

    esp_http_client_set_method(client, method);
    if (headers_item) {
        cJSON *header = NULL;

        cJSON_ArrayForEach(header, headers_item) {
            if (header->string && cJSON_IsString(header) && header->valuestring) {
                esp_http_client_set_header(client, header->string, header->valuestring);
            }
        }
    }
    if (multipart_body) {
        /* Override only if caller did not set Content-Type explicitly. */
        if (!headers_item || !cJSON_GetObjectItem(headers_item, "Content-Type")) {
            esp_http_client_set_header(client, "Content-Type", multipart_ctype);
        }
        esp_http_client_set_post_field(client, multipart_body, (int)multipart_len);
    } else if (body_item && body_item->valuestring) {
        esp_http_client_set_post_field(client, body_item->valuestring, strlen(body_item->valuestring));
    }

    err = esp_http_client_perform(client);
    status = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);
    cJSON_Delete(input);
    free(multipart_body);
    if (buf.file && fclose(buf.file) != 0 && err == ESP_OK) {
        buf.file_write_failed = true;
        err = ESP_FAIL;
    }
    buf.file = NULL;

    if (err != ESP_OK) {
        if (tmp_save_path) {
            remove(tmp_save_path);
        }
        free(buf.data);
        snprintf(output,
                 output_size,
                 "Error: %s (%s)",
                 buf.file_write_failed ? "failed to write response file" : "http request failed",
                 esp_err_to_name(err));
        free(tmp_save_path);
        free(save_path_copy);
        return err;
    }

    if (save_path_copy) {
        if (rename(tmp_save_path, save_path_copy) != 0) {
            remove(save_path_copy);
            if (rename(tmp_save_path, save_path_copy) != 0) {
                remove(tmp_save_path);
                free(buf.data);
                free(tmp_save_path);
                free(save_path_copy);
                snprintf(output, output_size, "Error: failed to finalize save_path");
                return ESP_FAIL;
            }
        }
        snprintf(output,
                 output_size,
                 "HTTP %d%s\nSaved response body to %s (%zu bytes)",
                 status,
                 buf.truncated ? " (file truncated)" : "",
                 save_path_copy,
                 buf.file_bytes);
    } else {
        snprintf(output,
                 output_size,
                 "HTTP %d%s\n%s",
                 status,
                 buf.truncated ? " (body truncated)" : "",
                 buf.data ? buf.data : "");
    }
    free(buf.data);
    free(tmp_save_path);
    free(save_path_copy);
    return ESP_OK;
}

static const claw_cap_descriptor_t s_http_request_descriptors[] = {
    {
        .id = "http_request",
        .name = "http_request",
        .family = "system",
        .description = "Call a standard HTTP endpoint with allowlist protection.",
        .kind = CLAW_CAP_KIND_CALLABLE,
        .cap_flags = CLAW_CAP_FLAG_CALLABLE_BY_LLM,
        .input_schema_json =
        "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},"
        "\"method\":{\"type\":\"string\",\"enum\":[\"GET\",\"POST\",\"PUT\",\"PATCH\",\"DELETE\",\"HEAD\"]},"
        "\"headers\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}},"
        "\"body\":{\"type\":\"string\"},"
        "\"multipart\":{\"type\":\"object\",\"properties\":{"
        "\"fields\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}},"
        "\"files\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{"
        "\"name\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},"
        "\"filename\":{\"type\":\"string\"},\"content_type\":{\"type\":\"string\"}},"
        "\"required\":[\"name\",\"path\"]}}}},"
        "\"save_path\":{\"type\":\"string\"},"
        "\"timeout_ms\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":120000},"
        "\"max_body_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":65535},"
        "\"max_file_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":2147483647}},"
        "\"required\":[\"url\"]}",
        .execute = cap_http_request_execute,
    },
};

static const claw_cap_group_t s_http_request_group = {
    .group_id = "cap_http_request",
    .descriptors = s_http_request_descriptors,
    .descriptor_count = sizeof(s_http_request_descriptors) / sizeof(s_http_request_descriptors[0]),
};

esp_err_t cap_http_request_register_group(void)
{
    if (claw_cap_group_exists(s_http_request_group.group_id)) {
        return ESP_OK;
    }

    return claw_cap_register_group(&s_http_request_group);
}

esp_err_t cap_http_request_set_allowlist(const char *allowlist_csv)
{
    if (!allowlist_csv) {
        return ESP_ERR_INVALID_ARG;
    }

    strlcpy(s_http_request.allowlist, allowlist_csv, sizeof(s_http_request.allowlist));
    return ESP_OK;
}
