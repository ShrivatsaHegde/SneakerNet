#!/usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use File::Basename qw/dirname/;

use Test::More tests => 3;

use FindBin qw/$RealBin/;

use lib "$RealBin/../lib/perl5";
use_ok 'SneakerNet';

$ENV{PATH}="$RealBin/../scripts:$RealBin/../SneakerNet.plugins:$ENV{PATH}";
my $run = "$RealBin/M00123-18-001-test";

is system("addReadMetrics.pl --force $run >/dev/null 2>&1"), 0, "Adding read metrics";

# Double check that everything is 10x.  ish.
# The exception is that the Vibrio sample is only the
# 3 Mb chromosome and so the coverage calculation
# will be off.
subtest "Expected coverage" => sub {
  plan tests => 6;
  my %expected = (
    "FA1090_1.fastq.gz"           => 5,
    "FA1090_2.fastq.gz"           => 5,
    "2010EL-1786_1.fastq.gz"      => 3.8,
    "2010EL-1786_2.fastq.gz"      => 3.8,
    "Philadelphia_CDC_1.fastq.gz" => 5,
    "Philadelphia_CDC_2.fastq.gz" => 5,
  );
  open(my $fh, "$run/readMetrics.tsv") or die "ERROR reading $run/readMetrics.tsv: $!";
  while(<$fh>){
    chomp;
    my ($file, $avgReadLength, $totalBases, $minReadLength, $maxReadLength, $avgQuality, $numReads, $PE, $coverage) 
        = split(/\t/, $_);
    
    next if(!$expected{$file}); # avoid header
    ok $coverage > $expected{$file} - 1 && $coverage < $expected{$file} + 1, "Coverage for $file";
  }
  close $fh;
};