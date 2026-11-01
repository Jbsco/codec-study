# Stereo

## Method

Channels pair up in order, 1 with 2, 3 with 4, and an odd last channel is coded alone. For a pair in the same float mode, the encoder codes each block as left and right, left and side, side and right, or mid and side, whichever is shortest, and the leaf contains each pair's mode in 2 bits. Mid is the mean of the two channels rounded down, and side is left minus right, coded one bit wider. The decoder rebuilds left and right from the mode's two signals exactly.

At the lower levels the encoder picks the mode from an estimate instead of coding all four signals: the pair whose summed absolute second differences have the smallest summed logarithm.

## Measured effect

Over the corpus 7.17 to 7.14 bits per sample; on the ten recordings 10.55 to 10.41. The electronic track gains most, 19.76 to 18.65, and uses all three modes with a side. Speech at 48 kHz codes mid and side in 314 of its 319 blocks and gains 0.19. Both piano recordings keep left and right throughout: their channels hold different signals and no mode is smaller. The estimate at level 1 chooses the same mode as the exact search often enough that level 1 stays within 1.3 percent of level 4 overall.

## More than two channels

`multichannel.sh` merges the orchestra and room recordings, both 48 kHz, 24-bit and 20 s, into one four-channel file and codes it at level 4: 6,525,980 bytes with pairs, 6,534,159 with every channel alone (`--no-pairs`), 0.13 percent apart, and 3,072 bytes less than the two stereo streams together, which contain two headers and two sets of group framing. On these two recordings the stereo modes gain little, so the pairs gain little; the electronic track would gain its 1.1 bits per sample as a pair wherever it sat among the channels.

Pairs by position suit layouts whose related channels are adjacent, such as left and right and the two surrounds of a 5.1 mix. A center and a low-frequency channel pair harmlessly, since left and right is always available. No real multichannel recording in the public domain was at hand, so the file is constructed and says nothing about the correlation of real surround channels.

## Cost

Two additions per frame in the decoder. The encoder at level 3 and above codes four signals per node instead of two for every coupled pair: the four-channel file took 26.38 s against 12.65 s with channels alone.

## Beyond audio

The idea is decorrelation of channels with related values: coding one channel and the difference to it. It applies to any multi-channel record whose channels move together, such as three-axis sensors or the red, green and blue planes of an image, where the same choice-per-block structure works and the difference channel needs one more bit of range. It does not apply to channels with unrelated data.
