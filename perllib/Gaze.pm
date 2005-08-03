#!/usr/bin/perl
#
# Gaze.pm:
# Common code for global gazetteer.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Gaze.pm,v 1.8 2005-08-03 15:26:23 francis Exp $
#

package Gaze;

use strict;

use utf8;

use mySociety::Config;
use mySociety::DBHandle qw(dbh);
use Geo::IP;
use POSIX qw(acos);
use Search::Xapian qw(:ops);

BEGIN {
    mySociety::DBHandle::configure(
            Name => mySociety::Config::get('GAZE_DB_NAME'),
            User => mySociety::Config::get('GAZE_DB_USER'),
            Password => mySociety::Config::get('GAZE_DB_PASS'),
            Host => mySociety::Config::get('GAZE_DB_HOST', undef),
            Port => mySociety::Config::get('GAZE_DB_PORT', undef)
        );
}

use constant name_part_size => 3;

=head1 NAME

Gaze

=head1 DESCRIPTION

Implementation of Gaze

=head1 FUNCTIONS

=over 4

=cut

# split_name_parts NAME
#
# Given the NAME of a place, return a reference to a hash mapping "name parts"
# (substrings, essentially) of that name to the number of times they occur in
# it.
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
    my @words = split(/[^[:alpha:]0-9]+/, $name);
    foreach (@words) {
        next if (length($_) == 0);
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

=item find_places COUNTRY STATE QUERY [MAXRESULTS]

Search for places in COUNTRY (ISO code) which match the given search QUERY.
STATE, if specified, is a customary code for a top-level administrative
subregion within the given COUNTRY; at present, this is only useful for the
United States, and should be passed as undef otherwise.  Returns a reference to
a list of [NAME, IN, NEAR, LATITUDE, LONGITUDE]. When IN is defined, it gives
the name of a region in which the place lies; when NEAR is defined, it gives a
short list of other places near to the returned place. These allow nonunique
names to be disambiguated by the user.  LATITUDE and LONGITUDE are in decimal
degrees, north- and east-positive, in WGS84. Earlier entries in the returned
list are better matches to the query. At most MAXRESULTS (default, 10) results
are returned. On error, throws an exception.

=cut
sub find_places ($$$;$) {
    my ($country, $state, $query, $maxresults) = @_;
    $maxresults ||= 10;

    # Xapian databases for different countries.
    our %X;
    $X{$country} ||= new Search::Xapian::Database(mySociety::Config::get('GAZE_XAPIAN_INDEX_DIR') . "/gazeidx-$country");
    my $X = $X{$country};

    # Collect matches from Xapian. In the case where we are searching with a
    # state as well as a country, we may need to expand the number of results
    # requested in order to find all those relevant (because matches for, say,
    # Brooklyn, NY may be crowded out by matches for Brooklyns not in NY).
    my ($match_start, $match_num);

    # We coalesce matches by UFI for the case where there are several names per
    # feature. For each feature we record the highest-scoring matching UNI, its
    # score, and whether the matched name was the primary name.
    my %uni;
    my %score;
    my %isprimary;

    my $terms = Gaze::split_name_parts($query);
    my $enq = $X->enquire(OP_OR, keys(%$terms));

    while (keys(%score) < $maxresults) {
        if (!defined($match_start)) {
            $match_start = 0;
            $match_num = $maxresults;
        } else {
            $match_start += $match_num;
            $match_num += int($match_num / 2);
        }
        my @matches = $enq->matches($match_start, $match_num);

        last if (@matches == 0);

        foreach my $match (@matches) {
            my $score = $match->get_percent();
            my $uni = $match->get_document()->get_data();
            my ($ufi, $isprimary);
            if ($state) {
                ($ufi, $isprimary) = dbh()->selectrow_array('select ufi, is_primary from name where uni = ? and (select state from feature where feature.ufi = name.ufi) = ?', {}, $uni, $state);
            } else {
                ($ufi, $isprimary) = dbh()->selectrow_array('select ufi, is_primary from name where uni = ?', {}, $uni);
            }
            if (defined($ufi) && (!exists($score{$ufi}) || $score{$ufi} < $score)) {
                $score{$ufi} = $score;
                $uni{$ufi} = $uni;
                $isprimary{$ufi} = $isprimary;
            }
        }
    }

    my @results;
    foreach my $ufi (sort { $score{$b} <=> $score{$a} || $isprimary{$b} <=> $isprimary{$a} } keys(%score)) {
        push(@results, [dbh()->selectrow_array('select full_name, in_qualifier, near_qualifier, lat, lon from feature, name where feature.ufi = name.ufi and feature.ufi = ? and is_primary', {}, $ufi)]);
        last if (@results == $maxresults);
    }
    return \@results;
}

=item get_country_from_ip ADDRESS

Return the country code for the given IP address, or undef if none could be
found.

=cut
sub get_country_from_ip ($) {
    my ($addr) = @_;
    return undef if $addr eq '127.0.0.1';
    our $geoip;
    $geoip ||= new Geo::IP(GEOIP_STANDARD);
    my $country = $geoip->country_code_by_addr($addr);
    # warn "ip: $addr country: $country";
    return $country;
}

# Some conveniences for the parser.

# strip_punctuation NAME
# Remove punctuation from NAME. This is used to broaden our search for
# ambiguous names; we want to treat, e.g., "St Peters" as ambiguous with "St.
# Peter's", or "Le Petit-Paris" with "Le Petit Paris".
sub strip_punctuation ($) {
    my $t = shift;
    $t =~ s#[^[:alpha:][0-9]]##g; # [0-9] because US place names quite commonly contain numbers
    return $t;
}

use constant R_e => 6372.8; # radius of the earth in km
use constant M_PI => 3.141592654;

# rad DEGREES
# Return DEGREES in radians.
sub rad ($) {
    return M_PI * $_[0] / 180.;
}

# deg RADIANS
# Return RADIANS in degrees.
sub deg ($) {
    return 180. * $_[0] / M_PI;
}

# distance LAT1 LON2 LAT2 LON2
# Return the great-circle distance between (LAT1, LON1) and (LAT2, LON2).
sub distance ($$$$) {
    my ($lat1, $lon1, $lat2, $lon2) = map { rad($_) } @_;
    my $arg = sin($lat1) * sin($lat2) + cos($lat1) * cos($lat2) * cos($lon1 - $lon2);
    return 0 if (abs($arg) > 1); # XXX "shouldn't happen", but sometimes does when passed two equal places
    return R_e * acos(sin($lat1) * sin($lat2) + cos($lat1) * cos($lat2) * cos($lon1 - $lon2));
}

1;
