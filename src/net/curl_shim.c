#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

CURLcode curl_shim_global_init(void) {
    return curl_global_init(CURL_GLOBAL_ALL);
}

void curl_shim_global_cleanup(void) {
    curl_global_cleanup();
}

CURL *curl_shim_init(void) {
    return curl_easy_init();
}

void curl_shim_cleanup(CURL *handle) {
    curl_easy_cleanup(handle);
}

CURLcode curl_shim_perform(CURL *handle) {
    return curl_easy_perform(handle);
}

CURLcode curl_shim_setopt_ptr(CURL *handle, CURLoption option, void *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode curl_shim_setopt_long(CURL *handle, CURLoption option, long value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode curl_shim_getinfo_long(CURL *handle, CURLINFO info, long *value) {
    return curl_easy_getinfo(handle, info, value);
}

struct curl_slist *curl_shim_slist_append(struct curl_slist *list, const char *string) {
    return curl_slist_append(list, string);
}

void curl_shim_slist_free_all(struct curl_slist *list) {
    curl_slist_free_all(list);
}

const char *curl_shim_strerror(CURLcode errornum) {
    return curl_easy_strerror(errornum);
}

typedef struct {
    char *data;
    size_t size;
} Buffer;

static size_t write_cb(void *ptr, size_t size, size_t nmemb, void *userdata) {
    size_t realsize = size * nmemb;
    Buffer *mem = (Buffer *)userdata;
    char *ptr_new = realloc(mem->data, mem->size + realsize + 1);
    if (!ptr_new) return 0;
    mem->data = ptr_new;
    memcpy(&(mem->data[mem->size]), ptr, realsize);
    mem->size += realsize;
    mem->data[mem->size] = 0;
    return realsize;
}

CURLcode curl_shim_simple_request(const char *url, const char *method, const char *payload, struct curl_slist *headers, char **response, size_t *response_len) {
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;

    Buffer buf;
    buf.data = malloc(1);
    buf.size = 0;

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    if (headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    if (payload) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(payload));
    }
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    
    // Enable SSL/TLS certificate verification
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);

    CURLcode res = curl_easy_perform(curl);
    if (res == CURLE_OK) {
        *response = buf.data;
        *response_len = buf.size;
    } else {
        free(buf.data);
    }
    curl_easy_cleanup(curl);
    return res;
}
