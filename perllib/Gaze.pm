#!/usr/bin/perl
#
# Gaze.pm:
# Common code for global gazetteer.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Gaze.pm,v 1.5 2005-07-22 13:57:40 francis Exp $
#

package Gaze;

use strict;

use utf8;

use mySociety::Config;
use mySociety::DBHandle qw(dbh);
use Geo::IP;

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
# (substrings, essentially) of that name to the number of times they occur in it.
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

=item find_places COUNTRY QUERY [MAXRESULTS]

Search for places in COUNTRY (ISO code) which match the given search QUERY.
Returns a reference to a list of [NAME, QUALIFICATION, QUALIFIER, LATITUDE,
LONGITUDE]. When NAME is unique, QUALIFICATION and QUALIFIER will be undef;
otherwise, QUALIFICATION will either be 'in' and QUALIFIER the name of an
enclosing administrative area (for instance, a state or county), or 'near' and
the names of nearby places, respectively. LATITUDE and LONGITUDE are in decimal
degrees, north- and east-positive, in WGS84. Earlier entries in the returned
list are better matches to the query. At most MAXRESULTS (default, 10) results
are returned. On error, throws an exception.

=cut
sub find_places ($$;$) {
    my ($country, $query, $maxresults) = @_;
    $maxresults ||= 10;
    my $terms = Gaze::split_name_parts($query);
    my %possibles;

    our $s ||= dbh()->prepare("
        select name_part.uni, name.ufi
        from name_part, name, feature
        where feature.ufi = name.ufi
            and name.uni = name_part.uni
            and feature.country = ?
            and namepart = ?");
        
    foreach my $t (keys %$terms) {
        my $count = dbh()->selectrow_array('
                select count(name_part.uni)
                    from name_part, name, feature
                    where namepart = ?
                        and name_part.uni = name.uni
                        and name.ufi = feature.ufi
                        and feature.country = ?',
                {}, $t, $country);
        $s->execute($country, $t);
        while (my ($uni, $ufi) = $s->fetchrow_array()) {
            $possibles{$ufi}->{$uni} += $terms->{$t} / $count;
        }
    }

    # Use as the score for each place the best score for any of its names.
    foreach my $ufi (keys %possibles) {
        my ($bestuni, $maxscore);
        foreach my $uni (keys %{$possibles{$ufi}}) {
            if (!defined($bestuni) || $possibles{$ufi}->{$uni} > $maxscore) {
                $bestuni = $uni;
                $maxscore = $possibles{$ufi}->{$uni};
            }
        }
        $possibles{$ufi} = [$maxscore, $bestuni];
    }

    my @r = ( );
    my @ufis = sort { $possibles{$b}->[0] <=> $possibles{$a}->[0] } keys %possibles;
    for (my $i = 0; $i < $maxresults && $i < @ufis; ++$i) {
        my $name = dbh()->selectrow_array('select full_name from name where is_primary and ufi = ?', {}, $_);
        my ($qt, $q, $lat, $lon) = dbh()->selectrow_array('select qualifier_type, qualifier, lat, lon from feature where ufi = ?', {}, $_);
        push(@r, [$name, $qt, $q, $lat, $lon]);
    }

    return \@r;
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

1;
