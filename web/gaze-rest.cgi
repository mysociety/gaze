#!/usr/bin/perl -w -I../perllib -I../../../perllib
#
# gaze-rest.cgi:
# "RESTful" interface to Gaze.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#

my $rcsid = ''; $rcsid .= '$Id: gaze-rest.cgi,v 1.13 2006-05-30 11:23:46 chris Exp $';

use strict;

require 5.8.0;

# Do this first of all, because Gaze.pm needs to see the config file.
BEGIN {
    use mySociety::Config;
    mySociety::Config::set_file('../conf/general');
}

use CGI::Fast;
use Error qw(:try);
use mySociety::WatchUpdate;
use RABX; # only for RABX::Error
use Regexp::Common qw(net);
use utf8;

use Gaze;

my $W = new mySociety::WatchUpdate();

# XXX do this in Gaze.pm?
my %countries = map { $_ => 1 } @{Gaze::get_find_places_countries()};
my $countries_last = time();

my %dispatch = (
        get_country_from_ip => {
                ip => [
                    "IP address for which to return country, in dotted-quad notation",
                    sub ($) {
                        return "missing"
                            if (!defined($_[0]));
                        return "invalid"
                            unless ($_[0] =~ /^$RE{net}{IPv4}$/);
                        return undef;
                    }
                ]
            },
        get_find_places_countries => {
            },
        find_places => {
                country => [
                    "ISO country code of country in which to search for places",
                    sub ($) {
                        return "missing"
                            if (!defined($_[0]));
                        return "invalid"
                            if ($_[0] !~ /^[A-Z]{2}$/ || !exists($countries{$_[0]}));
                        return undef;
                    }
                ], state => [
                    "state in which to search for places (optional)",
                    sub ($) {
                        return undef if (!defined($_[0]));
                        return "invalid" if ($_[0] !~ /^[A-Z]{2}$/);
                        return undef;
                    }
                ], query => [
                    "query term, at least two UTF-8 characters",
                    sub ($) {
                        my $x = $_[0];
                        return 'missing' if (!defined($x));
                        return "not valid UTF-8"
                            if (!utf8::decode($x));
                        return "too short"
                            unless (length($x) >= 2);
                        return undef;
                    }
                ],
                maxresults => [
                    "largest number of results to return (optional; between 1 and 100 inclusive)",
                    sub ($) {
                        return undef if (!defined($_[0]));
                        return "invalid"
                            unless ($_[0] =~ /^(100|[1-9]\d|[1-9])*$/);
                        return undef;
                    }
                ], minscore => [
                    "smallest percentage score for returned results (optional; between 1 and 100 inclusive)",
                    sub ($) {
                        return undef if (!defined($_[0]));
                        return "invalid"
                            unless ($_[0] =~ /^(100|[1-9]\d|[1-9])*$/);
                        return undef;
                    }
                ]
            },
            get_population_density => {
                lat => [
                    "WGS84 latitude, in north-positive decimal degrees",
                    sub ($) {
                        my $lat = shift;
                        return 'missing' if (!defined($lat));
                        my $w = undef;
                        eval { local $SIG{__WARN__} = sub { $w = shift; }; $lat += 0.; };
                        return "'$lat' is not a valid real number" if ($w);
                        return "'$lat' is out-of-range (should be in [-90, 90])"
                            if ($lat < -90 || $lat > 90);
                        return undef;
                    }
                ], lon => [
                    "WGS84 longitude, in east-positive decimal degrees",
                    sub ($) {
                        my $lon = shift;
                        return 'missing' if (!defined($lon));
                        my $w = undef;
                        eval { local $SIG{__WARN__} = sub { $w = shift; }; $lon += 0.; };
                        return "'$lon' is not a valid real number" if ($w);
                        return undef;
                    }
                ]
            },
            get_radius_containing_population => {
                lat => [
                    "WGS84 latitude, in north-positive decimal degrees",
                    sub ($) {
                        my $lat = shift;
                        return 'missing' if (!defined($lat));
                        my $w = undef;
                        eval { local $SIG{__WARN__} = sub { $w = shift; }; $lat += 0.; };
                        return "'$lat' is not a valid real number" if ($w);
                        return "'$lat' is out-of-range (should be in [-90, 90])"
                            if ($lat < -90 || $lat > 90);
                        return undef;
                    }
                ], lon => [
                    "WGS84 longitude, in east-positive decimal degrees",
                    sub ($) {
                        my $lon = shift;
                        return 'missing' if (!defined($lon));
                        my $w = undef;
                        eval { local $SIG{__WARN__} = sub { $w = shift; }; $lon += 0.; };
                        return "'$lon' is not a valid real number" if ($w);
                        return undef;
                    }
                ], number => [
                    "number of persons",
                    sub ($) {
                        my $num = shift;
                        return 'missing' if (!defined($num));
                        my $w = undef;
                        eval { local $SIG{__WARN__} = sub { $w = shift; }; $num += 0.; };
                        return "'$num' is not a valid real number" if ($w);
                        return "'$num' must not be negative" if ($num < 0);
                        return undef;
                    }
                ], maximum => [
                    "maximum radius to return (default 150km)",
                    sub ($) {
                        my $max = shift;
                        return undef if (!defined($max));
                        my $w = undef;
                        eval { local $SIG{__WARN__} = sub { $w = shift; }; $max += 0.; };
                        return "'$max' is not a valid real number" if ($w);
                        return "'$max' must not be negative" if ($max < 0);
                        return "'$max' is greater than the circumference of the earth" if ($max > 41000);
                        return undef;
                    }
                ]
            },
           
    );

sub error ($%) {
    my ($q, %e) = @_;
    my $text = join("", map { "$_: $e{$_}\n" } sort(keys(%e)));
    print $q->header(
                -content_type => 'text/plain; charset=utf-8',
                -content_length => length($text),
                -status => '400 Bad Request'
            ), $text;
}
    
while (my $q = new CGI::Fast()) {
    my $f = $q->param('f');
    if (!defined($f)) {
        error($q, f => "missing (should specify function)");
    } elsif (!exists($dispatch{$f})) {
        error($q, f => "invalid (should specify function)");
    } else {
        my %v = ( );
        my %errors = ( );
        foreach my $p (keys %{$dispatch{$f}}) {
            my ($desc, $test) = @{$dispatch{$f}->{$p}};
            $v{$p} = $q->param($p);
            if (ref($test) eq 'Regexp') {
                if (!defined($v{$p})) {
                    $errors{$p} = "missing; should be $desc";
                } elsif ($v{$p} !~ $test) {
                    $errors{$p} = "invalid; should be $desc";
                }
            } else {
                my $r = &$test($v{$p});
                $errors{$p} = "$r; should be $desc" if (defined($r));
            }
        }

        my $ct = 'text/plain; charset=utf-8';
        my $r;
        if (keys(%errors)) {
            error($q, %errors);
        } elsif ($f eq 'get_country_from_ip') {
            $r = Gaze::get_country_from_ip($v{ip});
            $r ||= '';
            $r .= "\n";
        } elsif ($f eq 'get_find_places_countries') {
            if ($countries_last < time() - 60) {
                my %countries = map { $_ => 1 } @{Gaze::get_find_places_countries()};
                my $countries_last = time();
            }
            $r = join("\n", sort(keys(%countries))) . "\n";
        } elsif ($f eq 'find_places') {
            my $l;
            try {
                $l = Gaze::find_places($v{country}, $v{state}, $v{query}, $v{maxresults}, $v{minscore})
            } catch RABX::Error with {
                my $E = shift;
                $r = undef;
                error($q, find_places => $E->text());
            };
            if ($l) {
                # CSV formatted per http://www.ietf.org/internet-drafts/draft-shafranovich-mime-csv-05.txt
                $ct = 'text/csv; charset=utf-8';
                $r = qq("Name","In","Near","Latitude","Longitude","State","Score"\r\n);
                foreach (@$l) {
                    $r .= join(",", map { my $x = $_; $x ||= ''; $x =~ s/"/""/g; qq("$x") } @$_) . "\r\n";
                }
            }
        } elsif ($f eq 'get_population_density') {
            try {
                $r = Gaze::get_population_density($v{lat}, $v{lon});
            } catch RABX::Error with {
                my $E = shift;
                $r = undef;
                error($q, get_population_density => $E->text());
            };
            $r .= "\n";
        } elsif ($f eq 'get_radius_containing_population') {
            try {
                $r = Gaze::get_radius_containing_population($v{lat}, $v{lon}, $v{number}, $v{maximum});
            } catch RABX::Error with {
                my $E = shift;
                $r = undef;
                error($q, get_population_density => $E->text());
            };
            $r .= "\n";
        }
        if ($r) {
            print $q->header(
                        -content_type => $ct,
                        -content_length => length($r),
                        -cache_control => 'max-age=86400'
                    ), $r;
        }
    }
    last if ($W->changed());
}
