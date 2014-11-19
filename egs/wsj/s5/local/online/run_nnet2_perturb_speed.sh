#!/bin/bash
# Copyright 2013  Johns Hopkins University (author: Daniel Povey)
#           2014  Tom Ko
# Apache 2.0

# This example script demonstrates how speed perturbation of the data helps the nnet training.

. ./cmd.sh
. ./path.sh

stage=-1
train_stage=-10
use_gpu=true
nnet_dir=exp/nnet2_online_perturb

if $use_gpu; then
  if ! cuda-compiled; then
    cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.  Otherwise, call this script with --use-gpu false
EOF
  fi
  parallel_opts="-l gpu=1"
  num_threads=1
  minibatch_size=512
  # the _a is in case I want to change the parameters.
  dir=$nnet_dir/nnet_a_gpu
else
  # Use 4 nnet jobs just like run_4d_gpu.sh so the results should be
  # almost the same, but this may be a little bit slow.
  num_threads=16
  minibatch_size=128
  parallel_opts="-pe smp $num_threads"
  dir=$nnet_dir/nnet_a
fi


if [ $stage -le -1 ]; then
  utils/perturb_data_dir_speed.sh 0.9 data/train_si284 data/train_si284temp1
  utils/perturb_data_dir_speed.sh 1.0 data/train_si284 data/train_si284temp2
  utils/perturb_data_dir_speed.sh 1.1 data/train_si284 data/train_si284temp3
  utils/combine_data.sh data/train_si284p data/train_si284temp1 data/train_si284temp2 data/train_si284temp3
  rm -r data/train_si284temp1 data/train_si284temp2 data/train_si284temp3

  mfccdir=mfcc_perturbed
  for x in train_si284p; do
    steps/make_mfcc.sh --cmd "$train_cmd" --nj 20 \
      data/$x exp/make_mfcc/$x $mfccdir || exit 1;
    steps/compute_cmvn_stats.sh data/$x exp/make_mfcc/$x $mfccdir || exit 1;
  done
fi

if [ $stage -le 0 ]; then
  steps/align_fmllr.sh --nj 30 --cmd "$train_cmd" \
    data/train_si284p data/lang exp/tri4b exp/tri4b_ali_si284p || exit 1;
fi


if [ $stage -le 1 ]; then
  mkdir -p $nnet_dir
  # To train a diagonal UBM we don't need very much data, so use just the si84 data.
  # the tri3b is the input dir; the choice of this is not critical as we just use
  # it for the LDA matrix.  Since the iVectors don't make a great deal of difference,
  # we'll use 256 Gaussians for speed.
  steps/online/nnet2/train_diag_ubm.sh --cmd "$train_cmd" --nj 30 --num-frames 200000 \
    data/train_si84 256 exp/tri3b $nnet_dir/diag_ubm
fi	

if [ $stage -le 2 ]; then
  # even though $nj is just 10, each job uses multiple processes and threads.
  steps/online/nnet2/train_ivector_extractor.sh --cmd "$train_cmd" --nj 10 \
    data/train_si284p $nnet_dir/diag_ubm $nnet_dir/extractor || exit 1;
fi

if [ $stage -le 3 ]; then
   steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 30 \
    data/train_si284p $nnet_dir/extractor $nnet_dir/ivectors_train_si284p || exit 1;
fi

if [ $stage -le 4 ]; then
  steps/nnet2/train_pnorm_simple2.sh --stage $train_stage \
    --online-ivector-dir $nnet_dir/ivectors_train_si284p \
    --num-epochs 4 \
    --splice-width 7 --feat-type raw \
    --cmvn-opts "--norm-means=false --norm-vars=false" \
    --num-threads "$num_threads" \
    --minibatch-size "$minibatch_size" \
    --parallel-opts "$parallel_opts" \
    --num-jobs-nnet 6 \
    --num-hidden-layers 4 \
    --mix-up 4000 \
    --initial-learning-rate 0.02 --final-learning-rate 0.004 \
    --cmd "$decode_cmd" \
    --pnorm-input-dim 2400 \
    --pnorm-output-dim 300 \
    data/train_si284p data/lang exp/tri4b_ali_si284p $dir  || exit 1;
fi

if [ $stage -le 5 ]; then
  for data in test_eval92 test_dev93 test_eval93; do
    steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 8 \
      data/${data} $nnet_dir/extractor $nnet_dir/ivectors_${data} || exit 1;
  done
fi

if [ $stage -le 6 ]; then
  # this does offline decoding that should give the same results as the real
  # online decoding.
  for lm_suffix in tgpr bd_tgpr; do
    graph_dir=exp/tri4b/graph_${lm_suffix}
    # use already-built graphs.
    for year in eval92 eval93 dev93; do
      steps/nnet2/decode.sh --nj 8 --cmd "$decode_cmd" \
        --online-ivector-dir $nnet_dir/ivectors_test_$year \
        $graph_dir data/test_$year $dir/decode_${lm_suffix}_${year} || exit 1;
    done
  done
fi




