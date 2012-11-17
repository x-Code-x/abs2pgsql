#!/usr/bin/perl -w

# This file is licensed CC0 by Andrew Harvey <andrew.harvey4@gmail.com>
#
# To the extent possible under law, the person who associated CC0
# with this work has waived all copyright and related or neighboring
# rights to this work.
# http://creativecommons.org/publicdomain/zero/1.0/

use strict;
use autodie;
use Text::CSV;
use DBI;

my $structure;
my $profile;
my $release;

my %profile_fullname = (
  "BCP" => "Basic Community Profile",
  "IP" => "Aboriginal and Torres Strait Islander Peoples Profile",
  "TSP" => "Time Series Profile"
);

if (@ARGV >= 3) {
  $release = $ARGV[0];
  $structure = uc($ARGV[1]);
  $profile = uc($ARGV[2]);
}else{
  print STDERR "Usage: $0 <ASGS_Structure> <Census_Profile>\n";
  exit 1;
}

my $dbh = DBI->connect("DBI:Pg:", '', '' , {'RaiseError' => 1, AutoCommit => 1});

my %loads;
my %loads_multiple_values;

# read through the lines generated by 04-prepare-from-expansion.pl
for my $line (<STDIN>) {
  chomp $line;
  # and unless it is a comment or empty line...
  unless (($line =~ /^#/) || ($line =~ /^\s*$/)) {
    # "parse" the line
    if ($line =~ /^([^\s]+) ([^\s]+) ([^\s]+)$/) {
      my ($seq, $file, $table) = ($1, $2, $3);
      my @seqs = split(/,/, $seq);
      # if the table for the line read is for the same profile as the program was invoked with
      if (lc(substr($table, 0, 1)) eq lc(substr($profile, 0, 1))) {
        $loads_multiple_values{$file}->{$table} = \@seqs;
      }
    }elsif ($line =~ /^(\w\d+) ([^\s]+) ([^\s]+) (.*)$/) {
      my ($seq, $file, $table, $insert) = ($1, $2, $3, $4);
      my @insert_values = split(/\t/, $insert);

      # change NULL into \N which COPY will interpret as a NULL value
      map { s/NULL/\\N/g } @insert_values;

      # if the table for the line read is for the same profile as the program was invoked with
      if (lc(substr($table, 0, 1)) eq lc(substr($profile, 0, 1))) {
        if (!exists $loads{$file}) {
          $loads{$file} = {};
        }
        $loads{$file}->{$seq} = [$table, \@insert_values];
      }
    }else{
      warn "Map file line of unexpected format: $line\n";
    }
  }
}

# open each DataPack file
for my $file (sort (keys %loads, keys %loads_multiple_values)) {
  my $state_to_load = "AUST"; # for example changing this to NSW will just load data for the regions which fall in NSW

  my $state_to_load_directory = "";
  my $state_to_load_path = "";
  if ((uc $structure) ne "AUST") {
    $state_to_load_directory = "${state_to_load}/";
    $state_to_load_path = "${state_to_load}_";
  }

  open (my $datapack_file, '<', "DataPacks/2011 ". $profile_fullname{$profile} . " Release $release/Sequential Number Descriptor/$structure/${state_to_load_directory}2011Census_${file}_${state_to_load_path}${structure}_sequential.csv");

  # read in this datapack file as a CSV file
  my $csv = Text::CSV->new();
  $csv->column_names($csv->getline($datapack_file));
  my %datapack;

  while (my $row = $csv->getline_hr($datapack_file)) {
    # and for each seq id which we need to insert data for
    my @seqs_for_multiple_values;
    if (exists $loads_multiple_values{$file}) {
      for my $t (keys %{$loads_multiple_values{$file}}) {
         push @seqs_for_multiple_values, @{$loads_multiple_values{$file}->{$t}};
      }
    }
    for my $seq ('region_id', keys (%{$loads{$file}}), @seqs_for_multiple_values) {
      # add the data from this line in the CSV file to the hash
      push @{$datapack{$seq}}, $row->{$seq};
    }
  }
  close $datapack_file or warn $!;

  # for each seq id...
  if (exists $loads{$file}) {
    for my $seq (sort keys %{$loads{$file}}) {
      print "  $profile $structure $file $seq\n";

      # ...COPY all the values for each region in this $structure for the current $seq id into the database
      $dbh->do("COPY census_2011." . $loads{$file}->{$seq}->[0] . "_$structure FROM STDIN;");

      for (my $i = 0; $i < scalar @{$datapack{$seq}}; $i++) {
        my $region_id = $datapack{'region_id'}->[$i];
        $region_id =~ s/^(CED|LGA|POA|SED|SSC|IARE|ILOC|IREG)//;
        my $insert_value = $datapack{$seq}->[$i];
        $insert_value =~ s/\.\./\\N/;
        $dbh->pg_putcopydata("$region_id\t" . join("\t", @{$loads{$file}->{$seq}->[1]}) . "\t$insert_value\n");
      }

      $dbh->pg_putcopyend() or die $!;
    }
  }
  
  if (exists $loads_multiple_values{$file}) {
    my @tables = keys %{$loads_multiple_values{$file}};
    # FIXME assert tables contains 1 or more values or the same values.
    my @seqs = @{$loads_multiple_values{$file}->{$tables[0]}};
    print "  $profile $structure $file " . join (",", @seqs) . "\n";
    $dbh->do("COPY census_2011." . $tables[0] . "_$structure FROM STDIN;");
    
    # for each row
    for (my $i = 0; $i < scalar @{$datapack{$seqs[0]}}; $i++) {
        my $region_id = $datapack{'region_id'}->[$i];
        $region_id =~ s/^(CED|LGA|POA|SED|SSC|IARE|ILOC|IREG)//;
        
        my @insert_values;
        for my $s (@seqs) {
          push @insert_values, $datapack{$s}->[$i];
        }
        map { s/\.\./\\N/; } @insert_values;
        $dbh->pg_putcopydata("$region_id\t" . join("\t", @insert_values) . "\n");
      }
    
    $dbh->pg_putcopyend() or die $!;
  }
}

$dbh->disconnect or warn $!;
