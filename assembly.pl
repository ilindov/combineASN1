#!/usr/bin/perl

use strict;
use warnings;


my $inFile = $ARGV[0];
my $outFile = $ARGV[1];

my $outFH;
my %existingElements = ();
my %existingFileElements = ();

my @baseTypes = (	"BOOLEAN",
					"INTEGER",
					"BIT STRING",
					"CHOICE",
					"EMBEDDED PDV",
					"ENUMERATED",
					"EXTERNAL",
					"OID-IRI",
					"NULL",
					"OBJECT IDENTIFIER",
					"OCTET STRING",
					"REAL",
					"RELATIVE-OID-IRI",
					"SEQUENCE",
					"SEQUENCE OF",
					"SET",
					"SET OF",
					"TIME",
					"BMPString",
					"GeneralString",
					"GraphicString",
					"IA5String",
					"ISO646String",
					"NumericString",
					"PrintableString",
					"TeletexString",
					"T61String",
					"UniversalString",
					"UTF8String",
					"VideotexString",
					"VisibleString");


if (!defined($inFile) or !defined($outFile)) {
	print "Usage: assembly.pl <ASN.1_input_file> <ASN.1_output_file>\n";
	exit(1);
}

open($outFH, ">".$outFile) or die ("Unable to open output file: ".$outFile."\n");
processFile($inFile, 0);
print $outFH "\nEND\n";
close($outFH);

sub processFile {
	my $fileName = $_[0];
	my $recursionLevel = $_[1];
	my @fields = @{$_[2]} if (defined($_[2]));

	my $importsFlag = 0;
	my $importsStrTmp = "";
	my $importsStr = "";
	my $nextRowBuffer = "";
	my %imports = ();

	my $element = "";
	my $elementName = "";
	my %elementsInFile = ();
	my $awaitingOpeningBracket = 0;
	my @secondaryDeps = ();
	my %dependencyChecked = ();

	print "-- Start file: '", $fileName, "'\n\n";
	print $outFH "-- Start file: '", $fileName, "'\n\n";

	open(INFILE, "<".$fileName) or die ("Unable to open input file: ".$fileName."\n");
	while (<INFILE>) {
		my $row = $_;
		chomp($row);
		next if (!$row or $row =~ /^\s+$/ or $row =~ /^\s*END\s*$/);
		
		if ($nextRowBuffer) {
			$row = $nextRowBuffer." ".$row;
			$nextRowBuffer = "";
		}

		# Clean comments
		next if ($row =~ /^\s*--.*$/);
		$row = $1 if ($row =~ /(.*)--.*/);

		# IMPORTS
		if (!$importsFlag and $row =~ /((^\s*)|(\s+))IMPORTS((\s*$)|(\s+\S+.*$))/) {
			$importsStrTmp .= $4." ";
			$importsFlag = 1;
			next;
		}
		elsif ($importsFlag) {
			if ($row =~ /(.*);((\s*)|(\s*\S+.*))$/) {
				$importsStrTmp .= $1." ";
				$nextRowBuffer = $4;
				$importsFlag = 0;
				$importsStr = $importsStrTmp;
			}
			else {
				$importsStrTmp .= $row." ";
			}
			next;
		}

		if ($importsStr) {
			my $fromIndex = index($importsStr, " FROM ");

			while ($fromIndex != -1) {
				my $fieldsStr = substr($importsStr, 0, $fromIndex);
				$fieldsStr =~ s/\s//g;
				$importsStrTmp = substr($importsStr, $fromIndex + 6, length($importsStr));
				$importsStr = $importsStrTmp;
				my $definition = "";
				if ($importsStr =~ /^\s*(\S+)\s+(.*)$/) {
					$definition = $1;
					$importsStr = $2;
				}

				my @currentFields = split(",", $fieldsStr);
				@currentFields = sort(@currentFields);
				if ($recursionLevel) {
					# TODO: remove all unneeded imports fields
				}
				$imports{$definition} = \@currentFields;

				$fromIndex = index($importsStr, " FROM ");
			}
		}
		# IMPORTS END

		if ($row =~ /^\s*(\S+)\s*::=.*/) {
			if (!$recursionLevel) {
				checkDuplicate($1);
				$existingFileElements{$fileName.':-:'.$1} = 1;
			}

			if ($element and $elementName) {
				$elementsInFile{$elementName} = $element;
				$element = "";
			}

			$elementName = $1;
			if ($row =~ /\{/ and $row =~ /\}/) {
				$elementsInFile{$elementName} = $row;
				$element = "";
			}
			else {
				$element = $row;
			}
		}
		elsif ($row =~ /\}/) {
			$element .= "\n".$row;
			$elementsInFile{$elementName} = $element;
			$element = "";
		}
		else {
			$element .= "\n".$row;
		}

		print $outFH $row, "\n" if (!$recursionLevel);
	}
	close(INFILE);

	if ($element) {
		$elementsInFile{$elementName} = $element;
		$element = "";
	}


	# Building seconsdary deps for 0 level
	if (!$recursionLevel) {
		foreach my $key (sort(keys(%elementsInFile))) {
			push(@secondaryDeps, @{getDependencies($elementsInFile{$key})});
			$dependencyChecked{$key} = 1;
		}
	}

	# Adding imported fields
	foreach my $field (@fields) {
		if (!$elementsInFile{$field}) {
			print STDERR "Imported element '", $field, "' missing in file '", $fileName, "'\n";
			exit(2);
		}

		if (!$existingFileElements{$fileName.':-:'.$field}) {
			checkDuplicate($field);
			print $outFH $elementsInFile{$field}, "\n";
			$existingFileElements{$fileName.':-:'.$field} = 1;
		}
		
		# Building seconsdary deps for 1+ levels
		if ($recursionLevel) {
			push(@secondaryDeps, @{getDependencies($elementsInFile{$field})});
			$dependencyChecked{$field} = 1;
		}
	}

	# Checking and filling dependencies
	DEPCHECK:
	uniq(\@secondaryDeps);
	foreach my $element (@secondaryDeps) {
		if (!$elementsInFile{$element}) {
			my $match = 0;
			DEFINITIONS:
			foreach my $definition (sort(keys(%imports))) {
				foreach my $importedElement (@{$imports{$definition}}) {
					if ($importedElement eq $element) {
						$match = 1;
						last DEFINITIONS;
					}
				}
			}
			if(!$match) {
				print STDERR "ERROR: Unsatisfied dependency for: '", $element, "'\n";
				exit(16);
			}
		}
		elsif ($recursionLevel and !$existingFileElements{$fileName.':-:'.$element}) {
			checkDuplicate($element);
			print $outFH $elementsInFile{$element}, "\n";
			$existingFileElements{$fileName.':-:'.$element} = 1;
			if (!$dependencyChecked{$element}) {
				push(@secondaryDeps, @{getDependencies($elementsInFile{$element})});
				$dependencyChecked{$element} = 1;
				goto(DEPCHECK);
			}
		}
	}

	print "\n\n-- End file: '", $fileName, "'\n\n";
	print $outFH "\n\n-- End file: '", $fileName, "'\n\n";

	# Removing unneeded imports
	foreach my $definition (sort(keys(%imports))) {
		my @filteredArray = ();

		foreach my $importedElement (@{$imports{$definition}}) {
			foreach my $neededElement (@secondaryDeps) {
				if ($importedElement eq $neededElement) {
					push(@filteredArray, $importedElement);
					last;
				}
			}
		}

		$imports{$definition} = \@filteredArray;
	}

	foreach my $key (sort(keys(%imports))) {
		processFile($key.".asn", ++$recursionLevel, $imports{$key});
	}
}

sub checkDuplicate {
	my $elementName = shift;

	if ($existingElements{$elementName}) {
		my $msg = "WARNING: Duplicate element: '". $elementName. "'\n";
		print STDERR $msg;
		print $outFH "\n-- ", $msg;
	}
	else {
		$existingElements{$elementName} = 1;
	}
}

sub getDependencies {
	my $element = shift;

	my @list = ();

	$element =~ s/\n//g;

	if (($element =~ /\{/ and $element !~ /\}/)
		or ($element =~ /\}/ and $element !~ /\{/)) {
		print STDERR "ERROR: Corrupted element: \n", $element;
		exit(4);
	}

	if ($element =~ /\{(.*)\}/) {
		my @subElements = split(/,/, $1);
		foreach my $subElement (@subElements) {

			if ($subElement =~ /^\s*([\w\-_]+)\s*<?\s*(((\[\d+\])\s*<?\s*)|(\s*<?\s+))(SEQUENCE\s+OF|SET\s+OF)\s+([\w\-_]+)/
			 or $subElement =~ /^(\s*)([\w\-_]+)\s*<?\s*(((\[\d+\])\s*<?\s*)|(\s*<?\s+))(BIT\s+STRING|EMBEDDED\s+PDV|OBJECT\s+IDENTIFIER|OCTET\s+STRING|[\w\-_]+)/) {
				my $type = $7;
				$type =~ s/\s+/ /g;
				my $match = 0;
				foreach my $baseType (@baseTypes) {
					if ($type eq $baseType) {
						$match = 1;
						last;
					}
				}
				if (!$match) {
					push(@list, $type);
				}
			}
		}
	}
	elsif ($element =~ /::=\s*(SEQUENCE\s+OF|SET\s+OF)\s+([\w\-_]+)/
		or $element =~ /(::=)\s*(BIT\s+STRING|EMBEDDED\s+PDV|OBJECT\s+IDENTIFIER|OCTET\s+STRING|[\w\-_]+)/) {
		my $type = $2;
		$type =~ s/\s+/ /g;
		my $match = 0;
		foreach my $baseType (@baseTypes) {
			if ($type eq $baseType) {
				$match = 1;
				last;
			}
		}
		if (!$match) {
			push(@list, $type);
		}
	}
	else {
		print STDERR "Non-parseable dependency: '", $element, "'\n";
		exit(8);
	}

	return \@list;
}

sub uniq {
	my $ref = shift;

	@$ref = sort(@$ref);

	my $prev = "";
	for (my $i = 0; $i < scalar @$ref; $i++) {
		splice(@$ref, $i--, 1) if ((@$ref)[$i] eq $prev);
		$prev = (@$ref)[$i];
	}
}

