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

my $rcsid = ''; $rcsid .= '$Id: gaze.cgi,v 1.3 2005-07-22 13:57:40 francis Exp $';

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
                Gaze::find_places($_[0], @_[1 .. $#_]);
            },
            'Gaze.get_country_from_ip' => sub {
                Gaze::get_country_from_ip($_[0]);
            }
        );
    last if ($W->changed());
}
