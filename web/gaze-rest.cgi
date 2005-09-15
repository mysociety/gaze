#!/usr/bin/perl -w
#
# gaze-rest.cgi:
# "RESTful" interface to Gaze.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#

my $rcsid = ''; $rcsid .= '$Id: gaze-rest.cgi,v 1.1 2005-09-15 14:01:32 chris Exp $';

use strict;

require 5.8.0;

# Do this first of all, because Gaze.pm needs to see the config file.
BEGIN {
    use mySociety::Config;
    mySociety::Config::set_file('../../conf/general');
}

use CGI::Fast;
use mySociety::WatchUpdate;
use Regexp::Common qw(net);
use utf8;

use Gaze;

my $W = new mySociety::WatchUpdate();

# XXX do this in Gaze.pm?
my %countries = map { $_ => 1 } get_find_places_countries();
my $countries_last = time();

my %dispatch = (
        get_country_from_ip => {
                ip => sub ($) {
                    return "missing (should specify a single IPv4 address in dotted-quad notation)"
                        if (!defined($_[0]));
                    return "invalid (should specify a single IPv4 address in dotted-quad notation)"
                        if ($_[0] !=~ /^$RE{net}{IPv4}$/);
                }
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
                    }
                ], state => [
                    "state in which to search for places (optional)",
                    sub ($) {
                        return undef if (!defined($_[0]));
                        return "invalid" if ($_[0] !~ /^[A-Z]{2}$/);
                    }
                ], query => [
                    "query term, at least two UTF-8 characters",
                    sub ($) {
                        my $x = $_[0];
                        return "invalid (not UTF-8)"
                            if (!utf8::decode($x));
                        return "invalid (too short)"
                            unless (length($x) >= 2);
                    },
                maxresults => qr/^(100|[1-9]\d|[1-9])*$/,
                minscore => qr/^(100|[1-9]\d|[1-9])*$/
            }
    );

sub error ($%) {
    my ($q, %e) = @_;
    my $text = join("", map { "$_: $e{$_}\n" } sort(keys(%e)));
    print $q->header(
                -content_type => 'text/plain; charset=utf-8',
                -content_length => length($text)
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
            my $test = $dispatch{$f}->{$p};
            my $v{$p} = $q->param($p);
            if (ref($test) eq 'Regexp') {
                if (!defined($v{$p})) {
                    $errors{$v{$p}} = 'missing';
                } elsif ($v !~ $test) {
                    $errors{$v{$p}} = 'invalid';
                }
            } else {
                my $r = &$test($v{$p});
                $errors{$p} = $r if (defined($r));
            }
        }

        my $ct = 'text/plain; charset=utf-8';
        my $r;
        if (keys(%errors)) {
            error(%errors);
        } elsif ($f eq 'get_country_from_ip') {
            my $r = Gaze::get_country_from_ip($v{$p});
            $r ||= '';
            $r .= "\n";
        } elsif ($f eq 'get_find_places_countries') {
            if ($countries_last < time() - 60) {
                my %countries = map { $_ => 1 } get_find_places_countries();
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
                error($q, find_places => $E->text);
            };
            if ($l) {
                # CSV formatted per http://www.ietf.org/internet-drafts/draft-shafranovich-mime-csv-05.txt
                $ct = 'text/csv; charset=utf-8';
                $r = qq("Name","In","Near","Latitude","Longitude","State","Score"\r\n);
                foreach (@$l) {
                    $r .= join(",", map { my $x = $_; $x =~ s/"/""/g; qq("$x") } @$_) . "\r\n";
                }
            }
        }
        if ($r) {
            print $q->header(
                        -content_type => 'text/plain; charset=utf-8',
                        -content_length => length($r)
                    ), $r;
        }
    }
    last if ($W->changed());
}
