/* The block codec's C interface, API version 1, for streams in format version 2 (docs/spec.md).
   Link with -lblockcodec. Each call is independent of every other, so calls may run on many threads at once. */
#ifndef BLOCKCODEC_H
#define BLOCKCODEC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BLKC_API_VERSION 1
#define BLKC_FORMAT_VERSION 2

/* Return codes. */
#define BLKC_OK 0           /* decoded intact */
#define BLKC_DAMAGED 1      /* decoded with damage: lost frames are zero, blkc_damage says what was found */
#define BLKC_REFUSED 2      /* not a readable stream: magic, version, field or header CRC */
#define BLKC_UNSUPPORTED 3  /* a float stream, which this API version does not decode */
#define BLKC_BAD_ARGUMENT (-1)

/* The audio a stream holds. Samples are signed integers in depth bits, left-justified when valid_bits is less. */
typedef struct {
  int32_t channels;      /* 1 to 8 */
  int32_t rate;          /* samples per second, 0 when unknown */
  int32_t depth;         /* 8, 16, 24 or 32 */
  int32_t valid_bits;    /* 1 to depth */
  int64_t frames;        /* 0 to 2^31 - 1 */
  uint32_t channel_mask; /* WAV speaker positions, 0 when none */
  int32_t is_float;      /* 0; set by blkc_read_info for float streams */
  uint8_t audio_md5[16]; /* MD5 of the samples in FLAC's layout, all zeros when not recorded */
} blkc_info;

/* What a decode found. */
typedef struct {
  int64_t lost_frames;    /* frames of unreadable groups, written as zeros */
  int32_t bad_groups;     /* groups skipped for a wrong sync word, field or CRC */
  int32_t bad_block_crcs; /* blocks whose CRC failed, decoded anyway */
  int32_t blocks_ok;      /* 1 when every block decoded under the format's rules */
  int32_t audio_md5;      /* 0 not recorded, 1 matches the decoded samples, 2 differs */
} blkc_damage;

int blkc_api_version(void);
int blkc_format_version(void);

/* The most bytes blkc_encode writes for frames of channels, or BLKC_BAD_ARGUMENT. */
int64_t blkc_encode_bound(int64_t frames, int32_t channels);

/* Code info->frames frames of interleaved samples into stream. level is 0 to 5, threads 1 to 1024, or 0 for every
   processor; the stream is the same for any thread count. Returns the stream's length, or BLKC_BAD_ARGUMENT for an
   argument out of range, a sample outside depth bits, or a capacity below the stream's length. */
int64_t blkc_encode(const int32_t *samples, const blkc_info *info, int32_t level, int32_t threads, uint8_t *stream,
                    int64_t capacity);

/* Read a stream's header into info. Returns BLKC_OK, BLKC_REFUSED or BLKC_BAD_ARGUMENT. */
int blkc_read_info(const uint8_t *stream, int64_t length, blkc_info *info);

/* Decode a stream into frames * channels interleaved samples; capacity_frames must hold the header's frame count.
   Returns BLKC_OK, BLKC_DAMAGED, BLKC_REFUSED, BLKC_UNSUPPORTED or BLKC_BAD_ARGUMENT. */
int blkc_decode(const uint8_t *stream, int64_t length, int32_t *samples, int64_t capacity_frames, blkc_damage *damage);

/* Block level: one block of one signal, as the Haskell hybrid calls it. Samples are 64-bit, history the decoded samples
   before the block. block_encode returns the bytes written or -1; block_decode returns 0 decoded, 1 truncated input,
   2 bad data, or -1. */
int block_encode(const int64_t *samples, int count, const int64_t *history, int history_count, int depth, int lpc_orders,
                 int precision_from, int adaptive, int adaptive_code, uint8_t *output, int capacity);
int block_decode(const uint8_t *input, int length, const int64_t *history, int history_count, int count, int depth,
                 int64_t *samples);

#ifdef __cplusplus
}
#endif

#endif
