/* Seek timing through each codec's library: open a file once, then for each of count frames drawn from seed, seek
   to it and read frames frames. Prints one tab-separated line: file, frames in the file, median, 90th percentile and
   largest time in milliseconds, and a sum of the first channel's samples read, equal across codecs for the same
   audio. Usage: seek_bench <file.flac|file.wv|file.blkc> <count> <frames> <seed> */
#define _POSIX_C_SOURCE 200809L
#include <FLAC/stream_decoder.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wavpack/wavpack.h>

#include "blockcodec.h"

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static int by_value(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

static uint64_t state;
static uint64_t next(void) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

typedef struct {
  int64_t want, got;
  long long sum;
} flac_read;

static FLAC__StreamDecoderWriteStatus flac_write(const FLAC__StreamDecoder *d, const FLAC__Frame *f,
                                                 const FLAC__int32 *const b[], void *c) {
  (void)d;
  flac_read *r = c;
  for (unsigned i = 0; i < f->header.blocksize && r->got < r->want; i++, r->got++) r->sum += b[0][i];
  return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

static void flac_error(const FLAC__StreamDecoder *d, FLAC__StreamDecoderErrorStatus e, void *c) {
  (void)d;
  (void)e;
  (void)c;
}

int main(int argc, char **argv) {
  if (argc != 5) return 2;
  const char *path = argv[1], *kind = strrchr(path, '.');
  int count = atoi(argv[2]);
  int64_t want = atoll(argv[3]), frames = 0;
  state = strtoull(argv[4], NULL, 10) | 1;
  double *ms = calloc((size_t)count, sizeof *ms);
  long long sum = 0;
  if (!kind || count < 1 || want < 1 || !ms) return 2;
  if (!strcmp(kind, ".blkc")) {
    FILE *f = fopen(path, "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long length = ftell(f);
    rewind(f);
    uint8_t *s = malloc((size_t)length);
    if (!s || fread(s, 1, (size_t)length, f) != (size_t)length) return 2;
    fclose(f);
    blkc_info info;
    blkc_decoder *d = blkc_open(s, length, &info);
    if (!d) return 2;
    frames = info.frames;
    int32_t *out = malloc(sizeof(int32_t) * (size_t)(want * info.channels));
    for (int i = 0; i < count; i++) {
      int64_t t = (int64_t)(next() % (uint64_t)(frames - want)), got = 0;
      double a = now();
      if (blkc_seek(d, t) != BLKC_OK) return 1;
      while (got < want) {
        int64_t n = blkc_read(d, out + got * info.channels, want - got);
        if (n <= 0) return 1;
        got += n;
      }
      ms[i] = (now() - a) * 1e3;
      for (int64_t k = 0; k < want; k++) sum += out[k * info.channels];
    }
    blkc_close(d);
  } else if (!strcmp(kind, ".flac")) {
    FLAC__StreamDecoder *d = FLAC__stream_decoder_new();
    flac_read r = {0, 0, 0};
    FLAC__stream_decoder_set_md5_checking(d, false);
    if (FLAC__stream_decoder_init_file(d, path, flac_write, NULL, flac_error, &r) != FLAC__STREAM_DECODER_INIT_STATUS_OK)
      return 2;
    FLAC__stream_decoder_process_until_end_of_metadata(d);
    frames = (int64_t)FLAC__stream_decoder_get_total_samples(d);
    for (int i = 0; i < count; i++) {
      int64_t t = (int64_t)(next() % (uint64_t)(frames - want));
      double a = now();
      r.want = want;
      r.got = 0;
      r.sum = 0;
      if (!FLAC__stream_decoder_seek_absolute(d, (FLAC__uint64)t)) return 1;
      while (r.got < r.want)
        if (!FLAC__stream_decoder_process_single(d)) return 1;
      ms[i] = (now() - a) * 1e3;
      sum += r.sum;
    }
    FLAC__stream_decoder_delete(d);
  } else if (!strcmp(kind, ".wv")) {
    char error[80];
    WavpackContext *w = WavpackOpenFileInput(path, error, 0, 0);
    if (!w) return 2;
    frames = WavpackGetNumSamples64(w);
    int channels = WavpackGetNumChannels(w);
    int32_t *out = malloc(sizeof(int32_t) * (size_t)(want * channels));
    for (int i = 0; i < count; i++) {
      int64_t t = (int64_t)(next() % (uint64_t)(frames - want)), got = 0;
      double a = now();
      if (!WavpackSeekSample64(w, t)) return 1;
      while (got < want) {
        uint32_t n = WavpackUnpackSamples(w, out + got * channels, (uint32_t)(want - got));
        if (!n) return 1;
        got += n;
      }
      ms[i] = (now() - a) * 1e3;
      for (int64_t k = 0; k < want; k++) sum += out[k * channels];
    }
    WavpackCloseFile(w);
  } else {
    return 2;
  }
  qsort(ms, (size_t)count, sizeof *ms, by_value);
  printf("%s\t%lld\t%.3f\t%.3f\t%.3f\t%lld\n", path, (long long)frames, ms[count / 2], ms[count * 9 / 10], ms[count - 1], sum);
  return 0;
}
