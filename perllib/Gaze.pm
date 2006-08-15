#!/usr/bin/perl
#
# Gaze.pm:
# Common code for global gazetteer.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Gaze.pm,v 1.29 2006-08-15 19:08:09 chris Exp $
#

package Gaze;

use strict;

use utf8;

use mySociety::Config;
use mySociety::DBHandle qw(dbh);
use Geo::IP;
use POSIX qw(acos);
use Search::Xapian qw(:ops);
use File::Find;

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

=item find_places COUNTRY STATE QUERY [MAXRESULTS [MINSCORE]]

Search for places in COUNTRY (ISO code) which match the given search QUERY.
The country must be from the list returned by get_find_places_countries.
STATE, if specified, is a customary code for a top-level administrative
subregion within the given COUNTRY; at present, this is only useful for the
United States, and should be passed as undef otherwise.  

Returns a reference to a list of [NAME, IN, NEAR, LATITUDE, LONGITUDE, STATE, SCORE].
When IN is defined, it gives the name of a region in which the place lies; when
NEAR is defined, it gives a short list of other places near to the returned
place.  These allow nonunique names to be disambiguated by the user.  LATITUDE
and LONGITUDE are in decimal degrees, north- and east-positive, in WGS84.
Earlier entries in the returned list are better matches to the query. 

At most MAXRESULTS (default, 20) results, and only results with score at least
MINSCORE (default 0, percentage from 0 to 100) are returned. The MAXRESULTS
limit is ignored when the top results all have the same relevancy. They are all
returned. So for example, this means that if you search for Cambridge in the US
with MAXRESULTS of 5, it will return all the Cambridges, even though there
are more than 5 of them.

On error, throws an exception.

=cut
sub find_places ($$$;$$) {
    my ($country, $state, $query, $maxresults, $minscore) = @_;
    $maxresults ||= 10;
    $minscore ||= 0;
    throw RABX::Error("Country code must be exactly two capital letters", RABX::Error::USER)
        unless ($country =~ m/^[A-Z][A-Z]$/);

    # Xapian databases for different countries.
    our %X;
    my $countryxapiandb = mySociety::Config::get('GAZE_XAPIAN_INDEX_DIR') . "/gazeidx-$country";
    throw RABX::Error("Gazeteer not available for $country", RABX::Error::USER)
        if (!-d $countryxapiandb);
    $X{$country} ||= new Search::Xapian::Database($countryxapiandb);
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

    # grab more than maxresults from xapian, so we can show all those with
    # same highest score (e.g. there are about 30 Cambridges)
    my $xapian_maxresults = $maxresults + 100; 
    while (keys(%score) < $xapian_maxresults) {
        if (!defined($match_start)) {
            $match_start = 0;
            $match_num = $xapian_maxresults;
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
    my $first_score;
    foreach my $ufi (sort { $score{$b} <=> $score{$a} || $isprimary{$b} <=> $isprimary{$a} } keys(%score)) {
        # Stop when we 
        # - exceed max results AND
        # - we have shown all the entries with the highest score (this makes
        #   sure all towns with same name get shown)
        last if ($first_score && $score{$ufi} < $first_score && @results >= $maxresults);
        last if ($score{$ufi} < $minscore);
        push(@results, [dbh()->selectrow_array('select full_name, in_qualifier, near_qualifier, lat, lon, state, ?::int from feature, name where feature.ufi = name.ufi and feature.ufi = ? and is_primary', {}, $score{$ufi}, $ufi)]);
        $first_score = $score{$ufi} if !$first_score;
    }

    # XXX suggestion from Mark: in the case where the best matches have the
    # same name, we should promote the one which has a higher population
    # density (or smaller radius-containing-N), as this is more likely to be
    # the right one.

    return \@results;
}

=item get_find_places_countries

Return list of countries which find_places will work for.

=cut
sub get_find_places_countries() {
    my $xapiandb_directory = mySociety::Config::get('GAZE_XAPIAN_INDEX_DIR');

    my @countries;
    opendir(DIRHANDLE, $xapiandb_directory) or die "Couldn't opendir $xapiandb_directory";
    while (defined($_ = readdir(DIRHANDLE))) {
        if (m/^gazeidx-([A-Z][A-Z])$/) {
            push @countries, $1;
        }
    };
    closedir(DIRHANDLE);
    return \@countries;
}

=item get_country_from_ip ADDRESS

Return the country code for the given IP address, or undef if none could be
found.

=cut
sub get_country_from_ip ($) {
    my ($addr) = @_;
    return undef if ($addr =~ /^127\./);
    our $geoip;
    $geoip ||= new Geo::IP(GEOIP_STANDARD);
    my $country = $geoip->country_code_by_addr($addr);
    # GeoIP may also return "continent codes", in the case of addresses for
    # which a proper country code is not available. These are of almost no
    # value to us, so suppress them.
    my %continent = map { $_ => 1 } qw(AF AN AS EU NA OC SA);
    $country = undef if (defined($country) && exists($continent{$country}));
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

 
=item get_country_bounding_coords COUNTRY

Returns a 4 element list containing the latitude of the most northerly and
southernly places, and the longitude of the most easterly and westerly places
in COUNTRY. (NB these will always lie *inside* the true bounding coordinates
of the COUNTRY itself.)

=cut
sub get_country_bounding_coords ($) {
    my $country = shift;
    throw RABX::Error("Country code must be exactly two capital letters", RABX::Error::USER)
        unless ($country =~ m/^[A-Z][A-Z]$/);
    my ($max_lat, $min_lat, $max_long, $min_long)
        dbh()->selectrow_array('
                select max(lat), min(lat), max(lon), min(lon)
                from feature
                where country = ?', {}, $country);
    throw RABX::Error("No bounds known for country '$country'")
        unless (defined($max_lat));
    return [$max_lat, $min_lat, $max_long, $min_long];
}

#
# Gridded Population of the World stuff
#

package Gaze::GPW;

use Geo::Distance;
use IO::File;
use POSIX qw(acos asin);

#
# We use two GPW data files: one generated from the population density data,
# and one from the whole population of each cell. The reason that both are
# required is that GPW computes for each cell of the grid a land area, and its
# measure of the population density is the population of the cell *divided by
# that land area*. So where (say) a small island is the only land in a given
# cell, GPW will record the population of the island, the area of the island,
# and *the population density of the island itself* -- not the population of
# the island divided by the area of the cell. This means that point estimates
# of the population density are likely to be correct -- because in most cases
# we will be asking for the population density of a place where there is known
# to be population -- but if we want to integrate up the whole population the
# GPW-recorded population density is NOT the right function to use. Instead we
# need to smear the population out over the whole of each cell, because when
# sampling the integrand we have no a priori knowledge of whether an individual
# point lands on a populated place or not.
#

# Filehandles and data offsets for density and population data dumps.
my ($f_d, $f_p);
my ($datastart_d, $datastart_p);
my $path;
my ($west, $east, $south, $north, $xpitch, $ypitch, $cols, $rows);
my $blurb_string = <<EOF;
Gaze population density file -- DO NOT EDIT
EOF

# read_gpw_data
# Open the GPW data files.
sub read_gpw_data () {
    return if ($f_d && $f_p);
    $path = mySociety::Config::get('GAZE_GPW_DATA_DIR');
    $f_d = new IO::File("$path/density.data", O_RDONLY) 
                || die "$path/density.data: open: $!";
    # Grab data about the grid.
    my $len = length(pack('ddddddII', qw(0 0 0 0 0 0 0 0)));
    $f_d->seek(length($blurb_string), SEEK_SET)
                || die "$path/density.data: lseek: $!";
    my $header = '';
    $f_d->read($header, $len)
                || die "$path/density.data: read: $!";
    ($west, $east, $south, $north, $xpitch, $ypitch, $cols, $rows)
        = unpack('ddddddII', $header);
    $datastart_d = $f_d->getpos();

    # Grab the population data too, but assume that its header is the same as
    # that of the density data.
    $f_p = new IO::File("$path/population.data", O_RDONLY)
        || die "$path/population.data: open: $!";
    $f_p->seek(length($blurb_string) + $len, 0)
        || die "$path/population.data: seek: $!";
    $datastart_p = $f_p->getpos();
}

use constant M_PI => 3.141592654;

# get_cell_number LAT LON
# Return the cell number in which (LAT, LON) lies. Returns -1 if the cell is
# outside the coverage area; dies on error. 
sub get_cell_number ($$) {
    my ($lat, $lon) = @_;
    read_gpw_data();

    throw RABX::Error("Latitude is out of range", RABX::Error::USER)
        if ($lat > 90 || $lat < -90);
    
    # 
    # GPW is cell-based: each element in the grid specifies the population in
    # a cell lying between lines of fixed longitude and latitude:
    #
    #            m dx          (m + 1) dx
    #       n dy + - - - - - - +
    #              population
    #            | density in  |
    #              cell is
    #            | recorded at |
    #              (m, n)
    # (n + 1) dy + - - - - - - +
    # 

    $lon -= 180 while ($lon > 180);
    $lon += 180 while ($lon < -180);
   
#printf "using (%f, %f)\n", $lat, $lon;
   
    my $x = int(($lon - $west) / $xpitch);
    my $y = int(($north - $lat) / $ypitch);

#printf "(x, y) = (%d, %d)\n", $x, $y;

    return -1 if ($y < 0 || $y >= $rows);
    die "bad X value" if ($x < 0 || $x >= $cols); # shouldn't happen

#printf "($lat, $lon) -> cell #%d\n", $y * $cols + $x;

    return $y * $cols + $x;
}

# get_density NUMBER | LAT LON
# Return the population density (in persons per square kilometer) at cell
# NUMBER or at (LAT, LON).
my $cellsize = length(pack('d', 0));
sub get_density ($;$) {
    my $n = $_[0];
    $n = get_cell_number($_[0], $_[1]) if (@_ == 2);
    return 0. if ($n == -1);
    $f_d->setpos($datastart_d)
        || die "$path/density.data: setpos: $!";
    $f_d->seek($n * length(pack('d', 0)), 1)
        || die "$path/density.data: lseek: $!";
    my $b = '';
    $f_d->read($b, $cellsize)
        || die "$path/density.data: read: $!";
    my $density = unpack('d', $b);
#print "\$density = $density\n";
    $density = 0 if ($density < 0);
    return $density;
}

# get_population NUMBER | LAT LON
# Return the total population of the cell NUMBER or at (LAT, LON).
sub get_population ($;$) {
    my $n = $_[0];
    $n = get_cell_number($_[0], $_[1]) if (@_ == 2);
    return 0. if ($n == -1);
    $f_p->setpos($datastart_p)
        || die "$path/population.data: setpos: $!";
    $f_p->seek($n * length(pack('d', 0)), 1)
        || die "$path/population.data: lseek: $!";
    my $b = '';
    $f_p->read($b, $cellsize)
        || die "$path/population.data: read: $!";
    my $pop = unpack('d', $b);
#print "\$pop = $pop\n";
    $pop = 0 if ($pop < 0);
    return $pop;
}

sub rad ($) { return $_[0] * M_PI / 180; }
sub deg ($) { return $_[0] * 180 / M_PI; }

# get_cellarea NUMBER | LAT LON
# Return the total area (NOT the land area) of the cell NUMBER or at (LAT,
# LON), in square kilometers.
sub get_cellarea ($;$) {
    my $n = $_[0];
    $n = get_cell_number($_[0], $_[1]) if (@_ == 2);
    return -1. if ($n == -1);
    # For a spherical earth, cell area depends only on latitude.
    my $y = int($n / $cols);
    my $lat1 = $north - $ypitch * $y;
    my $lat2 = $lat1 - $ypitch;
    return 2 * M_PI * abs(sin(rad($lat1)) - sin(rad($lat2))) * ($xpitch / 360) * Geo::Distance::R_e ** 2;
}

# add_azimuth_offset LAT LON AZIMUTH OFFSET
# Find the latitude and longitude at a distance OFFSET from (LAT, LON) in the
# direction of AZIMUTH. LAT, LON are in degrees, AZIMUTH in radians, and OFFSET
# in km.  Return in list context the new latitude and longitude.
sub add_azimuth_offset ($$$$) {
    my ($lat, $lon, $theta, $off) = @_;
    # http://www.codeguru.com/Cpp/Cpp/algorithms/general/article.php/c5115/
    my $b = $off / Geo::Distance::R_e;
    my $a = acos(cos($b) * cos(rad(90 - $lat)) + sin(rad(90 - $lat)) * sin($b) * cos($theta));
    my $B = asin(sin($b) * sin($theta) / sin($a));
    return (90 - deg($a), deg($B) + $lon);
}

# spherical_cap_area R1 R2
# Return the surface area of a spherical cap on a sphere radius R1 subtending
# and angle 2 R2 / R1 (i.e., a cap which on the surface of the sphere appears
# to be of radius R2).
sub spherical_cap_area ($$) {
    my ($R, $r) = @_;
    my $theta = $r / $R;
    # assuming the thing is flat is a pretty good approximation for small r.
    return M_PI * $r ** 2 if ($theta < 0.25);
    my $a = sin($theta);        # small angles, typically
    my $h = 1 - cos($theta);
    return M_PI * ($a ** 2 + $h ** 2) * $R ** 2;
}

# get_radius_containing LAT LON NUMBER MAXIMUM
# What radius circle around (LAT, LON) contains at least NUMBER people? If the
# radius would be larger than MAXIMUM, return MAXIMUM instead.
sub get_radius_containing ($$$$) {
    my ($lat, $lon, $num, $max) = @_;
    throw RABX::Error("LAT is out of range", RABX::Error::USER)
        if ($lat > 90 || $lat < -90);

    throw RABX::Error("MAXIMUM must not be negative", RABX::Error::USER)
        if ($max < 0);
    return 0.1 if ($max < 0.1);

    my $r0 = 0.1;
    my $area0 = spherical_cap_area(Geo::Distance::R_e, $r0);
    my $P = get_density($lat, $lon) * $area0;
#printf "%f %f\n", $r0, $P;
    return $r0 if ($P > $num);

    # Now work outwards in small steps until we reach MAXIMUM or enclose at
    # least NUMBER people.
    my @rp = ([$r0, $P]);
    for (my $r = 1; $r < $max; $r += ($r < 15 ? 1 : 5)) {
        my $rr = ($r + $r0) / 2;
        my $alpha = $rr / Geo::Distance::R_e;
        # Step round the circle in ~2500m steps.
        my $n = 2 * M_PI * $rr / ($r < 15 ? 2.5 : 5);
        $n = 10 if ($n < 10);
        my $p = 0;
        my $dens = 0;
        for (my $i = 0; $i < $n; ++$i) {
            my $phi = 2 * $i * M_PI / $n;
            my ($lat1, $lon1) = add_azimuth_offset($lat, $lon, $phi, $rr);
            my $n = get_cell_number($lat1, $lon1);
            $dens += get_population($n) / get_cellarea($n);
        }
        $dens /= $n;
        my $area = spherical_cap_area(Geo::Distance::R_e, $r);
        $P += $dens * ($area - $area0);
        push(@rp, [$r, $P]);
        shift(@rp) if (@rp == 3);

        if ($P > $num) {
            # Interpolate to find the appropriate radius.
            my ($r1, $P1) = @{$rp[0]};
            my ($r2, $P2) = @{$rp[1]};
            return ($r1 + ($r2 - $r1) * ($num - $P1) / ($P2 - $P1));
        }

        $r0 = $r;
        $area0 = $area;
#printf "%f %f\n", $r0, $P;
    }

    return $max;
}

package Gaze;

=item get_population_density LAT LON

Return an estimate of the population density at (LAT, LON) in persons per
square kilometer.

=cut
sub get_population_density ($$) {
    return Gaze::GPW::get_density($_[0], $_[1]);
}

=item get_radius_containing_population LAT LON NUMBER [MAXIMUM]

Return an estimate of the radius (in km) of the smallest circle around (LAT,
LON) which contains at least NUMBER people. If MAXIMUM is defined, return that
value rather than any larger computed radius; if not specified, use 150km.

=cut
sub get_radius_containing_population ($$$;$) {
    $_[3] ||= 150;
    return Gaze::GPW::get_radius_containing($_[0], $_[1], $_[2], $_[3]);
}

1;
