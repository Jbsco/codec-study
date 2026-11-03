/* Checks the C interface against include/blockcodec.h: versions, structure sizes, integer and float round trips,
   stream details, damaged, refused and float streams from vectors/, ranges, the decoder handle's reads and seeks, and
   argument checks. Exit status 1 on a failure. */
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

/* Decode ranges of a vector, as integers or as floats, and compare each with the same frames of a full decode. */
static int ranges_match(const char *path, int is_float) {
  int64_t length;
  uint8_t *s = load(path, &length);
  blkc_info info;
  if (!s || blkc_read_info(s, length, &info) != BLKC_OK) {
    free(s);
    return 0;
  }
  size_t n = (size_t)(info.frames * info.channels);
  int32_t *all = malloc(sizeof(int32_t) * n), *part = malloc(sizeof(int32_t) * n);
  blkc_damage d;
  int ok = (is_float ? blkc_decode_float(s, length, (float *)all, info.frames, &d)
                     : blkc_decode(s, length, all, info.frames, &d)) == BLKC_OK;
  int64_t starts[] = {0, 1, 4095, 4096, 5000, 6208, info.frames / 2, info.frames - 7};
  for (size_t k = 0; ok && k < sizeof starts / sizeof starts[0]; k++) {
    int64_t first = starts[k], count = info.frames - first < 3000 ? info.frames - first : 3000;
    int r = is_float ? blkc_decode_range_float(s, length, first, count, (float *)part, &d)
                     : blkc_decode_range(s, length, first, count, part, &d);
    ok = r == BLKC_OK && d.audio_md5 == 0 &&
         memcmp(part, all + first * info.channels, sizeof(int32_t) * (size_t)(count * info.channels)) == 0;
  }
  int past = is_float ? blkc_decode_range_float(s, length, info.frames - 1, 2, (float *)part, &d)
                      : blkc_decode_range(s, length, info.frames - 1, 2, part, &d);
  ok = ok && past == BLKC_BAD_ARGUMENT;
  free(part);
  free(all);
  free(s);
  return ok;
}

/* Read a stream through a decoder handle in uneven pieces, then from frames sought at random; every frame must equal
   the same frame of a full decode, and reads past the end, seeks past it and reads of the other kind are refused. */
static int handle_matches(const uint8_t *s, int64_t length, int is_float) {
  blkc_info info;
  blkc_decoder *dec = blkc_open(s, length, &info);
  if (!dec) return 0;
  size_t n = (size_t)(info.frames * info.channels);
  int32_t *all = malloc(sizeof(int32_t) * n), *part = malloc(sizeof(int32_t) * n);
  blkc_damage d;
  int ok = (is_float ? blkc_decode_float(s, length, (float *)all, info.frames, &d)
                     : blkc_decode(s, length, all, info.frames, &d)) == BLKC_OK;
  int64_t at = 0, piece = 1;
  while (ok && at < info.frames) {
    int64_t got = is_float ? blkc_read_float(dec, (float *)part, piece) : blkc_read(dec, part, piece);
    ok = got > 0 && memcmp(part, all + at * info.channels, sizeof(int32_t) * (size_t)(got * info.channels)) == 0;
    at += got;
    piece = piece * 3 % 5000 + 1;
  }
  ok = ok && (is_float ? blkc_read_float(dec, (float *)part, 10) : blkc_read(dec, part, 10)) == 0;
  uint32_t seed = 7;
  for (int k = 0; ok && k < 60; k++) {
    seed = seed * 1103515245u + 12345u;
    int64_t first = (int64_t)(seed >> 4) % info.frames, count = info.frames - first < 2000 ? info.frames - first : 2000;
    ok = blkc_seek(dec, first) == BLKC_OK &&
         (is_float ? blkc_read_float(dec, (float *)part, count) : blkc_read(dec, part, count)) == count &&
         memcmp(part, all + first * info.channels, sizeof(int32_t) * (size_t)(count * info.channels)) == 0 &&
         blkc_report(dec, &d) == BLKC_OK && d.audio_md5 == 0;
  }
  ok = ok && blkc_seek(dec, info.frames) == BLKC_OK &&
       (is_float ? blkc_read_float(dec, (float *)part, 1) : blkc_read(dec, part, 1)) == 0 &&
       blkc_seek(dec, info.frames + 1) == BLKC_BAD_ARGUMENT && blkc_seek(dec, -1) == BLKC_BAD_ARGUMENT &&
       blkc_seek(dec, 0) == BLKC_OK &&
       (is_float ? blkc_read(dec, part, 1) : blkc_read_float(dec, (float *)part, 1)) == BLKC_BAD_ARGUMENT;
  blkc_close(dec);
  free(part);
  free(all);
  return ok;
}

static int handle_file(const char *path, int is_float) {
  int64_t length;
  uint8_t *s = load(path, &length);
  int ok = s && handle_matches(s, length, is_float);
  free(s);
  return ok;
}

/* Code samples at a level and check reads and seeks through a handle on the stream. */
static int handle_coded(const int32_t *x, int64_t frames, int level) {
  blkc_info info = {2, 48000, 16, 16, frames, 3, 0, {0}};
  int64_t bound = blkc_encode_bound(frames, 2);
  uint8_t *s = malloc((size_t)bound);
  int64_t n = blkc_encode(x, &info, level, 0, s, bound);
  int ok = n > 0 && handle_matches(s, n, 0);
  free(s);
  return ok;
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
  check(ranges_match("../vectors/tags_seek_table.blkc", 0), "ranges from a seek point every second");
  check(ranges_match("../vectors/independent.blkc", 0), "ranges with every group a segment");
  check(ranges_match("../vectors/stereo_modes.blkc", 0), "ranges of a stereo stream");
  check(ranges_match("../vectors/float_patterns.blkc", 1), "float ranges");
  check(ranges_match("../vectors/delay_in_history.blkc", 0), "ranges of a stream that repeats earlier samples");
  check(ranges_match("../vectors/adaptive_stage.blkc", 0), "ranges of a stream with the adaptive stage");
  check(handle_file("../vectors/tags_seek_table.blkc", 0) && handle_file("../vectors/independent.blkc", 0) &&
            handle_file("../vectors/stereo_modes.blkc", 0) && handle_file("../vectors/eight_channels.blkc", 0),
        "handle reads and seeks");
  check(handle_file("../vectors/delay_in_history.blkc", 0) && handle_file("../vectors/adaptive_stage.blkc", 0),
        "handle seeks into blocks that read earlier samples");
  check(handle_file("../vectors/float_patterns.blkc", 1), "handle float reads and seeks");
  {
    enum { period = 5003, long_frames = 60000 };
    int32_t *p = malloc(sizeof(int32_t) * long_frames * 2);
    uint32_t r = 3;
    for (int i = 0; i < period * 2; i++) {
      r = r * 1103515245u + 12345u;
      p[i] = (int32_t)((r >> 16) % 4001) - 2000;
    }
    for (int i = period * 2; i < long_frames * 2; i++) p[i] = p[i - period * 2];
    check(handle_coded(p, long_frames, 4), "handle seeks in a repeating signal, level 4");
    for (int i = 0; i < long_frames; i++) {
      r = r * 1103515245u + 12345u;
      int noise = (int)((r >> 16) % 61) - 30;
      p[2 * i] = (int32_t)(9000.0 * sin(i * 0.013) + 4000.0 * sin(i * 0.11)) + noise;
      p[2 * i + 1] = (int32_t)(7000.0 * sin(i * 0.021 + 0.5)) - noise;
    }
    check(handle_coded(p, long_frames, 5), "handle seeks with the adaptive stage, level 5");
    free(p);
  }
  {
    blkc_info none;
    int64_t length;
    uint8_t *s = load("../vectors/not_a_stream.blkc", &length);
    check(s && blkc_open(s, length, &none) == NULL && blkc_open(NULL, 10, &none) == NULL &&
              blkc_seek(NULL, 0) == BLKC_BAD_ARGUMENT && blkc_read(NULL, NULL, 1) == BLKC_BAD_ARGUMENT,
          "handle arguments");
    blkc_close(NULL);
    free(s);
  }

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
  if (failures == 0) printf("  C interface: versions, layout, round trips, ranges, damage and arguments as declared\n");
  return failures != 0;
}
