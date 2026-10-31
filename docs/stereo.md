# Stereo

## Method

For a pair of channels in the same float mode, the encoder codes each block as left and right, left and side, side and right, or mid and side, whichever is shortest, and the leaf carries the mode in 2 bits. The mid is the mean of the two channels rounded down, and the side is left minus right, coded one bit wider. The decoder rebuilds left and right from the mode's two signals exactly. At the lower levels the encoder picks the mode from an estimate instead of coding all four signals: the pair whose summed absolute second differences have the smallest summed logarithm.

## Measured effect

Over the corpus 7.17 to 7.14 bits per sample; on the ten recordings 10.55 to 10.41. The electronic track gains most, 19.76 to 18.65, and uses all three modes with a side. Speech at 48 kHz codes mid and side in 314 of its 319 blocks and gains 0.19. Both piano recordings keep left and right throughout: their channels carry different signals and no mode is smaller. The estimate at level 1 chooses the same mode as the exact search often enough that level 1 stays within 1.3 percent of level 4 overall.

## Cost

Two additions per frame in the decoder. The encoder at level 3 and above codes four signals per node instead of two.

## Beyond audio

The idea is decorrelation of channels that carry related values: coding one channel and the difference to it. It applies to any multi-channel record whose channels move together, such as three-axis sensors or the red, green and blue planes of an image, where the same choice-per-block structure works and the difference channel needs one more bit of range. It does not apply to channels that carry unrelated data.
