--
-- schema.sql:
-- Schema for gazetteer service.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.8 2005-07-27 09:16:40 chris Exp $
--

create table feature (
    ufi integer not null primary key,   -- values above 100,000,000 used for USGS data
    country char(2) not null,   -- references country(iso_code)?
    state char(2),              -- optional; for USA
    -- coordinates in WGS84
    lat double precision not null,
    lon double precision not null,
    -- where a placename is ambiguous, qualify it with extra information
    in_qualifier text,  -- name of enclosing region in which this place lies
    near_qualifier text -- names of nearby places
);

create index feature_country_idx on feature(country);

create table name (
    uni integer not null primary key,
    ufi integer not null references feature(ufi),
    is_primary boolean not null default false,
    -- Name of the place, in UTF-8. But note that these are transcribed
    -- into the Latin alphabet and so are no good to us in, e.g., China or
    -- Russia.
    full_name text not null,
    -- C - Conventional
    -- N - Native
    -- V - Variant or alternate
    -- D - Not verified
    name_type char(1) check (name_type in ('C', 'D', 'N', 'V'))
--    language_code char(2) -- references language(code) ?
);

create index name_ufi_idx on name(ufi);
create index name_full_name_idx on name(full_name);

create table name_part (
    uni integer not null references name(uni),

    -- Three letter substrings of name.full_name.  Letters are lowercase except
    -- the first and last letter from the name, which is uppercase.
    namepart varchar(16) not null,         -- three characters, but UNICODE, so make this longer in case of byte vs char problems

    count integer not null
);

create index name_part_namepart_idx on name_part(namepart);
