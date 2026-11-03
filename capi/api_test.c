/* Checks the C interface against include/blockcodec.h: versions, structure sizes, integer and float round trips,
   stream details, damaged, refused and float streams from vectors/, and argument checks. Exit status 1 on a failure. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blockcodec.h"

static int failures = 0;

static void check(int ok, const char *what) {
  if (!ok) {
    printf("  C interface: %s FAILED\n", what);
    failures++;
  }
}

static uint8_t *load(const char *path, int64_t *length) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  *length = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *b = malloc((size_t)*length);
  if (b && fread(b, 1, (size_t)*length, f) != (size_t)*length) {
    free(b);
    b = NULL;
  }
  fclose(f);
  return b;
}

static int decode_file(const char *path, blkc_damage *d) {
  int64_t length;
  uint8_t *s = load(path, &length);
  if (!s) return -100;
  int32_t *x = malloc(sizeof(int32_t) * 1000000);
  int r = blkc_decode(s, length, x, 1000000 / 8, d);
  free(x);
  free(s);
  return r;
}

static int decode_float_file(const char *path, blkc_damage *d) {
  int64_t length;
  uint8_t *s = load(path, &length);
  if (!s) return -100;
  float *x = malloc(sizeof(float) * 1000000);
  int r = blkc_decode_float(s, length, x, 1000000 / 8, d);
  free(x);
  free(s);
  return r;
}

/* Code float samples and decode them again; 1 when every bit pattern comes back and the integer decoder refuses them. */
static int float_round_trip(const float *x, int64_t frames, int channels) {
  blkc_info info = {channels, 48000, 32, 32, frames, 0, 1, {0}};
  int64_t bound = blkc_encode_bound(frames, channels);
  size_t count = (size_t)(frames * channels);
  uint8_t *s = malloc((size_t)bound);
  float *y = malloc(sizeof(float) * count);
  int32_t *z = malloc(sizeof(int32_t) * count);
  blkc_damage d;
  int64_t n = blkc_encode_float(x, &info, 2, 0, s, bound);
  int ok = n > 0 && blkc_decode_float(s, n, y, frames, &d) == BLKC_OK && d.audio_md5 == 1 &&
           memcmp(x, y, sizeof(float) * count) == 0 && blkc_decode(s, n, z, frames, &d) == BLKC_UNSUPPORTED;
  free(z);
  free(y);
  free(s);
  return ok;
}

int main(void) {
  check(blkc_api_version() == BLKC_API_VERSION && BLKC_API_VERSION == 1, "API version");
  check(blkc_format_version() == BLKC_FORMAT_VERSION && BLKC_FORMAT_VERSION == 2, "format version");
  check(sizeof(blkc_info) == 48 && sizeof(blkc_damage) == 24, "structure sizes");

  enum { frames = 20000, channels = 2 };
  int32_t *x = malloc(sizeof(int32_t) * frames * channels), *y = malloc(sizeof(int32_t) * frames * channels);
  uint32_t seed = 1;
  for (int i = 0; i < frames; i++) {
    seed = seed * 1103515245u + 12345u;
    int noise = (int)((seed >> 16) % 201) - 100;
    x[2 * i] = (int32_t)(12000.0 * sin(i * 0.031)) + noise;
    x[2 * i + 1] = (int32_t)(9000.0 * sin(i * 0.017 + 1.0)) - noise;
  }
  blkc_info info = {channels, 44100, 16, 16, frames, 3, 0, {0}};
  int64_t bound = blkc_encode_bound(frames, channels);
  uint8_t *a = malloc((size_t)bound), *b = malloc((size_t)bound);
  int64_t la = blkc_encode(x, &info, 2, 1, a, bound), lb = blkc_encode(x, &info, 2, 0, b, bound);
  check(la > 0 && la < (int64_t)sizeof(int32_t) * frames * channels / 2, "encode");
  check(la == lb && memcmp(a, b, (size_t)la) == 0, "same stream on one thread and on every processor");

  blkc_info got;
  check(blkc_read_info(a, la, &got) == BLKC_OK && got.channels == channels && got.rate == 44100 && got.depth == 16 &&
            got.valid_bits == 16 && got.frames == frames && got.channel_mask == 3 && got.is_float == 0,
        "read info");
  blkc_damage d;
  check(blkc_decode(a, la, y, frames, &d) == BLKC_OK && memcmp(x, y, sizeof(int32_t) * frames * channels) == 0 &&
            d.lost_frames == 0 && d.bad_groups == 0 && d.blocks_ok == 1 && d.audio_md5 == 1,
        "round trip");

  check(blkc_decode_float(a, la, (float *)y, frames, &d) == BLKC_UNSUPPORTED, "integer stream refused as float");
  enum { float_frames = 12000 };
  float *f = malloc(sizeof(float) * float_frames * 2);
  for (int i = 0; i < float_frames * 2; i++) f[i] = (float)(0.4 * sin(i * 0.013) + 0.001 * cos(i * 1.7));
  check(float_round_trip(f, float_frames, 2), "float round trip, bit patterns");
  for (int i = 0; i < float_frames * 2; i++) f[i] = (float)((i * 37) % 65536 - 32768) / 32768.0f;
  check(float_round_trip(f, float_frames, 2), "float round trip, integers over a power of two");
  f[5] = NAN;
  f[9] = INFINITY;
  f[11] = -0.0f;
  check(float_round_trip(f, float_frames, 2), "float round trip, NaN, infinity and negative zero");
  free(f);
  check(decode_float_file("../vectors/float_patterns.blkc", &d) == BLKC_OK && d.audio_md5 == 1, "float vector");

  a[la / 2] ^= 0x10;
  check(blkc_decode(a, la, y, frames, &d) == BLKC_DAMAGED, "changed byte reported as damage");
  check(decode_file("../vectors/damaged_group_sync.blkc", &d) == BLKC_DAMAGED && d.lost_frames > 0 && d.bad_groups == 1,
        "damaged vector");
  check(decode_file("../vectors/not_a_stream.blkc", &d) == BLKC_REFUSED, "refused vector");
  check(decode_file("../vectors/float_patterns.blkc", &d) == BLKC_UNSUPPORTED, "float vector refused as integer");
  check(blkc_decode(a, la, y, frames - 1, &d) == BLKC_BAD_ARGUMENT, "small output capacity");

  check(blkc_encode(x, &info, 6, 1, b, bound) == BLKC_BAD_ARGUMENT, "level out of range");
  check(blkc_encode(x, &info, 2, 1, b, 100) == BLKC_BAD_ARGUMENT, "small stream capacity");
  x[7] = 40000;
  check(blkc_encode(x, &info, 2, 1, b, bound) == BLKC_BAD_ARGUMENT, "sample outside depth");
  check(blkc_encode_bound(-1, 2) == BLKC_BAD_ARGUMENT && blkc_encode_bound(10, 9) == BLKC_BAD_ARGUMENT, "bound arguments");

  free(x);
  free(y);
  free(a);
  free(b);
  if (failures == 0) printf("  C interface: versions, layout, integer and float round trips, damage and arguments as declared\n");
  return failures != 0;
}
