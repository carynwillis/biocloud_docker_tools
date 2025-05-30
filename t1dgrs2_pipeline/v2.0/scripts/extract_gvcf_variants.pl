#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use constant FALSE => 0;
use constant TRUE  => 1;

# Autoflush STDOUT
select((select(STDOUT), $|=1)[0]);

my $sample_id = '';
my $gvcf = '';
my $variant_list = '';
my $hladq_variants_file = '';
my $non_hladq_variants_file = '';
my $out_prefix;
my $filter_by_qual = 0;
my $filter_by_gq = 0;
my $hom_gq_threshold = 99;
my $het_gq_threshold = 48;

GetOptions (
    'sample_id=s' => \$sample_id,
    'gvcf=s' => \$gvcf,
    'variant_list=s' => \$variant_list,
    'hladq_variants_file=s' => \$hladq_variants_file,
    'non_hladq_variants_file=s' => \$non_hladq_variants_file,
    'out_prefix=s' => \$out_prefix,
    'filter_by_qual:i' => \$filter_by_qual,
    'filter_by_gq:i' => \$filter_by_gq,
    'hom_gq_threshold:i' => \$hom_gq_threshold,
    'het_gq_threshold:i' => \$het_gq_threshold,
) or die("Invalid options");

sub flip {
    my ($allele) = @_;
    my $alleleComplement = "";
    my %flipMap = (
        "A" => "T",
        "T" => "A",
        "C" => "G",
        "G" => "C",
        "-" => "-"
    );
    foreach my $nt (reverse(split("", $allele))) {
        if (!exists($flipMap{uc($nt)})) {
            $alleleComplement = $allele;
            last;
        } else {
            $alleleComplement .= $flipMap{uc($nt)};
        }
    }
    return $alleleComplement;
}

my %variant_ids = ();
my %ref_alleles = ();
my %alt_alleles = ();
my @F = ();

# Read extract file
if ($variant_list =~ /gz$/) {
    open(EXTRACT, "gunzip -c $variant_list |") or die "gunzip $variant_list: $!";
} else {
    open(EXTRACT, $variant_list);
}
while (<EXTRACT>) {
    chomp;
    @F = split();
    $variant_ids{$F[0]} = $F[1] ? $F[1] : (join(":", $F[0], $F[2], $F[3]));
    $ref_alleles{$F[0]} = $F[2];
    $alt_alleles{$F[0]} = $F[3];
}
close EXTRACT;

# Get dataset variants by position
open(OUT_VCF, "> ".$out_prefix.".vcf");
if ($gvcf =~ /gz$/) {
    open(GVCF, "gunzip -c $gvcf |") or die "gunzip $gvcf: $!";
} else {
    open(GVCF, $gvcf);
}
print "Extracting " . keys(%variant_ids). " variants from $gvcf...\n";
while(<GVCF>){
    if (/^#/) {
        if (/^#CHROM/) {
            s/\S+$/$sample_id/;
        }
        print OUT_VCF;
    } else {
        chomp;
        @F =split("\t");
        if (
            !$filter_by_qual
            || (uc($F[6]) eq "PASS")
        ) {
            if ($F[0] =~ /(\d+)$/) {
                my $chr = $1;
                my @keys = split(":", $F[8]);
                my @values = split(":", $F[9]);
                my %variantData;
                @variantData{@keys} = @values;
                $variantData{"GT"} =~ /(\d+|\.).(\d+|\.)/;
                my $sampleA1Index = $1;
                my $sampleA2Index = $2;
                $F[9] =~ s/^(\d+|\.).(\d+|\.)/$sampleA1Index|$sampleA2Index/;
                if (
                    !$filter_by_gq
                    || (
                        (
                            $sampleA1Index eq $sampleA2Index
                            && ($variantData{"GQ"} >= $hom_gq_threshold)
                        )
                        || (
                            $sampleA1Index ne $sampleA2Index
                            && ($variantData{"GQ"} >= $het_gq_threshold)
                        )
                    )
                ) {
                    if ($F[7] =~ /END=(\d+)/) {
                        my $end = $1;
                        for (my $i=$F[1]; $i<=$end; $i++) {
                            my $chrPos = $chr.":".$i;
                            if (exists($ref_alleles{$chrPos})) {
                                print OUT_VCF join("\t", $chr, $i, $variant_ids{$chrPos}, $ref_alleles{$chrPos}, $alt_alleles{$chrPos}, @F[5..6], ".", $F[8], $F[9])."\n";
                                delete($ref_alleles{$chrPos});
                            }
                        }
                    } else {
                        my $chrPos = $chr.":".$F[1];
                        if (exists($ref_alleles{$chrPos}) && $F[3] eq $ref_alleles{$chrPos}) {
                            my %sampleAlleles = ();
                            $sampleAlleles{'0'} = 1;
                            $sampleAlleles{$sampleA1Index} = 1;
                            $sampleAlleles{$sampleA2Index} = 1;
                            if (keys(%sampleAlleles) < 3) {
                                my @alleles =($F[3]);
                                push(@alleles, split(",", $F[4]));
                                if (@alleles == 3) {
                                    $F[4] = $alleles[1];
                                } else {
                                    if ($sampleA2Index != 0) {
                                        $F[4] = $alleles[$sampleA2Index];
                                    } elsif ($sampleA1Index != 0) {
                                        $F[4] = $alleles[$sampleA1Index];
                                    }
                                }
                                if ($F[4] eq $alt_alleles{$chrPos}) {
                                    print OUT_VCF join("\t", $chr, $F[1], $variant_ids{$chrPos}, @F[3..9])."\n";
                                    delete($ref_alleles{$chrPos});
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

close GVCF;
close OUT_VCF;

## Read HLA-DQ variants
my %hladq_variants = ();
open(HLA, $hladq_variants_file);
while (<HLA>) {
    chomp;
    $hladq_variants{$_} = 1;
}
close HLA;

## Read non-HLA-DQ variants
my %non_hladq_variants = ();
open(NON_HLA, $non_hladq_variants_file);
while (<NON_HLA>) {
    chomp;
    $non_hladq_variants{$_} = 1;
}
close NON_HLA;

# Write list of missing variants and count
my @missing = sort(keys(%ref_alleles));
my $missing_hladq_count = 0;
my $missing_non_hladq_count = 0;
open(OUT_MISSING, "> ".$out_prefix."_missing.txt");
if (@missing > 0) {
    print "Missing variants:\n"
}
foreach my $missing_variant (@missing) {
    print OUT_MISSING $variant_ids{$missing_variant}."\n";
    print $variant_ids{$missing_variant}."\n";
    if (exists($hladq_variants{$variant_ids{$missing_variant}})) {
        $missing_hladq_count++;
    } elsif (exists($non_hladq_variants{$variant_ids{$missing_variant}})) {
        $missing_non_hladq_count++;
    }
}
close OUT_MISSING;

# Write missingness summary
open(OUT_MISSING_SUMMARY, "> ".$out_prefix."_missing_summary.tsv");
print OUT_MISSING_SUMMARY join("\t", "SAMPLE_ID", "MISSING_HLADQ_COUNT", "MISSING_NON_HLADQ_COUNT")."\n";
print OUT_MISSING_SUMMARY join("\t", $sample_id, $missing_hladq_count, $missing_non_hladq_count)."\n";
close OUT_MISSING_SUMMARY;

print "\nExtraction complete\n"
