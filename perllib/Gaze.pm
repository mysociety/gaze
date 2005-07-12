#!/usr/bin/perl
#
# Gaze.pm:
# Common code for global gazetteer.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Gaze.pm,v 1.2 2005-07-12 17:35:27 chris Exp $
#

package Gaze;

use strict;

use constant name_part_size => 3;

=item split_name_parts NAME

Given the NAME of a place, return a reference to a hash mapping "name parts"
(substrings, essentially) of that name to the number of times they occur in it.

=cut
sub split_name_parts ($) {
    my $name = lc(shift);
    #
    # For each part, we increment the corresponding counter in %parts. For a
    # name part on a word boundary, we upper-case the corresponding character
    # and insert the generated part as well. So, for instance, from the name
    # "Great Wilbraham", we would generate the parts,
    #   gre Gre rea eat eaT wil Wil ilb lbr bra rah aha ham haM
    # Individual words shorter than name_part_size are treated as single parts,
    # so that "of" becomes,
    #   of Of oF
    #
    my %parts;
    my @words = split(/[^[:alpha:]]+/, $name);
    foreach (@words) {
        if (length($_) <= name_part_size) {
            ++$parts{$_};
            if (length($_) > 1) {
                ++$parts{uc(substr($_, 0, 1)) . substr($_, 1)};
                ++$parts{substr($_, 0, length($_) - 1) . uc(substr($_, -1))};
            }
        } else {
            ++$parts{substr($_, 0, name_part_size)};
            ++$parts{uc(substr($_, 0, 1)) . substr($_, 1, name_part_size - 1)};
            for (my $i = 1; $i < length($_) - name_part_size; ++$i) {
                ++$parts{substr($_, $i, name_part_size)};
            }
            ++$parts{substr($_, - name_part_size)};
            ++$parts{substr($_, - name_part_size, name_part_size - 1) . uc(substr($_, -1))};
        }
    }

    return \%parts;
}

=item find_places COUNTRY TERM

Search for places in COUNTRY (ISO code) which match the given search TERM.

=cut
sub find_places ($$) {
}

1;
