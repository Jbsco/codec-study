# Learned decisions

## Question

The level-4 encoder decides whether to split each group of 4096 frames by coding every node of the tree, 15 nodes per group. That search is most of the difference between level 3 and level 4 in time, 100 s against 244 s in Ada over the corpus, for 0.016 bits per sample. Could a small gate network predict the decision from cheap features, so a low level gets the split without the search? A wrong prediction only costs bits, never correctness, because the decoder accepts any tree.

## Data

`codec_main --features` writes, per group, bit lengths of the summed absolute first differences of each of its eight eighths and of its peak sample, and whether the exact search split the root. Over the corpus at level 4: 8,166 groups, of which 403 were split, 4.9 percent. Features were thermometer coded to 208 bits, absolute values and each eighth relative to the group's largest.

## Result

Ten of the forty files were held out whole. The majority answer, never split, scores 0.995 on held-out groups, which contain 13 splits in 2,537. Differentiable logic gate networks of 36 to 114 gates, trained on the other thirty files and discretized, score 0.995 on held-out groups: they learned to predict one true split and miss twelve. A one-line rule, split when the eighths' bit lengths span more than 2 bits, scores 0.934 on training files and 0.993 held out, and finds splits the network does not.

## Reading

This decision is too rare and too tied to exact bit counts to learn from these features: a split pays when the halves' best predictors differ, which the energy of the eighths only hints at. What the data does support is the rule as a cheap pre-filter: a low level that splits only where the spread rule fires would try the halves on 7 percent of groups instead of all of them. A gate network is the right form for a decision that a table already describes exactly, which this one is not.

## Beyond audio

Before learning an encoder decision, count how often it goes each way and what the majority answer scores. A decision made in 5 percent of cases needs features that separate that 5 percent, and energy summaries did not. The measurement that settles it is the one here: a held-out split by file, the discrete network's confusion counts, and a hand rule beside it.
