#!/usr/bin/env perl
# Use Kmers to guess if there is contamination

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use File::Basename qw/fileparse basename dirname/;
use File::Temp qw/tempdir/;
use File::Copy qw/mv cp/;
use FindBin;
use Bio::SeqIO;

use lib "$FindBin::RealBin/../lib/perl5";
use SneakerNet qw/readConfig samplesheetInfo_tsv command logmsg/;

local $0=fileparse $0;
exit(main());

sub main{
  my $settings=readConfig();
  GetOptions($settings,qw(help k|kmer=i force debug tempdir=s numcpus=i mlstfasta=s)) or die $!;
  die usage() if($$settings{help} || !@ARGV);
  $$settings{numcpus}||=1;
  $$settings{tempdir}||=tempdir("$0XXXXXX",TMPDIR=>1, CLEANUP=>1);
  $$settings{mlstfasta}||=die "ERROR: need --mlstfasta";
  $$settings{k}||=39;

  my $dir=$ARGV[0];
  mkdir "$dir/SneakerNet";
  mkdir "$dir/SneakerNet/colorid";

  system("which colorid >& /dev/null");
  if($?){
    die "ERROR: could not find colorid in your PATH";
  }

  my $mlstFasta = readMlstFasta($$settings{mlstfasta}, $settings);
  
  my $report = mlstColorId($dir, $mlstFasta, $settings);

  my $finalReport = "$dir/SneakerNet/forEmail/mlst-contamination-detection.tsv";
  cp($report, $finalReport);
  logmsg "Report can be found in $finalReport";

  return 0;
}

sub readMlstFasta{
  my($infasta, $settings)=@_;

  my $newFasta = "$$settings{tempdir}/query.fasta";

  open(my $fh, ">", $newFasta) or die "ERROR: writing to $newFasta: $!";
  my $inseq = Bio::SeqIO->new(-file=>$infasta);
  while(my $seq = $inseq->next_seq){
    my $sequence = $seq->seq; # pull it out once to make it go faster
    next if(length($sequence) < $$settings{k});
    next if($sequence =~ /A{30,}|C{30,}|G{30,}|T{30,}/);
    next if($sequence =~ /N{5,}/);
    print $fh ">".$seq->id."\n".$sequence."\n";
  }
  close $fh;

  return $newFasta;
}

sub mlstColorId{
  my($dir, $mlstFasta, $settings)=@_;
  my $sampleInfo=samplesheetInfo_tsv("$dir/samples.tsv",$settings);

  my $coloridDir = "$dir/SneakerNet/colorid";

  my $peTxt = "$coloridDir/PE.tsv";
  open(my $fh, ">", $peTxt) or die "ERROR writing to $peTxt: $!";
  while(my($sample,$info)=each(%$sampleInfo)){
    # for f in *.fastq.gz; do echo ${f%.fastq.gz}$'\t'$f >> PE.txt; done
    print $fh join("\t", $sample, @{ $$info{fastq} })."\n";
  }
  close $fh;
  
  my $indexPrefix = "$coloridDir/colorid";
  if(! -e "$indexPrefix.bxi"){
    # ./colorid_Centos64  build -b ST8 -s 30000000 -n 2 -k <preferred k-mer size> -t 10 -r PE.txt  
    logmsg "colorid build => $indexPrefix.bxi";
    system("colorid build -b $coloridDir/tmp -s 30000000 -n 2 -k $$settings{k} -t $$settings{numcpus} -r $peTxt 2> $coloridDir/build.log 1>&2");
    die "ERROR with colorid build. Here is the log:\n".`cat $coloridDir/build.log` if $?;
    mv("$coloridDir/tmp.bxi","$indexPrefix.bxi") or die "ERROR moving $coloridDir/tmp.bxi => $indexPrefix.bxi: $!";
  }

  # ./colorid_Centos64 search -b ST8.bxi -q ../Schemes/*.fasta -m -s > test_7gene.txt
  my $coloridResults = "$coloridDir/hits.tsv";
  if(! -e $coloridResults){
    logmsg "colorid search => $coloridResults";
    system("colorid search -b $indexPrefix.bxi -q $mlstFasta -m -s > $coloridResults.tmp 2>$coloridDir/search.log");
    die "ERROR with colorid search. Here is the log:\n".`cat $coloridDir/search.log` if $?;
    mv("$coloridResults.tmp", $coloridResults) or die "ERROR: could not move $coloridResults.tmp => $coloridResults: $!";
  }

  # Parse allele hits for each sample/locus
  my %allele;
  my %locusIndex;
  open(my $hitsFh, "<", $coloridResults) or die "ERROR: could not open $coloridResults: $!";
  while(<$hitsFh>){
    chomp;
    my($schemeLocusAllele, $sample, $bp, $percentage) = split /\t/;
    my($scheme, $locus, $allele);
    if($schemeLocusAllele =~ /(.+)\.(.+?)[_-](\d+)/){
      $scheme = $1;
      $locus  = $2;
      $allele = $3;
    } else {
      die "ERROR: could not parse scheme/locus/allele from $schemeLocusAllele";
    }
    push(@{ $allele{$sample}{$scheme}{$locus} }, $allele);
    $locusIndex{$locus}=1;
  }
  close $hitsFh;

  # Are there any loci on any samples with multiple alleles?
  my $contaminationReport = "$coloridDir/colorid.tsv";
  open(my $reportFh, ">", $contaminationReport) or die "ERROR writing to $contaminationReport: $!";
  my @locus = sort keys(%locusIndex);
  print $reportFh join("\t","Sample", "Scheme", "NumLociFound", "questionableLoci")."\n";
  for my $sample(sort keys(%allele)){
    my $is_contaminated=0;
    for my $scheme(sort keys(%{ $allele{$sample} })){
      # Is this the right scheme? See if we have >=5 loci.
      my $numLoci = scalar(keys(%{ $allele{$sample}{$scheme} }));
      if($numLoci < 5){
        next;
      }

      # Since we have five or more loci, proceed with the report.
      print $reportFh $sample."\t".$scheme;
      my $numLociWithOneAllele=0;
      for my $locus(@locus){
        my $sampleLocusAllele = $allele{$sample}{$locus} || [];
        my $numAlleles = scalar(@$sampleLocusAllele);
        #print $reportFh "\t".$numAlleles;
        if($numAlleles == 1){
          $numLociWithOneAllele++;
        } elsif($numAlleles > 1){
          $is_contaminated = 1;
          #logmsg "Found multiple alleles for $sample/$locus: ".join(", ",@$sampleLocusAllele);
        }
      }
      print $reportFh "\t", $numLoci;
      last; # only report one scheme
    }
    print $reportFh "\t", $is_contaminated;
    print $reportFh "\n";
  }

  print $reportFh "# This analysis searches for conserved MLST loci in an attempt to find multiple alleles.\n";
  print $reportFh "# In preliminary testing, this tool was able to detect as low as 6% contamination.\n";
  close $reportFh;

  logmsg "Cleaning up large files";
  unlink("$indexPrefix.bxi");

  return $contaminationReport;
}

sub usage{
  "Guesses if there is contamination in a miseq run by detecting how many alleles of 7-gene MLST genes there are
  Usage: $0 MiSeq_run_dir
  --numcpus 1
  --mlstfasta mlst.fa  The mlst.fa file in Torsten's mlst package
  --k   kmer length
  "
}
