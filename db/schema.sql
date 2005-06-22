--
-- schema.sql:
-- Schema for gazetteer service.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.1 2005-06-22 18:25:55 chris Exp $
--

create table feature (
    ufi integer not null primary key,
    country char(2) not null, -- references country(iso_code),
    -- coordinates in WGS84
    lat double precision not null,
    lon double precision not null,
    populated_place_classification integer check (
            populated_place_classification is null
            or (populated_place_classification >= 1
                and populated_place_classification <= 5)
        ),
    
);

create table name (
    uni integer not null primary key,
    ufi integer not null references feature(ufi),
    -- Short and full names, both in UTF-8. But note that these are transcribed
    -- into the Latin alphabet and so are no good to us in, e.g., China or
    -- Russia.
    short_name text not null,
    full_name text not null,
    name_type char(1) check (name_type in ('C', 'D', 'N', 'V')),
    language_code char(2), -- references language(code) ?
    -- Where a name is not unique within a country, we need to qualify it.
    -- We support two kinds of qualification: place "is in" other place, and
    -- place "is near" other place. The former is used when we have
    -- well-defined information on enclosing administrative areas (ADM1 in
    -- GEOnet), and the latter otherwise. Ideally we would qualify places by
    -- nearby more important places, but in practice the GEOnet data typically
    -- don't give information on the size/importance of places.
    qualifier_type text check (
            qualifier_type is null
            or qualifier_type = 'in'
            or qualifier_type = 'near'
        ),
    qualifier_ufi integer references feature(ufi)
);

create index name_short_name_idx on name(short_name);
create index name_full_name_idx on name(full_name);

-- some kind of index for name lookup
