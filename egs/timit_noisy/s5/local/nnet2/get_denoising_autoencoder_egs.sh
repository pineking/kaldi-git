#!/bin/bash

# Copyright 2012 Johns Hopkins University (Author: Daniel Povey).  Apache 2.0.
# Copyright 2014 Vimal Manohar
# This script, which will generally be called from other neural-net training
# scripts, extracts the training examples used to train the denoising autoencoder (and also
# the validation examples used for diagnostics), and puts them in separate archives.

# Begin configuration section.
cmd=run.pl
nj=4
feat_type=
num_utts_subset=300    # number of utterances in validation and training
                       # subsets used for shrinkage and diagnostics
num_valid_frames_combine=0 # #valid frames for combination weights at the very end.
num_train_frames_combine=10000 # # train frames for the above.
num_frames_diagnostic=4000 # number of frames for "compute_prob" jobs
samples_per_iter=200000 # each iteration of training, see this many samples
                        # per job.  This is just a guideline; it will pick a number
                        # that divides the number of samples in the entire data.
transform_dir=     
transform_dir_out=     
num_jobs_nnet=16    # Number of neural net jobs to run in parallel
stage=0
io_opts="-tc 5" # for jobs with a lot of I/O, limits the number running at one time. 
splice_width=4 # meaning +- 4 frames on each side as input to nnet 
left_context=
right_context=
random_copy=false
cmvn_opts=  # can be used for specifying CMVN options, if feature type is not lda.

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;


if [ $# != 3 ]; then
  echo "Usage: steps/nnet2/get_denoising_autoencoder_egs.sh [opts] <in-data> <out-data> <exp-dir>"
  echo " e.g.: steps/nnet2/get_denoising_autoencoder_egs.sh data/train_multi data/train_clean exp/nnet_da"
  echo ""
  echo "Main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config file containing options"
  echo "  --nj <num_jobs> To split data in parallel"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --num-jobs-nnet <num-jobs|16>                    # Number of parallel jobs to use for main neural net"
  echo "                                                   # training (will affect results as well as speed; try 8, 16)"
  echo "                                                   # Note: if you increase this, you may want to also increase"
  echo "                                                   # the learning rate."
  echo "  --samples-per-iter <#samples|400000>             # Number of samples of data to process per iteration, per"
  echo "                                                   # process."
  echo "  --feat-type <lda|raw>                            # (by default it tries to guess).  The feature type you want"
  echo "                                                   # to use as input to the neural net."
  echo "  --splice-width <width|4>                         # Number of frames on each side to append for feature input"
  echo "                                                   # (note: we splice processed, typically 40-dimensional frames"
  echo "  --num-frames-diagnostic <#frames|4000>           # Number of frames used in computing (train,valid) diagnostics"
  echo "  --num-valid-frames-combine <#frames|10000>       # Number of frames used in getting combination weights at the"
  echo "                                                   # very end."
  echo "  --stage <stage|0>                                # Used to run a partially-completed training process from somewhere in"
  echo "                                                   # the middle."
  
  exit 1;
fi

in_data=$1
out_data=$2
dir=$3

[ -z "$left_context" ] && left_context=$splice_width
[ -z "$right_context" ] && right_context=$splice_width

mkdir -p $dir/egs

# Check some files.
extra_files=

for f in $in_data/feats.scp $out_data/feats.scp $extra_files; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

mkdir -p $dir/log

if [ ! -z "$transform_dir" ]; then
  [ ! -f $transform_dir/num_jobs ] && echo "num_jobs not found in $transform_dir" && exit 1
  nj=`cat $transform_dir/num_jobs` || exit 1
fi

in_sdata=$in_data/split$nj
utils/split_data.sh $in_data $nj

out_sdata=$out_data/split$nj
utils/split_data.sh $out_data $nj

# Get list of validation utterances. 
awk '{print $1}' $in_data/utt2spk | utils/shuffle_list.pl | head -$num_utts_subset \
    > $dir/valid_uttlist || exit 1;

[ ! -s $dir/valid_uttlist ] && exit 1

if [ -f $in_data/utt2uniq ]; then
  mv $dir/valid_uttlist $dir/valid_uttlist.tmp
  [ ! -s $dir/valid_uttlist.tmp ] && exit 1
  utils/utt2spk_to_spk2utt.pl $in_data/utt2uniq > $dir/uniq2utt
  cat $dir/valid_uttlist.tmp | utils/apply_map.pl $in_data/utt2uniq | \
    sort | uniq | utils/apply_map.pl $dir/uniq2utt | \
    awk '{for(n=1;n<=NF;n++) print $n;}' | sort  > $dir/valid_uttlist
fi

cp $dir/valid_uttlist $dir/valid_out_uttlist

awk '{print $1}' $in_data/utt2spk | utils/filter_scp.pl --exclude $dir/valid_uttlist | \
  shuf -n $num_utts_subset > $dir/train_subset_uttlist || exit 1;

cp $dir/train_subset_uttlist $dir/train_subset_out_uttlist
 
#if [ -f $in_data/utt2uniq ]; then
#  utils/apply_map.pl $in_data/utt2uniq < $dir/train_subset_uttlist | sort -u > $dir/train_subset_out_uttlist || exit 1
#fi
#[ ! -s $dir/train_subset_out_uttlist ] && exit 1

## Set up features. 
if [ -z $feat_type ]; then
  if [ -f $transform_dir/final.mat ] && [ ! -f $transform_dir/raw_trans.1 ]; then feat_type=lda; else feat_type=raw; fi
fi
echo "$0: feature type is $feat_type"

case $feat_type in
  raw) 
    in_feats="ark,s,cs:utils/filter_scp.pl --exclude $dir/valid_uttlist $in_sdata/JOB/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$in_sdata/JOB/utt2spk scp:$in_sdata/JOB/cmvn.scp scp:- ark:- |"
    valid_in_feats="ark,s,cs:utils/filter_scp.pl $dir/valid_uttlist $in_data/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$in_data/utt2spk scp:$in_data/cmvn.scp scp:- ark:- |"
    train_subset_in_feats="ark,s,cs:utils/filter_scp.pl $dir/train_subset_uttlist $in_data/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$in_data/utt2spk scp:$in_data/cmvn.scp scp:- ark:- |"
    out_feats="ark,s,cs:utils/filter_scp.pl --exclude $dir/valid_out_uttlist $out_sdata/JOB/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$out_sdata/JOB/utt2spk scp:$out_sdata/JOB/cmvn.scp scp:- ark:- |"
    valid_out_feats="ark,s,cs:utils/filter_scp.pl $dir/valid_out_uttlist $out_data/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$out_data/utt2spk scp:$out_data/cmvn.scp scp:- ark:- |"
    train_subset_out_feats="ark,s,cs:utils/filter_scp.pl $dir/train_subset_out_uttlist $out_data/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$out_data/utt2spk scp:$out_data/cmvn.scp scp:- ark:- |"
    echo $cmvn_opts >$dir/cmvn_opts
   ;;
  lda) 
    splice_opts=`cat $transform_dir/splice_opts 2>/dev/null`
    cp $transform_dir/{splice_opts,cmvn_opts,final.mat} $dir || exit 1;
    [ ! -z "$cmvn_opts" ] && \
       echo "You cannot supply --cmvn-opts option if feature type is LDA." && exit 1;
    cmvn_opts=$(cat $dir/cmvn_opts)
    in_feats="ark,s,cs:utils/filter_scp.pl --exclude $dir/valid_uttlist $in_sdata/JOB/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$in_sdata/JOB/utt2spk scp:$in_sdata/JOB/cmvn.scp scp:- ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $dir/final.mat ark:- ark:- |"
    valid_in_feats="ark,s,cs:utils/filter_scp.pl $dir/valid_uttlist $in_data/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$in_data/utt2spk scp:$in_data/cmvn.scp scp:- ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $dir/final.mat ark:- ark:- |"
    train_subset_in_feats="ark,s,cs:utils/filter_scp.pl $dir/train_subset_uttlist $in_data/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$in_data/utt2spk scp:$in_data/cmvn.scp scp:- ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $dir/final.mat ark:- ark:- |"
    out_feats="ark,s,cs:utils/filter_scp.pl --exclude $dir/valid_out_uttlist $out_sdata/JOB/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$out_sdata/JOB/utt2spk scp:$out_sdata/JOB/cmvn.scp scp:- ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $dir/final.mat ark:- ark:- |"
    valid_out_feats="ark,s,cs:utils/filter_scp.pl $dir/valid_out_uttlist $out_data/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$out_data/utt2spk scp:$out_data/cmvn.scp scp:- ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $dir/final.mat ark:- ark:- |"
    train_subset_out_feats="ark,s,cs:utils/filter_scp.pl $dir/train_subset_out_uttlist $out_data/feats.scp | apply-cmvn $cmvn_opts --utt2spk=ark:$out_data/utt2spk scp:$out_data/cmvn.scp scp:- ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $dir/final.mat ark:- ark:- |"
    ;;
  *) echo "$0: invalid feature type $feat_type" && exit 1;
esac

if [ -f $transform_dir/trans.1 ] && [ -f $transform_dir_out/trans.1 ] && [ $feat_type != "raw" ]; then
  echo "$0: using transforms from $transform_dir"
  in_feats="$in_feats transform-feats --utt2spk=ark:$in_sdata/JOB/utt2spk ark:$transform_dir/trans.JOB ark:- ark:- |"
  valid_in_feats="$valid_in_feats transform-feats --utt2spk=ark:$in_data/utt2spk 'ark:cat $transform_dir/trans.*|' ark:- ark:- |"
  train_subset_in_feats="$train_subset_in_feats transform-feats --utt2spk=ark:$in_data/utt2spk 'ark:cat $transform_dir/trans.*|' ark:- ark:- |"
  out_feats="$out_feats transform-feats --utt2spk=ark:$out_sdata/JOB/utt2spk ark:$transform_dir_out/trans.JOB ark:- ark:- |"
  valid_out_feats="$valid_out_feats transform-feats --utt2spk=ark:$out_data/utt2spk 'ark:cat $transform_dir_out/trans.*|' ark:- ark:- |"
  train_subset_out_feats="$train_subset_out_feats transform-feats --utt2spk=ark:$out_data/utt2spk 'ark:cat $transform_dir_out/trans.*|' ark:- ark:- |"
fi
if [ -f $transform_dir/raw_trans.1 ] && [ -f $transform_dir_out/raw_trans.1 ] && [ $feat_type == "raw" ]; then
  echo "$0: using raw-fMLLR transforms from $transform_dir"
  in_feats="$in_feats transform-feats --utt2spk=ark:$in_sdata/JOB/utt2spk ark:$transform_dir/raw_trans.JOB ark:- ark:- |"
  valid_in_feats="$valid_in_feats transform-feats --utt2spk=ark:$in_data/utt2spk 'ark:cat $transform_dir/raw_trans.*|' ark:- ark:- |"
  train_subset_in_feats="$train_subset_in_feats transform-feats --utt2spk=ark:$in_data/utt2spk 'ark:cat $transform_dir/raw_trans.*|' ark:- ark:- |"
  out_feats="$out_feats transform-feats --utt2spk=ark:$out_sdata/JOB/utt2spk ark:$transform_dir_out/raw_trans.JOB ark:- ark:- |"
  valid_out_feats="$valid_out_feats transform-feats --utt2spk=ark:$out_data/utt2spk 'ark:cat $transform_dir_out/raw_trans.*|' ark:- ark:- |"
  train_subset_out_feats="$train_subset_out_feats transform-feats --utt2spk=ark:$out_data/utt2spk 'ark:cat $transform_dir_out/raw_trans.*|' ark:- ark:- |"
fi

feat_dim=$(subset-feats --n=1 "`echo $in_feats | sed 's/JOB/1/g'`" ark:- 2> /dev/null | feat-to-dim ark:- ark,t:- 2> /dev/null | awk '{print $2}') || exit 1
target_dim=$(subset-feats --n=1 "`echo $out_feats | sed 's/JOB/1/g'`" ark:- 2> /dev/null | feat-to-dim ark:- ark,t:- 2> /dev/null | awk '{print $2}') || exit 1
ivector_dim=0

#if [ -f $in_data/utt2uniq ]; then
#  valid_in_feats="$valid_in_feats copy-feats --utt-map=$in_data/utt2uniq ark:- ark:- |"
#  train_subset_in_feats="$train_subset_in_feats copy-feats --utt-map=$in_data/utt2uniq ark:- ark:- |"
#  in_feats="$in_feats copy-feats --utt-map=$in_data/utt2uniq ark:- ark:- |"
#fi

echo $feat_dim > $dir/feat_dim
echo $target_dim > $dir/target_dim
echo $ivector_dim > $dir/ivector_dim

if [ $stage -le 0 ]; then
  echo "$0: working out number of frames of training data"
  num_frames=$(steps/nnet2/get_num_frames.sh $in_data)
  echo $num_frames > $dir/num_frames
else
  num_frames=`cat $dir/num_frames` || exit 1;
fi

# Working out number of iterations per epoch.
iters_per_epoch=`perl -e "print int($num_frames/($samples_per_iter * $num_jobs_nnet) + 0.5);"` || exit 1;
[ $iters_per_epoch -eq 0 ] && iters_per_epoch=1
samples_per_iter_real=$[$num_frames/($num_jobs_nnet*$iters_per_epoch)]
echo "$0: Every epoch, splitting the data up into $iters_per_epoch iterations,"
echo "$0: giving samples-per-iteration of $samples_per_iter_real (you requested $samples_per_iter)."

# Making soft links to storage directories.  This is a no-up unless
# the subdirectory $dir/egs/storage/ exists.  See utils/create_split_dir.pl
for x in `seq 1 $num_jobs_nnet`; do
  for y in `seq 0 $[$iters_per_epoch-1]`; do
    utils/create_data_link.pl $dir/egs/egs.$x.$y.ark
    utils/create_data_link.pl $dir/egs/egs_tmp.$x.$y.ark
  done
  for y in `seq 1 $nj`; do
    utils/create_data_link.pl $dir/egs/egs_orig.$x.$y.ark
  done
done

remove () { for x in $*; do [ -L $x ] && rm $(readlink -f $x); rm $x; done }

nnet_context_opts="--left-context=$left_context --right-context=$right_context"
mkdir -p $dir/egs

if [ $stage -le 2 ]; then
  echo "Getting validation and training subset examples."
  rm $dir/.error 2>/dev/null
  $cmd $dir/log/create_valid_subset.log \
    prob-to-post --no-prune=true "$valid_out_feats" ark:- \| \
    nnet-get-egs $nnet_context_opts "$valid_in_feats" \
    ark:- ark:$dir/egs/valid_all.egs || touch $dir/.error &
  $cmd $dir/log/create_train_subset.log \
    prob-to-post --no-prune=true "$train_subset_out_feats" ark:- \| \
    nnet-get-egs $nnet_context_opts "$train_subset_in_feats" \
    ark:- ark:$dir/egs/train_subset_all.egs || touch $dir/.error &
  wait;
  [ -f $dir/.error ] && exit 1;
  echo "Getting subsets of validation examples for diagnostics and combination."
  $cmd $dir/log/create_valid_subset_combine.log \
    nnet-subset-egs --n=$num_valid_frames_combine ark:$dir/egs/valid_all.egs \
        ark:$dir/egs/valid_combine.egs || touch $dir/.error &
  $cmd $dir/log/create_valid_subset_diagnostic.log \
    nnet-subset-egs --n=$num_frames_diagnostic ark:$dir/egs/valid_all.egs \
    ark:$dir/egs/valid_diagnostic.egs || touch $dir/.error &

  $cmd $dir/log/create_train_subset_combine.log \
    nnet-subset-egs --n=$num_train_frames_combine ark:$dir/egs/train_subset_all.egs \
    ark:$dir/egs/train_combine.egs || touch $dir/.error &
  $cmd $dir/log/create_train_subset_diagnostic.log \
    nnet-subset-egs --n=$num_frames_diagnostic ark:$dir/egs/train_subset_all.egs \
    ark:$dir/egs/train_diagnostic.egs || touch $dir/.error &
  wait
  cat $dir/egs/valid_combine.egs $dir/egs/train_combine.egs > $dir/egs/combine.egs

  for f in $dir/egs/{combine,train_diagnostic,valid_diagnostic}.egs; do
    [ ! -s $f ] && echo "No examples in file $f" && exit 1;
  done
  rm $dir/egs/valid_all.egs $dir/egs/train_subset_all.egs $dir/egs/{train,valid}_combine.egs
fi

if [ $stage -le 3 ]; then
  # Other scripts might need to know the following info:
  echo $num_jobs_nnet >$dir/egs/num_jobs_nnet
  echo $iters_per_epoch >$dir/egs/iters_per_epoch
  echo $samples_per_iter_real >$dir/egs/samples_per_iter

  echo "Creating training examples";
  # in $dir/egs, create $num_jobs_nnet separate files with training examples.
  # The order is not randomized at this point.

  egs_list=
  for n in `seq 1 $num_jobs_nnet`; do
    egs_list="$egs_list ark:$dir/egs/egs_orig.$n.JOB.ark"
  done
  echo "Generating training examples on disk"
  # The examples will go round-robin to egs_list.
  $cmd $io_opts JOB=1:$nj $dir/log/get_egs.JOB.log \
    prob-to-post --no-prune=false "$out_feats" ark:- \| \
    nnet-get-egs $nnet_context_opts "$in_feats" \
    ark:- ark:- \| \
    nnet-copy-egs ark:- $egs_list || exit 1;
fi

if [ $stage -le 4 ]; then
  echo "$0: rearranging examples into parts for different parallel jobs"
  # combine all the "egs_orig.JOB.*.scp" (over the $nj splits of the data) and
  # then split into multiple parts egs.JOB.*.scp for different parts of the
  # data, 0 .. $iters_per_epoch-1.

  if [ $iters_per_epoch -eq 1 ]; then
    echo "$0: Since iters-per-epoch == 1, just concatenating the data."
    for n in `seq 1 $num_jobs_nnet`; do
      cat $dir/egs/egs_orig.$n.*.ark > $dir/egs/egs_tmp.$n.0.ark || exit 1;
      remove $dir/egs/egs_orig.$n.*.ark 
    done
  else # We'll have to split it up using nnet-copy-egs.
    egs_list=
    for n in `seq 0 $[$iters_per_epoch-1]`; do
      egs_list="$egs_list ark:$dir/egs/egs_tmp.JOB.$n.ark"
    done
    # note, the "|| true" below is a workaround for NFS bugs
    # we encountered running this script with Debian-7, NFS-v4.
    $cmd $io_opts JOB=1:$num_jobs_nnet $dir/log/split_egs.JOB.log \
      nnet-copy-egs --random=$random_copy --srand=JOB \
        "ark:cat $dir/egs/egs_orig.JOB.*.ark|" $egs_list || exit 1;
    remove $dir/egs/egs_orig.*.*.ark  2>/dev/null
  fi
fi

if [ $stage -le 5 ]; then
  # Next, shuffle the order of the examples in each of those files.
  # Each one should not be too large, so we can do this in memory.
  echo "Shuffling the order of training examples"
  echo "(in order to avoid stressing the disk, these won't all run at once)."

  for n in `seq 0 $[$iters_per_epoch-1]`; do
    $cmd $io_opts JOB=1:$num_jobs_nnet $dir/log/shuffle.$n.JOB.log \
      nnet-shuffle-egs "--srand=\$[JOB+($num_jobs_nnet*$n)]" \
      ark:$dir/egs/egs_tmp.JOB.$n.ark ark:$dir/egs/egs.JOB.$n.ark 
    remove $dir/egs/egs_tmp.*.$n.ark
  done
fi

echo "$0: Finished preparing training examples"