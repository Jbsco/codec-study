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
#define BLKC_UNSUPPORTED 3  /* a stream of the other sample kind: float for blkc_decode, integer for blkc_decode_float */
#define BLKC_BAD_ARGUMENT (-1)
#define BLKC_FAILED (-2)    /* the library could not finish the call, for lack of memory */

/* The audio a stream holds. Integer samples are signed in depth bits, left-justified when valid_bits is less; float
   samples are 32-bit IEEE 754 values with depth and valid_bits 32. */
typedef struct {
  int32_t channels;      /* 1 to 8 */
  int32_t rate;          /* samples per second, 0 when unknown */
  int32_t depth;         /* 8, 16, 24 or 32; a float stream read from 64-bit input reports 64 */
  int32_t valid_bits;    /* 1 to depth */
  int64_t frames;        /* 0 to 2^31 - 1 */
  uint32_t channel_mask; /* WAV speaker positions, 0 when none */
  int32_t is_float;      /* 1 for a float stream, set by blkc_read_info; the encoders ignore it */
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

/* Code info->frames frames of interleaved float samples; info->depth and info->valid_bits must be 32. Every bit
   pattern, NaN and infinity included, comes back as it was. Returns as blkc_encode does. */
int64_t blkc_encode_float(const float *samples, const blkc_info *info, int32_t level, int32_t threads, uint8_t *stream,
                          int64_t capacity);

/* Read a stream's header into info. Returns BLKC_OK, BLKC_REFUSED or BLKC_BAD_ARGUMENT. */
int blkc_read_info(const uint8_t *stream, int64_t length, blkc_info *info);

/* Decode a stream into frames * channels interleaved samples; capacity_frames must hold the header's frame count.
   Returns BLKC_OK, BLKC_DAMAGED, BLKC_REFUSED, BLKC_UNSUPPORTED or BLKC_BAD_ARGUMENT. */
int blkc_decode(const uint8_t *stream, int64_t length, int32_t *samples, int64_t capacity_frames, blkc_damage *damage);

/* Decode a float stream into interleaved float samples, as blkc_decode does for integer streams. A stream coded from
   64-bit floats gives their values, which are exactly 32-bit floats. */
int blkc_decode_float(const uint8_t *stream, int64_t length, float *samples, int64_t capacity_frames,
                      blkc_damage *damage);

/* Decode frames first to first + count - 1 into count * channels interleaved samples, starting at the seek point at
   or before first, so only the groups from there are read. damage covers those groups; its audio_md5 is 0, since a
   range cannot be checked against the whole stream's digest. Returns as blkc_decode does, with BLKC_BAD_ARGUMENT for
   a range past the stream's frames. */
int blkc_decode_range(const uint8_t *stream, int64_t length, int64_t first, int64_t count, int32_t *samples,
                      blkc_damage *damage);
int blkc_decode_range_float(const uint8_t *stream, int64_t length, int64_t first, int64_t count, float *samples,
                            blkc_damage *damage);

/* A decoder for players. blkc_open copies the stream and reads its header into info, or returns NULL for a refused
   header or a wrong argument. blkc_read then hands out frames in order, from frame 0 or from the frame the last
   blkc_seek named; a seek decodes only the groups that frame needs. */
typedef struct blkc_decoder blkc_decoder;
blkc_decoder *blkc_open(const uint8_t *stream, int64_t length, blkc_info *info);
/* Move to frame, 0 to info.frames. Returns BLKC_OK or BLKC_BAD_ARGUMENT. */
int blkc_seek(blkc_decoder *decoder, int64_t frame);
/* Read up to frames frames into frames * channels interleaved samples. Returns the frames read, 0 at the stream's
   end, or BLKC_BAD_ARGUMENT for a stream of the other sample kind or a wrong argument. */
int64_t blkc_read(blkc_decoder *decoder, int32_t *samples, int64_t frames);
int64_t blkc_read_float(blkc_decoder *decoder, float *samples, int64_t frames);
/* What the reads since blkc_open or the last blkc_seek met; its audio_md5 is 0. Returns BLKC_OK or BLKC_DAMAGED. */
int blkc_report(blkc_decoder *decoder, blkc_damage *damage);
void blkc_close(blkc_decoder *decoder);

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
