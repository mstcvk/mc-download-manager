#ifndef CurlBridge_h
#define CurlBridge_h

#include <stddef.h>
#include <stdint.h>

typedef size_t (*mc_curl_write_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);
typedef int (*mc_curl_xferinfo_cb)(void *clientp, int64_t dltotal, int64_t dlnow, int64_t ultotal, int64_t ulnow);

void mc_curl_global_init(void);
void *mc_curl_easy_init(void);
void mc_curl_easy_cleanup(void *handle);

int mc_curl_setopt_url(void *handle, const char *url);
int mc_curl_setopt_interface(void *handle, const char *iface);
int mc_curl_setopt_range(void *handle, const char *range);
int mc_curl_setopt_accept_encoding(void *handle, const char *enc);
int mc_curl_setopt_httpheader(void *handle, void *slist);
int mc_curl_setopt_followlocation(void *handle, long enable);
int mc_curl_setopt_nosignal(void *handle, long enable);
int mc_curl_setopt_ipresolve(void *handle, long mode);
int mc_curl_setopt_connecttimeout(void *handle, long seconds);
int mc_curl_setopt_low_speed(void *handle, long limit_bytes_per_sec, long time_seconds);
int mc_curl_setopt_tcp_keepalive(void *handle, long enable);
int mc_curl_setopt_buffersize(void *handle, long size);
int mc_curl_setopt_noprogress(void *handle, long disable);
int mc_curl_setopt_write_cb(void *handle, mc_curl_write_cb cb, void *userdata);
int mc_curl_setopt_header_cb(void *handle, mc_curl_write_cb cb, void *userdata);
int mc_curl_setopt_xferinfo_cb(void *handle, mc_curl_xferinfo_cb cb, void *userdata);

void *mc_curl_slist_append(void *list, const char *header);
void mc_curl_slist_free_all(void *list);

int mc_curl_easy_perform(void *handle);
long mc_curl_getinfo_response_code(void *handle);
const char *mc_curl_getinfo_effective_url(void *handle);
const char *mc_curl_easy_strerror(int code);

int mc_curl_code_ok(void);
int mc_curl_code_aborted_by_callback(void);
int mc_curl_code_write_error(void);
int mc_curl_code_interface_failed(void);
int mc_curl_code_operation_timedout(void);

#endif /* CurlBridge_h */
