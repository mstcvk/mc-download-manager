#include "CurlBridge.h"
#include <curl/curl.h>
#include <dispatch/dispatch.h>

void mc_curl_global_init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        curl_global_init(CURL_GLOBAL_DEFAULT);
    });
}

void *mc_curl_easy_init(void) {
    mc_curl_global_init();
    return curl_easy_init();
}

void mc_curl_easy_cleanup(void *handle) {
    if (handle) {
        curl_easy_cleanup((CURL *)handle);
    }
}

int mc_curl_setopt_url(void *handle, const char *url) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_URL, url);
}

int mc_curl_setopt_interface(void *handle, const char *iface) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_INTERFACE, iface);
}

int mc_curl_setopt_range(void *handle, const char *range) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_RANGE, range);
}

int mc_curl_setopt_accept_encoding(void *handle, const char *enc) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_ACCEPT_ENCODING, enc);
}

int mc_curl_setopt_httpheader(void *handle, void *slist) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_HTTPHEADER, (struct curl_slist *)slist);
}

int mc_curl_setopt_followlocation(void *handle, long enable) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_FOLLOWLOCATION, enable);
}

int mc_curl_setopt_nosignal(void *handle, long enable) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_NOSIGNAL, enable);
}

int mc_curl_setopt_connecttimeout(void *handle, long seconds) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_CONNECTTIMEOUT, seconds);
}

int mc_curl_setopt_low_speed(void *handle, long limit_bytes_per_sec, long time_seconds) {
    CURLcode c1 = curl_easy_setopt((CURL *)handle, CURLOPT_LOW_SPEED_LIMIT, limit_bytes_per_sec);
    if (c1 != CURLE_OK) return (int)c1;
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_LOW_SPEED_TIME, time_seconds);
}

int mc_curl_setopt_tcp_keepalive(void *handle, long enable) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_TCP_KEEPALIVE, enable);
}

int mc_curl_setopt_buffersize(void *handle, long size) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_BUFFERSIZE, size);
}

int mc_curl_setopt_noprogress(void *handle, long disable) {
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_NOPROGRESS, disable);
}

int mc_curl_setopt_write_cb(void *handle, mc_curl_write_cb cb, void *userdata) {
    CURLcode c1 = curl_easy_setopt((CURL *)handle, CURLOPT_WRITEFUNCTION, cb);
    if (c1 != CURLE_OK) return (int)c1;
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_WRITEDATA, userdata);
}

int mc_curl_setopt_header_cb(void *handle, mc_curl_write_cb cb, void *userdata) {
    CURLcode c1 = curl_easy_setopt((CURL *)handle, CURLOPT_HEADERFUNCTION, cb);
    if (c1 != CURLE_OK) return (int)c1;
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_HEADERDATA, userdata);
}

int mc_curl_setopt_xferinfo_cb(void *handle, mc_curl_xferinfo_cb cb, void *userdata) {
    CURLcode c1 = curl_easy_setopt((CURL *)handle, CURLOPT_XFERINFOFUNCTION, cb);
    if (c1 != CURLE_OK) return (int)c1;
    return (int)curl_easy_setopt((CURL *)handle, CURLOPT_XFERINFODATA, userdata);
}

void *mc_curl_slist_append(void *list, const char *header) {
    return curl_slist_append((struct curl_slist *)list, header);
}

void mc_curl_slist_free_all(void *list) {
    if (list) {
        curl_slist_free_all((struct curl_slist *)list);
    }
}

int mc_curl_easy_perform(void *handle) {
    return (int)curl_easy_perform((CURL *)handle);
}

long mc_curl_getinfo_response_code(void *handle) {
    long code = 0;
    curl_easy_getinfo((CURL *)handle, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

const char *mc_curl_getinfo_effective_url(void *handle) {
    char *url = NULL;
    if (curl_easy_getinfo((CURL *)handle, CURLINFO_EFFECTIVE_URL, &url) == CURLE_OK) {
        return url;
    }
    return NULL;
}

const char *mc_curl_easy_strerror(int code) {
    return curl_easy_strerror((CURLcode)code);
}

int mc_curl_code_ok(void) { return (int)CURLE_OK; }
int mc_curl_code_aborted_by_callback(void) { return (int)CURLE_ABORTED_BY_CALLBACK; }
int mc_curl_code_write_error(void) { return (int)CURLE_WRITE_ERROR; }
int mc_curl_code_interface_failed(void) { return (int)CURLE_INTERFACE_FAILED; }
int mc_curl_code_operation_timedout(void) { return (int)CURLE_OPERATION_TIMEDOUT; }
