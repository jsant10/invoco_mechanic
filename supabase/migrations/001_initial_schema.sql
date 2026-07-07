-- ============================================================
-- INVOCO MECHANIC — Initial Schema
-- ============================================================

-- Enable extensions
create extension if not exists "uuid-ossp";
create extension if not exists "postgis"; -- for lat/lng proximity search

-- ============================================================
-- PROFILES
-- One row per auth user; role determines customer vs mechanic
-- ============================================================
create table public.profiles (
                                 id          uuid primary key references auth.users on delete cascade,
                                 full_name   text not null,
                                 phone       text,
                                 avatar_url  text,
                                 role        text not null check (role in ('customer', 'mechanic')),
                                 created_at  timestamptz not null default now(),
                                 updated_at  timestamptz not null default now()
);

-- ============================================================
-- MECHANIC PROFILES
-- Extended info for users with role = 'mechanic'
-- ============================================================
create table public.mechanic_profiles (
                                          id                        uuid primary key default uuid_generate_v4(),
                                          profile_id                uuid not null unique references public.profiles on delete cascade,
                                          shop_name                 text not null,
                                          bio                       text,
                                          address                   text,
                                          city                      text,
                                          state                     text,
                                          zip                       text,
                                          location                  geography(point, 4326), -- lat/lng for proximity search
                                          years_experience          int,
                                          is_verified               boolean not null default false,
                                          is_accepting_appointments boolean not null default true,
                                          avg_rating                numeric(3, 2),           -- cached, updated via trigger
                                          total_reviews             int not null default 0,  -- cached, updated via trigger
                                          created_at                timestamptz not null default now(),
                                          updated_at                timestamptz not null default now()
);

create index mechanic_profiles_location_idx on public.mechanic_profiles using gist(location);

-- ============================================================
-- SERVICES
-- Lookup table of service types (oil change, brakes, etc.)
-- ============================================================
create table public.services (
                                 id        uuid primary key default uuid_generate_v4(),
                                 name      text not null unique,
                                 category  text not null  -- e.g. 'Routine Maintenance', 'Engine', 'Brakes'
);

-- Seed common service categories
insert into public.services (name, category) values
                                                 ('Oil Change',              'Routine Maintenance'),
                                                 ('Tire Rotation',           'Routine Maintenance'),
                                                 ('Air Filter Replacement',  'Routine Maintenance'),
                                                 ('Brake Pad Replacement',   'Brakes'),
                                                 ('Brake Fluid Flush',       'Brakes'),
                                                 ('Rotor Resurfacing',       'Brakes'),
                                                 ('Transmission Service',    'Drivetrain'),
                                                 ('Differential Service',    'Drivetrain'),
                                                 ('Engine Diagnostics',      'Engine'),
                                                 ('Spark Plug Replacement',  'Engine'),
                                                 ('Timing Belt Replacement', 'Engine'),
                                                 ('Coolant Flush',           'Cooling'),
                                                 ('Radiator Repair',         'Cooling'),
                                                 ('A/C Service',             'HVAC'),
                                                 ('Wheel Alignment',         'Suspension'),
                                                 ('Strut/Shock Replacement', 'Suspension'),
                                                 ('Battery Replacement',     'Electrical'),
                                                 ('Alternator Replacement',  'Electrical'),
                                                 ('Inspection',              'Other');

-- ============================================================
-- MECHANIC SERVICES
-- Which services a mechanic offers, with pricing
-- ============================================================
create table public.mechanic_services (
                                          id                  uuid primary key default uuid_generate_v4(),
                                          mechanic_id         uuid not null references public.mechanic_profiles on delete cascade,
                                          service_id          uuid not null references public.services on delete cascade,
                                          price_min           numeric(10, 2),
                                          price_max           numeric(10, 2),
                                          duration_minutes    int,
                                          unique (mechanic_id, service_id)
);

-- ============================================================
-- APPOINTMENTS
-- Booking between a customer and a mechanic
-- ============================================================
create table public.appointments (
                                     id                        uuid primary key default uuid_generate_v4(),
                                     mechanic_id               uuid not null references public.mechanic_profiles on delete restrict,
                                     customer_id               uuid not null references public.profiles on delete restrict,
                                     service_id                uuid references public.services,
                                     vehicle_year              int,
                                     vehicle_make              text,
                                     vehicle_model             text,
                                     vehicle_notes             text,  -- describe the issue in their own words
                                     status                    text not null default 'pending'
                                         check (status in ('pending', 'confirmed', 'in_progress', 'completed', 'cancelled')),
                                     scheduled_at              timestamptz not null,
                                     estimated_duration_minutes int,
                                     customer_notes            text,
                                     mechanic_notes            text,
                                     price_quoted              numeric(10, 2),
                                     price_final               numeric(10, 2),
                                     created_at                timestamptz not null default now(),
                                     updated_at                timestamptz not null default now()
);

create index appointments_mechanic_idx  on public.appointments (mechanic_id);
create index appointments_customer_idx  on public.appointments (customer_id);
create index appointments_scheduled_idx on public.appointments (scheduled_at);

-- ============================================================
-- AVAILABILITY
-- Mechanic's recurring weekly schedule
-- ============================================================
create table public.availability (
                                     id           uuid primary key default uuid_generate_v4(),
                                     mechanic_id  uuid not null references public.mechanic_profiles on delete cascade,
                                     day_of_week  int not null check (day_of_week between 0 and 6), -- 0 = Sunday
                                     start_time   time not null,
                                     end_time     time not null,
                                     is_active    boolean not null default true,
                                     unique (mechanic_id, day_of_week)
);

-- ============================================================
-- AVAILABILITY EXCEPTIONS
-- One-off overrides: days off or special hours
-- ============================================================
create table public.availability_exceptions (
                                                id              uuid primary key default uuid_generate_v4(),
                                                mechanic_id     uuid not null references public.mechanic_profiles on delete cascade,
                                                date            date not null,
                                                is_unavailable  boolean not null default true,  -- true = day off
                                                start_time      time,  -- null when is_unavailable = true
                                                end_time        time,
                                                unique (mechanic_id, date)
);

-- ============================================================
-- REVIEWS
-- Customer reviews of mechanics (tied to a completed appointment)
-- ============================================================
create table public.reviews (
                                id              uuid primary key default uuid_generate_v4(),
                                mechanic_id     uuid not null references public.mechanic_profiles on delete cascade,
                                customer_id     uuid not null references public.profiles on delete restrict,
                                appointment_id  uuid unique references public.appointments on delete set null,
                                rating          int not null check (rating between 1 and 5),
                                title           text,
                                body            text,
                                mechanic_reply  text,
                                mechanic_reply_at timestamptz,
                                created_at      timestamptz not null default now()
);

create index reviews_mechanic_idx on public.reviews (mechanic_id);

-- ============================================================
-- REVIEW PHOTOS
-- Optional photos attached to a review
-- ============================================================
create table public.review_photos (
                                      id            uuid primary key default uuid_generate_v4(),
                                      review_id     uuid not null references public.reviews on delete cascade,
                                      storage_path  text not null,  -- Supabase Storage path
                                      sort_order    int not null default 0
);

-- ============================================================
-- TRIGGER: keep avg_rating + total_reviews in sync
-- ============================================================
create or replace function public.refresh_mechanic_rating()
returns trigger language plpgsql as $$
begin
update public.mechanic_profiles
set
    avg_rating    = (select round(avg(rating)::numeric, 2) from public.reviews where mechanic_id = coalesce(new.mechanic_id, old.mechanic_id)),
    total_reviews = (select count(*) from public.reviews where mechanic_id = coalesce(new.mechanic_id, old.mechanic_id)),
    updated_at    = now()
where id = coalesce(new.mechanic_id, old.mechanic_id);
return coalesce(new, old);
end;
$$;

create trigger trg_refresh_mechanic_rating
    after insert or update or delete on public.reviews
    for each row execute function public.refresh_mechanic_rating();

-- ============================================================
-- TRIGGER: updated_at timestamps
-- ============================================================
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
return new;
end;
$$;

create trigger trg_profiles_updated_at
    before update on public.profiles
    for each row execute function public.set_updated_at();

create trigger trg_mechanic_profiles_updated_at
    before update on public.mechanic_profiles
    for each row execute function public.set_updated_at();

create trigger trg_appointments_updated_at
    before update on public.appointments
    for each row execute function public.set_updated_at();

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table public.profiles              enable row level security;
alter table public.mechanic_profiles     enable row level security;
alter table public.mechanic_services     enable row level security;
alter table public.appointments          enable row level security;
alter table public.availability          enable row level security;
alter table public.availability_exceptions enable row level security;
alter table public.reviews               enable row level security;
alter table public.review_photos         enable row level security;

-- profiles: anyone can read; only the owner can write
create policy "profiles_select" on public.profiles for select using (true);
create policy "profiles_insert" on public.profiles for insert with check (auth.uid() = id);
create policy "profiles_update" on public.profiles for update using (auth.uid() = id);

-- mechanic_profiles: public read; mechanic edits their own
create policy "mechanic_profiles_select" on public.mechanic_profiles for select using (true);
create policy "mechanic_profiles_insert" on public.mechanic_profiles for insert with check (auth.uid() = profile_id);
create policy "mechanic_profiles_update" on public.mechanic_profiles for update using (auth.uid() = profile_id);

-- mechanic_services: public read; mechanic manages their own
create policy "mechanic_services_select" on public.mechanic_services for select using (true);
create policy "mechanic_services_write" on public.mechanic_services for all
  using (auth.uid() = (select profile_id from public.mechanic_profiles where id = mechanic_id));

-- appointments: customer sees their own; mechanic sees theirs
create policy "appointments_customer" on public.appointments for select using (auth.uid() = customer_id);
create policy "appointments_mechanic" on public.appointments for select
                                                                     using (auth.uid() = (select profile_id from public.mechanic_profiles where id = mechanic_id));
create policy "appointments_insert" on public.appointments for insert with check (auth.uid() = customer_id);
create policy "appointments_customer_update" on public.appointments for update using (auth.uid() = customer_id);
create policy "appointments_mechanic_update" on public.appointments for update
                                                                            using (auth.uid() = (select profile_id from public.mechanic_profiles where id = mechanic_id));

-- availability: public read; mechanic writes their own
create policy "availability_select" on public.availability for select using (true);
create policy "availability_write" on public.availability for all
  using (auth.uid() = (select profile_id from public.mechanic_profiles where id = mechanic_id));

create policy "availability_exceptions_select" on public.availability_exceptions for select using (true);
create policy "availability_exceptions_write" on public.availability_exceptions for all
  using (auth.uid() = (select profile_id from public.mechanic_profiles where id = mechanic_id));

-- reviews: public read; customer writes their own; mechanic can reply
create policy "reviews_select" on public.reviews for select using (true);
create policy "reviews_insert" on public.reviews for insert with check (auth.uid() = customer_id);
create policy "reviews_customer_update" on public.reviews for update using (auth.uid() = customer_id);
create policy "reviews_mechanic_reply" on public.reviews for update
                                                                 using (auth.uid() = (select profile_id from public.mechanic_profiles where id = mechanic_id));

create policy "review_photos_select" on public.review_photos for select using (true);
create policy "review_photos_write" on public.review_photos for all
  using (auth.uid() = (select customer_id from public.reviews where id = review_id));
