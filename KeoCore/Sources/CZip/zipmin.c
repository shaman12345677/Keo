#include "zipmin.h"
#include <string.h>
#include <zlib.h>

int keo_inflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap, size_t *out_len) {
    z_stream strm;
    if (src_len > 0xffffffffu || dst_cap > 0xffffffffu) return -2;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) return -1;
    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)src_len;
    strm.next_out = dst;
    strm.avail_out = (uInt)dst_cap;
    int rc = inflate(&strm, Z_FINISH);
    *out_len = (size_t)strm.total_out;
    inflateEnd(&strm);
    return rc == Z_STREAM_END ? 0 : -3;
}

int keo_deflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap, size_t *out_len) {
    z_stream strm;
    if (src_len > 0xffffffffu || dst_cap > 0xffffffffu) return -2;
    memset(&strm, 0, sizeof(strm));
    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return -1;
    }
    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)src_len;
    strm.next_out = dst;
    strm.avail_out = (uInt)dst_cap;
    int rc = deflate(&strm, Z_FINISH);
    *out_len = (size_t)strm.total_out;
    deflateEnd(&strm);
    return rc == Z_STREAM_END ? 0 : -3;
}

uint32_t keo_crc32(const uint8_t *src, size_t len) {
    uLong crc = crc32(0L, Z_NULL, 0);
    size_t off = 0;
    while (off < len) {
        size_t chunk = len - off;
        if (chunk > 0xffffffffu) chunk = 0xffffffffu;
        crc = crc32(crc, src + off, (uInt)chunk);
        off += chunk;
    }
    return (uint32_t)crc;
}
