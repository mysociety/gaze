--
-- schema.sql:
-- Schema for gazetteer service.
--
-- Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
-- Email: chris@mysociety.org; WWW: http://www.mysociety.org/
--
-- $Id: schema.sql,v 1.12 2006-12-01 15:35:21 matthew Exp $
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
create index feature_state_idx on feature(state);

create index feature_country_lat_idx on feature(country, lat);
create index feature_country_lon_idx on feature(country, lon);

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

create function angle_between(double precision, double precision)
    returns double precision as '
select case
    when abs($1 - $2) > pi() then 2 * pi() - abs($1 - $2)
else abs($1 - $2)
    end;
' language sql immutable;

-- R_e
-- Radius of the earth, in km. This is something like 6372.8 km:
--  http://en.wikipedia.org/wiki/Earth_radius
create function R_e()
returns double precision as '
    select 6372.8::double precision;
' language sql immutable;

create type feature_nearby_match as (
    ufi integer,
    country char(2),
    state char(2),
    lat double precision,   
    lon double precision,  
    distance double precision   -- km
);

-- feature_find_nearby LATITUDE LONGITUDE DISTANCE
-- Find features within DISTANCE (km) of (LATITUDE, LONGITUDE).
create function feature_find_nearby(double precision, double precision, double precision)
    returns setof feature_nearby_match as
    -- Write as SQL function so that we don't have to construct a temporary
    -- table or results set in memory. That means we can't check the values of
    -- the parameters, sadly.
    -- Through sheer laziness, just use great-circle distance; that'll be off
    -- by ~0.1%:
    --  http://www.ga.gov.au/nmd/geodesy/datums/distance.jsp
    -- We index locations on lat/lon so that we can select the locations which lie
    -- within a wedge of side about 2 * DISTANCE. That cuts down substantially
    -- on the amount of work we have to do.
'
    -- trunc due to inaccuracies in floating point arithmetic
    select feature.ufi,feature.country,feature.state,feature.lat,feature.lon,
        R_e() * acos(trunc(
            (sin(radians($1)) * sin(radians(lat))
             + cos(radians($1)) * cos(radians(lat))
                 * cos(radians($2 - lon)))::numeric, 14)
        ) as distance
    from feature
    where
        lon is not null and lat is not null
        and radians(lat) > radians($1) - ($3 / R_e())
        and radians(lat) < radians($1) + ($3 / R_e())
        and (abs(radians($1)) + ($3 / R_e()) > pi() / 2     -- case where search pt is near pole
            or angle_between(radians(lon), radians($2))
                < $3 / (R_e() * cos(radians($1 + $3 / R_e()))))
        -- ugly -- unable to use attribute name "distance" here, sadly
        and R_e() * acos(trunc(
            (sin(radians($1)) * sin(radians(lat))
            + cos(radians($1)) * cos(radians(lat))
                 * cos(radians($2 - lon)))::numeric, 14)
        ) < $3
    order by distance 
' language sql; -- should be "stable" rather than volatile per default?

create type place_nearby_match as (
    name text,
    country char(2),
    state char(2),
    lat double precision,   
    lon double precision,  
    distance double precision   -- km
);

-- place_find_nearby LATITUDE LONGITUDE DISTANCE
-- Find places within DISTANCE (km) of (LATITUDE, LONGITUDE).
create function place_find_nearby(double precision, double precision, double precision)
    returns setof place_nearby_match as
'
    select name.full_name, nearby.country,nearby.state,nearby.lat,nearby.lon,nearby.distance
        from feature_find_nearby($1, $2, $3) as nearby, name 
        where nearby.ufi = name.ufi
' language sql;

