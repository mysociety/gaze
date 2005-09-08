#!/usr/bin/perl -w -I../perllib -I../../../perllib
#
# gaze.cgi:
# RABX server.
#
# To run it you need these lines in an Apache config:
#     Options +ExecCGI
#     SetHandler fastcgi-script
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#

my $rcsid = ''; $rcsid .= '$Id: gaze.cgi,v 1.6 2005-09-08 11:34:20 francis Exp $';

use strict;

require 5.8.0;

# Do this first of all, because Gaze.pm needs to see the config file.
BEGIN {
    use mySociety::Config;
    mySociety::Config::set_file('../../conf/general');
}

use FCGI;
use RABX;

use mySociety::WatchUpdate;

use Gaze;

my $req = FCGI::Request();
my $W = new mySociety::WatchUpdate();

while ($req->Accept() >= 0) {
    RABX::Server::CGI::dispatch(
            'Gaze.find_places' => sub {
                Gaze::find_places($_[0], $_[1], $_[2], $_[3], $_[4]);
            },
            'Gaze.get_country_from_ip' => sub {
                Gaze::get_country_from_ip($_[0]);
            },
            'Gaze.get_find_places_countries' => sub {
                Gaze::get_find_places_countries();
            }
        );
    last if ($W->changed());
}
