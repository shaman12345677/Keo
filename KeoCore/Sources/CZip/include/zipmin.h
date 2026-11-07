#pragma once
#include <stddef.h>
#include <stdint.h>

int keo_inflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap, size_t *out_len);
int keo_deflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_cap, size_t *out_len);
uint32_t keo_crc32(const uint8_t *src, size_t len);
