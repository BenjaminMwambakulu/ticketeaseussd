--
-- PostgreSQL database dump
--

\restrict z1jBLSxbnCXerVSaKapcnA5eXXM7G30rmzL6ZwQiNRTEaOeFhqdH6L17N5abdbK

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

DROP POLICY IF EXISTS "Users can view ads for their tenant" ON public.ads;
DROP POLICY IF EXISTS "Trips: super_admin all" ON public.trips;
DROP POLICY IF EXISTS "Trips: staff and admin update tenant" ON public.trips;
DROP POLICY IF EXISTS "Trips: staff and admin read tenant" ON public.trips;
DROP POLICY IF EXISTS "Trips: staff and admin insert tenant" ON public.trips;
DROP POLICY IF EXISTS "Trips: passengers read published globally" ON public.trips;
DROP POLICY IF EXISTS "Trips: admin delete tenant" ON public.trips;
DROP POLICY IF EXISTS "Tenants: super_admin read all" ON public.tenants;
DROP POLICY IF EXISTS "Tenants: read own" ON public.tenants;
DROP POLICY IF EXISTS "Tenants: admin update own" ON public.tenants;
DROP POLICY IF EXISTS "Stages: tenant read" ON public.stages;
DROP POLICY IF EXISTS "Stages: super_admin all" ON public.stages;
DROP POLICY IF EXISTS "Stages: admin manage" ON public.stages;
DROP POLICY IF EXISTS "Seat assignments: super_admin all" ON public.seat_assignments;
DROP POLICY IF EXISTS "Seat assignments: staff admin tenant" ON public.seat_assignments;
DROP POLICY IF EXISTS "Seat assignments: staff admin manage tenant" ON public.seat_assignments;
DROP POLICY IF EXISTS "Seat assignments: passenger own" ON public.seat_assignments;
DROP POLICY IF EXISTS "Routes: tenant read" ON public.routes;
DROP POLICY IF EXISTS "Routes: super_admin all" ON public.routes;
DROP POLICY IF EXISTS "Routes: admin manage" ON public.routes;
DROP POLICY IF EXISTS "Role permissions: read all" ON public.role_permissions;
DROP POLICY IF EXISTS "Profiles: update own non-role" ON public.profiles;
DROP POLICY IF EXISTS "Profiles: super_admin read all" ON public.profiles;
DROP POLICY IF EXISTS "Profiles: read own" ON public.profiles;
DROP POLICY IF EXISTS "Profiles: admin update tenant roles" ON public.profiles;
DROP POLICY IF EXISTS "Profiles: admin read tenant" ON public.profiles;
DROP POLICY IF EXISTS "Payments: super_admin all" ON public.payments;
DROP POLICY IF EXISTS "Payments: staff admin tenant" ON public.payments;
DROP POLICY IF EXISTS "Payments: passenger update own" ON public.payments;
DROP POLICY IF EXISTS "Payments: passenger own" ON public.payments;
DROP POLICY IF EXISTS "Buses: tenant read" ON public.buses;
DROP POLICY IF EXISTS "Buses: super_admin all" ON public.buses;
DROP POLICY IF EXISTS "Buses: admin manage" ON public.buses;
DROP POLICY IF EXISTS "Bookings: super_admin all" ON public.bookings;
DROP POLICY IF EXISTS "Bookings: staff admin update tenant" ON public.bookings;
DROP POLICY IF EXISTS "Bookings: staff admin read tenant" ON public.bookings;
DROP POLICY IF EXISTS "Bookings: staff admin insert tenant" ON public.bookings;
DROP POLICY IF EXISTS "Bookings: passenger update own" ON public.bookings;
DROP POLICY IF EXISTS "Bookings: passenger read own" ON public.bookings;
DROP POLICY IF EXISTS "Bookings: passenger insert own" ON public.bookings;
DROP POLICY IF EXISTS "Booking passengers: super_admin all" ON public.booking_passengers;
DROP POLICY IF EXISTS "Booking passengers: staff admin update tenant" ON public.booking_passengers;
DROP POLICY IF EXISTS "Booking passengers: staff admin tenant" ON public.booking_passengers;
DROP POLICY IF EXISTS "Booking passengers: passenger own bookings" ON public.booking_passengers;
DROP POLICY IF EXISTS "Audit log: super_admin read all" ON public.audit_log;
DROP POLICY IF EXISTS "Audit log: admin read tenant" ON public.audit_log;
ALTER TABLE IF EXISTS ONLY public.trips DROP CONSTRAINT IF EXISTS trips_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.trips DROP CONSTRAINT IF EXISTS trips_schedule_master_id_fkey;
ALTER TABLE IF EXISTS ONLY public.trips DROP CONSTRAINT IF EXISTS trips_route_id_fkey;
ALTER TABLE IF EXISTS ONLY public.trips DROP CONSTRAINT IF EXISTS trips_original_bus_id_fkey;
ALTER TABLE IF EXISTS ONLY public.trips DROP CONSTRAINT IF EXISTS trips_bus_id_fkey;
ALTER TABLE IF EXISTS ONLY public.trips DROP CONSTRAINT IF EXISTS trips_boarding_stage_id_fkey;
ALTER TABLE IF EXISTS ONLY public.trips DROP CONSTRAINT IF EXISTS trips_alighting_stage_id_fkey;
ALTER TABLE IF EXISTS ONLY public.stages DROP CONSTRAINT IF EXISTS stages_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.seat_assignments DROP CONSTRAINT IF EXISTS seat_assignments_trip_id_fkey;
ALTER TABLE IF EXISTS ONLY public.seat_assignments DROP CONSTRAINT IF EXISTS seat_assignments_booking_passenger_id_fkey;
ALTER TABLE IF EXISTS ONLY public.schedule_masters DROP CONSTRAINT IF EXISTS schedule_masters_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.schedule_masters DROP CONSTRAINT IF EXISTS schedule_masters_route_id_fkey;
ALTER TABLE IF EXISTS ONLY public.schedule_masters DROP CONSTRAINT IF EXISTS schedule_masters_bus_id_fkey;
ALTER TABLE IF EXISTS ONLY public.routes DROP CONSTRAINT IF EXISTS routes_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.routes DROP CONSTRAINT IF EXISTS routes_origin_stage_id_fkey;
ALTER TABLE IF EXISTS ONLY public.routes DROP CONSTRAINT IF EXISTS routes_destination_stage_id_fkey;
ALTER TABLE IF EXISTS ONLY public.refunds DROP CONSTRAINT IF EXISTS refunds_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.refunds DROP CONSTRAINT IF EXISTS refunds_payment_id_fkey;
ALTER TABLE IF EXISTS ONLY public.refunds DROP CONSTRAINT IF EXISTS refunds_booking_id_fkey;
ALTER TABLE IF EXISTS ONLY public.profiles DROP CONSTRAINT IF EXISTS profiles_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.profiles DROP CONSTRAINT IF EXISTS profiles_id_fkey;
ALTER TABLE IF EXISTS ONLY public.payments DROP CONSTRAINT IF EXISTS payments_booking_id_fkey;
ALTER TABLE IF EXISTS ONLY public.notifications DROP CONSTRAINT IF EXISTS notifications_user_id_fkey;
ALTER TABLE IF EXISTS ONLY public.notifications DROP CONSTRAINT IF EXISTS notifications_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.buses DROP CONSTRAINT IF EXISTS buses_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.bookings DROP CONSTRAINT IF EXISTS bookings_trip_id_fkey;
ALTER TABLE IF EXISTS ONLY public.bookings DROP CONSTRAINT IF EXISTS bookings_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.bookings DROP CONSTRAINT IF EXISTS bookings_route_id_fkey;
ALTER TABLE IF EXISTS ONLY public.bookings DROP CONSTRAINT IF EXISTS bookings_original_booking_id_fkey;
ALTER TABLE IF EXISTS ONLY public.bookings DROP CONSTRAINT IF EXISTS bookings_booked_by_fkey;
ALTER TABLE IF EXISTS ONLY public.booking_reschedules DROP CONSTRAINT IF EXISTS booking_reschedules_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.booking_reschedules DROP CONSTRAINT IF EXISTS booking_reschedules_old_trip_id_fkey;
ALTER TABLE IF EXISTS ONLY public.booking_reschedules DROP CONSTRAINT IF EXISTS booking_reschedules_new_trip_id_fkey;
ALTER TABLE IF EXISTS ONLY public.booking_reschedules DROP CONSTRAINT IF EXISTS booking_reschedules_booking_id_fkey;
ALTER TABLE IF EXISTS ONLY public.booking_passengers DROP CONSTRAINT IF EXISTS booking_passengers_checked_in_by_fkey;
ALTER TABLE IF EXISTS ONLY public.booking_passengers DROP CONSTRAINT IF EXISTS booking_passengers_booking_id_fkey;
ALTER TABLE IF EXISTS ONLY public.audit_log DROP CONSTRAINT IF EXISTS audit_log_tenant_id_fkey;
ALTER TABLE IF EXISTS ONLY public.audit_log DROP CONSTRAINT IF EXISTS audit_log_actor_id_fkey;
ALTER TABLE IF EXISTS ONLY public.ads DROP CONSTRAINT IF EXISTS "ads_tenantId_fkey";
DROP TRIGGER IF EXISTS trigger_profile_role_changes ON public.profiles;
DROP TRIGGER IF EXISTS trigger_enforce_seat ON public.seat_assignments;
DROP TRIGGER IF EXISTS trigger_assign_ticket_number ON public.booking_passengers;
DROP TRIGGER IF EXISTS set_timestamp_trips ON public.trips;
DROP TRIGGER IF EXISTS set_timestamp_tenants ON public.tenants;
DROP TRIGGER IF EXISTS set_timestamp_stages ON public.stages;
DROP TRIGGER IF EXISTS set_timestamp_schedule_masters ON public.schedule_masters;
DROP TRIGGER IF EXISTS set_timestamp_routes ON public.routes;
DROP TRIGGER IF EXISTS set_timestamp_refunds ON public.refunds;
DROP TRIGGER IF EXISTS set_timestamp_profiles ON public.profiles;
DROP TRIGGER IF EXISTS set_timestamp_buses ON public.buses;
DROP TRIGGER IF EXISTS set_timestamp_bookings ON public.bookings;
DROP TRIGGER IF EXISTS audit_trips ON public.trips;
DROP TRIGGER IF EXISTS audit_tenants ON public.tenants;
DROP TRIGGER IF EXISTS audit_stages ON public.stages;
DROP TRIGGER IF EXISTS audit_seat_assignments ON public.seat_assignments;
DROP TRIGGER IF EXISTS audit_schedule_masters ON public.schedule_masters;
DROP TRIGGER IF EXISTS audit_routes ON public.routes;
DROP TRIGGER IF EXISTS audit_refunds ON public.refunds;
DROP TRIGGER IF EXISTS audit_profiles ON public.profiles;
DROP TRIGGER IF EXISTS audit_payments ON public.payments;
DROP TRIGGER IF EXISTS audit_buses ON public.buses;
DROP TRIGGER IF EXISTS audit_bookings ON public.bookings;
DROP TRIGGER IF EXISTS audit_booking_reschedules ON public.booking_reschedules;
DROP TRIGGER IF EXISTS audit_booking_passengers ON public.booking_passengers;
DROP INDEX IF EXISTS public.idx_trips_tenant_route;
DROP INDEX IF EXISTS public.idx_trips_schedule_master;
DROP INDEX IF EXISTS public.idx_trips_departure_date;
DROP INDEX IF EXISTS public.idx_trips_departure;
DROP INDEX IF EXISTS public.idx_trips_bus_datetime;
DROP INDEX IF EXISTS public.idx_tenants_settings;
DROP INDEX IF EXISTS public.idx_stages_tenant;
DROP INDEX IF EXISTS public.idx_seat_assignments_trip;
DROP INDEX IF EXISTS public.idx_schedule_masters_tenant;
DROP INDEX IF EXISTS public.idx_schedule_masters_route;
DROP INDEX IF EXISTS public.idx_schedule_masters_auto_extend;
DROP INDEX IF EXISTS public.idx_routes_tenant;
DROP INDEX IF EXISTS public.idx_passengers_ticket_token;
DROP INDEX IF EXISTS public.idx_bookings_tenant_trip;
DROP INDEX IF EXISTS public.idx_bookings_route_id;
DROP INDEX IF EXISTS public.idx_bookings_open_tickets;
DROP INDEX IF EXISTS public.idx_bookings_expires;
DROP INDEX IF EXISTS public.idx_booking_passengers_booking;
DROP INDEX IF EXISTS public.idx_audit_log_tenant_created;
DROP INDEX IF EXISTS public.idx_audit_log_target;
DROP INDEX IF EXISTS public.idx_audit_log_actor;
DROP INDEX IF EXISTS public.idx_audit_log_action;
ALTER TABLE IF EXISTS ONLY public.trips DROP CONSTRAINT IF EXISTS trips_pkey;
ALTER TABLE IF EXISTS ONLY public.tenants DROP CONSTRAINT IF EXISTS tenants_pkey;
ALTER TABLE IF EXISTS ONLY public.stages DROP CONSTRAINT IF EXISTS stages_tenant_id_stage_name_key;
ALTER TABLE IF EXISTS ONLY public.stages DROP CONSTRAINT IF EXISTS stages_pkey;
ALTER TABLE IF EXISTS ONLY public.seat_assignments DROP CONSTRAINT IF EXISTS seat_assignments_trip_id_seat_label_key;
ALTER TABLE IF EXISTS ONLY public.seat_assignments DROP CONSTRAINT IF EXISTS seat_assignments_pkey;
ALTER TABLE IF EXISTS ONLY public.schedule_masters DROP CONSTRAINT IF EXISTS schedule_masters_pkey;
ALTER TABLE IF EXISTS ONLY public.routes DROP CONSTRAINT IF EXISTS routes_tenant_id_route_code_key;
ALTER TABLE IF EXISTS ONLY public.routes DROP CONSTRAINT IF EXISTS routes_pkey;
ALTER TABLE IF EXISTS ONLY public.role_permissions DROP CONSTRAINT IF EXISTS role_permissions_role_key;
ALTER TABLE IF EXISTS ONLY public.role_permissions DROP CONSTRAINT IF EXISTS role_permissions_pkey;
ALTER TABLE IF EXISTS ONLY public.refunds DROP CONSTRAINT IF EXISTS refunds_pkey;
ALTER TABLE IF EXISTS ONLY public.profiles DROP CONSTRAINT IF EXISTS profiles_supa_auth_id_unique;
ALTER TABLE IF EXISTS ONLY public.profiles DROP CONSTRAINT IF EXISTS profiles_pkey;
ALTER TABLE IF EXISTS ONLY public.profiles DROP CONSTRAINT IF EXISTS profiles_national_id_key;
ALTER TABLE IF EXISTS ONLY public.payments DROP CONSTRAINT IF EXISTS payments_pkey;
ALTER TABLE IF EXISTS ONLY public.notifications DROP CONSTRAINT IF EXISTS notifications_pkey;
ALTER TABLE IF EXISTS ONLY public.buses DROP CONSTRAINT IF EXISTS buses_tenant_id_registration_number_key;
ALTER TABLE IF EXISTS ONLY public.buses DROP CONSTRAINT IF EXISTS buses_pkey;
ALTER TABLE IF EXISTS ONLY public.bookings DROP CONSTRAINT IF EXISTS bookings_pkey;
ALTER TABLE IF EXISTS ONLY public.booking_reschedules DROP CONSTRAINT IF EXISTS booking_reschedules_pkey;
ALTER TABLE IF EXISTS ONLY public.booking_passengers DROP CONSTRAINT IF EXISTS booking_passengers_ticket_number_key;
ALTER TABLE IF EXISTS ONLY public.booking_passengers DROP CONSTRAINT IF EXISTS booking_passengers_pkey;
ALTER TABLE IF EXISTS ONLY public.audit_log DROP CONSTRAINT IF EXISTS audit_log_pkey;
ALTER TABLE IF EXISTS ONLY public.audit_log_archive DROP CONSTRAINT IF EXISTS audit_log_archive_pkey;
ALTER TABLE IF EXISTS ONLY public.ads DROP CONSTRAINT IF EXISTS ads_pkey;
ALTER TABLE IF EXISTS public.trips ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.stages ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.seat_assignments ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.schedule_masters ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.routes ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.role_permissions ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.refunds ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.payments ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.buses ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.bookings ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.booking_reschedules ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.booking_passengers ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.audit_log ALTER COLUMN id DROP DEFAULT;
DROP VIEW IF EXISTS public.v_passenger_manifest;
DROP VIEW IF EXISTS public.v_daily_sales_report;
DROP SEQUENCE IF EXISTS public.trips_id_seq;
DROP TABLE IF EXISTS public.trips;
DROP TABLE IF EXISTS public.tenants;
DROP SEQUENCE IF EXISTS public.stages_id_seq;
DROP TABLE IF EXISTS public.stages;
DROP SEQUENCE IF EXISTS public.seat_assignments_id_seq;
DROP TABLE IF EXISTS public.seat_assignments;
DROP SEQUENCE IF EXISTS public.schedule_masters_id_seq;
DROP TABLE IF EXISTS public.schedule_masters;
DROP SEQUENCE IF EXISTS public.routes_id_seq;
DROP TABLE IF EXISTS public.routes;
DROP SEQUENCE IF EXISTS public.role_permissions_id_seq;
DROP TABLE IF EXISTS public.role_permissions;
DROP SEQUENCE IF EXISTS public.refunds_id_seq;
DROP TABLE IF EXISTS public.refunds;
DROP TABLE IF EXISTS public.profiles;
DROP SEQUENCE IF EXISTS public.payments_id_seq;
DROP TABLE IF EXISTS public.payments;
DROP TABLE IF EXISTS public.notifications;
DROP SEQUENCE IF EXISTS public.buses_id_seq;
DROP TABLE IF EXISTS public.buses;
DROP SEQUENCE IF EXISTS public.bookings_id_seq;
DROP TABLE IF EXISTS public.bookings;
DROP SEQUENCE IF EXISTS public.booking_reschedules_id_seq;
DROP TABLE IF EXISTS public.booking_reschedules;
DROP SEQUENCE IF EXISTS public.booking_passengers_id_seq;
DROP TABLE IF EXISTS public.booking_passengers;
DROP TABLE IF EXISTS public.audit_log_archive;
DROP SEQUENCE IF EXISTS public.audit_log_id_seq;
DROP TABLE IF EXISTS public.audit_log;
DROP TABLE IF EXISTS public.ads;
DROP FUNCTION IF EXISTS public.update_user_role(target_user_id uuid, new_role text);
DROP FUNCTION IF EXISTS public.trigger_set_timestamp();
DROP FUNCTION IF EXISTS public.log_profile_role_changes();
DROP FUNCTION IF EXISTS public.is_super_admin();
DROP FUNCTION IF EXISTS public.handle_new_user_sync();
DROP FUNCTION IF EXISTS public.handle_new_user();
DROP FUNCTION IF EXISTS public.get_user_permissions(user_id uuid);
DROP FUNCTION IF EXISTS public.get_or_create_profile(p_full_name text, p_phone text, p_national_id text, p_tenant_id uuid);
DROP FUNCTION IF EXISTS public.generate_ticket_number();
DROP FUNCTION IF EXISTS public.enforce_seat_assignment();
DROP FUNCTION IF EXISTS public.current_tenant_id();
DROP FUNCTION IF EXISTS public."current_role"();
DROP FUNCTION IF EXISTS public.current_profile_id();
DROP FUNCTION IF EXISTS public.check_in_passenger(p_ticket_token uuid, p_staff_id uuid);
DROP FUNCTION IF EXISTS public.check_bus_conflicts(p_tenant_id uuid, p_bus_id bigint, p_departure_datetime timestamp with time zone, p_arrival_datetime timestamp with time zone, p_exclude_trip_id bigint);
DROP FUNCTION IF EXISTS public.audit_table_change();
DROP FUNCTION IF EXISTS public.archive_old_audit_logs();
DROP TYPE IF EXISTS public.notification_category;
DROP SCHEMA IF EXISTS public;
--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: notification_category; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.notification_category AS ENUM (
    'booking',
    'refund',
    'reschedule',
    'chat',
    'system'
);


--
-- Name: archive_old_audit_logs(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.archive_old_audit_logs() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Move rows older than 90 days to archive
    WITH moved AS (
        DELETE FROM public.audit_log
        WHERE created_at < NOW() - INTERVAL '90 days'
        RETURNING *
    )
    INSERT INTO public.audit_log_archive SELECT * FROM moved;
END;
$$;


--
-- Name: audit_table_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_table_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_actor_id        UUID;
    v_action          TEXT;
    v_old_val         JSONB := NULL;
    v_new_val         JSONB := NULL;
    v_changes         TEXT  := NULL;
    v_tenant_id       UUID  := NULL;
    v_target_id       TEXT;
    v_changed_fields  TEXT[];
    v_key             TEXT;
BEGIN
    -- ── Resolve actor from JWT (NULL for service-role / migrations) ──────────
    BEGIN
        SELECT p.id INTO v_actor_id
        FROM public.profiles p
        WHERE p.supa_auth_id = auth.uid()
        LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
        v_actor_id := NULL;
    END;

    -- ── Action label ─────────────────────────────────────────────────────────
    v_action := TG_OP; -- 'INSERT' | 'UPDATE' | 'DELETE'

    -- ── Row snapshots ────────────────────────────────────────────────────────
    IF TG_OP = 'DELETE' THEN
        v_old_val   := to_jsonb(OLD);
        v_target_id := (OLD.id)::TEXT;
    ELSIF TG_OP = 'INSERT' THEN
        v_new_val   := to_jsonb(NEW);
        v_target_id := (NEW.id)::TEXT;
    ELSE -- UPDATE
        v_old_val   := to_jsonb(OLD);
        v_new_val   := to_jsonb(NEW);
        v_target_id := (NEW.id)::TEXT;

        -- Build a concise list of changed field names only
        v_changed_fields := ARRAY[]::TEXT[];
        FOR v_key IN SELECT key FROM jsonb_each(v_new_val)
        LOOP
            IF (v_old_val->v_key) IS DISTINCT FROM (v_new_val->v_key)
               AND v_key NOT IN ('updated_at') -- skip noise
            THEN
                v_changed_fields := v_changed_fields || v_key;
            END IF;
        END LOOP;

        IF array_length(v_changed_fields, 1) IS NULL THEN
            -- Nothing meaningful changed (only updated_at) — skip
            RETURN NEW;
        END IF;

        v_changes := 'Changed: ' || array_to_string(v_changed_fields, ', ');
    END IF;

    -- ── Resolve tenant_id (column name varies by table) ──────────────────────
    BEGIN
        IF TG_OP = 'DELETE' THEN
            v_tenant_id := (OLD.tenant_id)::UUID;
        ELSE
            v_tenant_id := (NEW.tenant_id)::UUID;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_tenant_id := NULL;
    END;

    -- ── Write audit row ───────────────────────────────────────────────────────
    INSERT INTO public.audit_log (
        tenant_id,
        actor_id,
        action,
        target_type,
        target_id,
        old_value,
        new_value,
        changes
    ) VALUES (
        v_tenant_id,
        v_actor_id,
        lower(TG_OP) || '_' || TG_TABLE_NAME,  -- e.g. 'update_bookings'
        TG_TABLE_NAME,
        v_target_id,
        v_old_val,
        v_new_val,
        v_changes
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: check_bus_conflicts(uuid, bigint, timestamp with time zone, timestamp with time zone, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_bus_conflicts(p_tenant_id uuid, p_bus_id bigint, p_departure_datetime timestamp with time zone, p_arrival_datetime timestamp with time zone, p_exclude_trip_id bigint DEFAULT NULL::bigint) RETURNS TABLE(conflict_trip_id bigint, conflict_route_code text, conflict_departure timestamp with time zone, conflict_arrival timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    t.id,
    r.route_code,
    t.departure_datetime,
    t.arrival_datetime
  FROM public.trips t
  JOIN public.routes r ON r.id = t.route_id
  WHERE t.tenant_id = p_tenant_id
    AND t.bus_id = p_bus_id
    AND t.status IN ('scheduled', 'active')
    AND (p_exclude_trip_id IS NULL OR t.id != p_exclude_trip_id)
    AND (
      -- Check for time overlap
      (t.departure_datetime, COALESCE(t.arrival_datetime, t.departure_datetime + INTERVAL '4 hours'))
      OVERLAPS
      (p_departure_datetime, COALESCE(p_arrival_datetime, p_departure_datetime + INTERVAL '4 hours'))
    );
END;
$$;


--
-- Name: check_in_passenger(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_in_passenger(p_ticket_token uuid, p_staff_id uuid) RETURNS TABLE(success boolean, message text, passenger_name text, seat_label text, route_info text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_passenger_record RECORD;
BEGIN
    -- 1. Look up the passenger and trip details
    SELECT 
        bp.id, bp.name, sa.seat_label, bp.checked_in_at,
        r.route_code || ' (' || os.stage_name || ' -> ' || ds.stage_name || ')' as route
    INTO v_passenger_record
    FROM public.booking_passengers bp
    JOIN public.bookings b ON b.id = bp.booking_id
    JOIN public.trips t ON t.id = b.trip_id
    JOIN public.routes r ON r.id = t.route_id
    JOIN public.stages os ON os.id = r.origin_stage_id
    JOIN public.stages ds ON ds.id = r.destination_stage_id
    LEFT JOIN public.seat_assignments sa ON sa.booking_passenger_id = bp.id
    WHERE bp.ticket_token = p_ticket_token;

    -- 2. Validations
    IF v_passenger_record.id IS NULL THEN
        RETURN QUERY SELECT false, 'Invalid Ticket: Token not found'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    IF v_passenger_record.checked_in_at IS NOT NULL THEN
        RETURN QUERY SELECT false, 'Already Checked In at ' || v_passenger_record.checked_in_at::TEXT, 
                            v_passenger_record.name, v_passenger_record.seat_label, v_passenger_record.route;
        RETURN;
    END IF;

    -- 3. Perform Check-in
    UPDATE public.booking_passengers
    SET checked_in_at = NOW(),
        checked_in_by = p_staff_id
    WHERE id = v_passenger_record.id;

    RETURN QUERY SELECT true, 'Check-in Successful'::TEXT, 
                        v_passenger_record.name, v_passenger_record.seat_label, v_passenger_record.route;
END;
$$;


--
-- Name: current_profile_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_profile_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT p.id
  FROM public.profiles p
  WHERE p.supa_auth_id = auth.uid()
  LIMIT 1
$$;


--
-- Name: current_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public."current_role"() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT p.role
  FROM public.profiles p
  WHERE p.supa_auth_id = auth.uid()
  LIMIT 1
$$;


--
-- Name: current_tenant_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_tenant_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT p.tenant_id
  FROM public.profiles p
  WHERE p.supa_auth_id = auth.uid()
  LIMIT 1
$$;


--
-- Name: enforce_seat_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_seat_assignment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    bus_rec RECORD;
BEGIN
    SELECT b.id, b.seat_map INTO bus_rec
    FROM public.trips t JOIN public.buses b ON b.id = t.bus_id
    WHERE t.id = NEW.trip_id;

    IF bus_rec.id IS NULL THEN
        RAISE EXCEPTION 'Cannot assign seat: no bus assigned to this trip yet';
    END IF;

    IF bus_rec.seat_map IS NULL OR NOT (bus_rec.seat_map->'seats' @> to_jsonb(ARRAY[NEW.seat_label]::text[])) THEN
        RAISE EXCEPTION 'Invalid seat % for this bus', NEW.seat_label;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: generate_ticket_number(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_ticket_number() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_new_ticket_text TEXT;
  v_exists BOOLEAN;
BEGIN
  LOOP
    -- Generates a code like 'TE-8F2AJK'
    v_new_ticket_text := 'TE-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 8));
    
    -- Check if it already exists
    SELECT EXISTS(SELECT 1 FROM public.booking_passengers WHERE ticket_number = v_new_ticket_text) INTO v_exists;
    EXIT WHEN NOT v_exists;
  END LOOP;
  
  NEW.ticket_number := v_new_ticket_text;
  RETURN NEW;
END;
$$;


--
-- Name: get_or_create_profile(text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_profile(p_full_name text, p_phone text, p_national_id text, p_tenant_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_profile_id UUID;
BEGIN
    -- 1. Try to find existing profile by National ID (most accurate)
    SELECT id INTO v_profile_id FROM public.profiles 
    WHERE national_id = p_national_id AND tenant_id = p_tenant_id;

    -- 2. If not found, try by Phone
    IF v_profile_id IS NULL THEN
        SELECT id INTO v_profile_id FROM public.profiles 
        WHERE phone = p_phone AND tenant_id = p_tenant_id;
    END IF;

    -- 3. If still not found, create a "Shadow Profile"
    IF v_profile_id IS NULL THEN
        INSERT INTO public.profiles (full_name, phone, national_id, tenant_id, role)
        VALUES (p_full_name, p_phone, p_national_id, p_tenant_id, 'passenger')
        RETURNING id INTO v_profile_id;
    END IF;

    RETURN v_profile_id;
END;
$$;


--
-- Name: get_user_permissions(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_permissions(user_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    target_user_id UUID := COALESCE(user_id, auth.uid());
    user_role TEXT;
    user_tenant_id UUID;
    resolved_profile_id UUID;
    permissions JSONB := '{}'::JSONB;
BEGIN
    -- Resolve either by profiles.id OR profiles.supa_auth_id
    SELECT id, role, tenant_id
      INTO resolved_profile_id, user_role, user_tenant_id
      FROM public.profiles
     WHERE id = target_user_id
        OR supa_auth_id = target_user_id
     LIMIT 1;

    IF user_role IS NULL THEN
        RETURN '{}'::JSONB;
    END IF;

    SELECT rp.permissions
      INTO permissions
      FROM public.role_permissions rp
     WHERE rp.role = user_role;

    IF permissions IS NULL THEN
        permissions := '{}'::JSONB;
    END IF;

    permissions := permissions || jsonb_build_object(
        'user_id', resolved_profile_id::TEXT,
        'tenant_id', COALESCE(user_tenant_id::TEXT, 'null'),
        'role', user_role
    );

    RETURN permissions;
END;
$$;


--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$DECLARE
    v_meta_nat_id TEXT;
    v_meta_full_name TEXT;
    v_email_prefix TEXT;
    v_email TEXT;
BEGIN
    -- 1. Prepare data
    v_meta_nat_id := NEW.raw_user_meta_data->>'national_id';
    v_meta_full_name := NEW.raw_user_meta_data->>'full_name';
    v_email_prefix := split_part(NEW.email, '@', 1);
    v_email := NEW.email;

    -- 2. Attempt to claim an existing profile
    UPDATE public.profiles
    SET 
        supa_auth_id = NEW.id,
        full_name = COALESCE(full_name, v_meta_full_name),
        phone = COALESCE(phone, NEW.phone),
        email = COALESCE(email, v_email), -- ✅ add email fill
        updated_at = NOW()
    WHERE (
        -- Priority 1: national ID
        (national_id IS NOT NULL AND national_id = v_meta_nat_id)

        OR

        -- Priority 2: email match
        (email IS NOT NULL AND email = v_email)

        OR

        -- Priority 3: fallback name match
        (national_id IS NULL AND email IS NULL AND full_name ILIKE v_email_prefix || '%')
    )
    AND supa_auth_id IS NULL;

    -- 3. If no profile was linked, create a new one
    IF NOT FOUND THEN
        INSERT INTO public.profiles (
            supa_auth_id,
            full_name,
            phone,
            national_id,
            email, -- ✅ include email
            role,
            tenant_id
        )
        VALUES (
            NEW.id,
            COALESCE(v_meta_full_name, v_email_prefix),
            NEW.phone,
            v_meta_nat_id,
            v_email, -- ✅ store email
            'passenger',
            NULLIF(NEW.raw_user_meta_data->>'tenant_id', '')::UUID
        );
    END IF;

    RETURN NEW;

EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'handle_new_user failed: %', SQLERRM;
    RETURN NEW;
END;$$;


--
-- Name: handle_new_user_sync(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user_sync() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  -- Check if a profile already exists for this person (by National ID in metadata)
  -- We assume you collect 'national_id' during Supabase Sign-up
  UPDATE public.profiles
  SET supa_auth_id = NEW.id,
      full_name = COALESCE(full_name, NEW.raw_user_meta_data->>'full_name')
  WHERE national_id = NEW.raw_user_meta_data->>'national_id'
  AND supa_auth_id IS NULL;

  -- If no profile was updated (meaning they are a brand new customer)
  IF NOT FOUND THEN
    INSERT INTO public.profiles (supa_auth_id, full_name, phone, national_id, role)
    VALUES (
      NEW.id,
      NEW.raw_user_meta_data->>'full_name',
      NEW.phone,
      NEW.raw_user_meta_data->>'national_id',
      'passenger'
    );
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: is_super_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_super_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE supa_auth_id = auth.uid()
    AND role = 'super_admin'
  )
$$;


--
-- Name: log_profile_role_changes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_profile_role_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_actor_profile_id UUID;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        SELECT id INTO v_actor_profile_id
        FROM public.profiles
        WHERE supa_auth_id = auth.uid()
        LIMIT 1;
    END IF;

    IF OLD.role IS DISTINCT FROM NEW.role THEN
        INSERT INTO public.audit_log (
            tenant_id,
            actor_id,
            action,
            target_type,
            target_id,
            old_value,
            new_value,
            changes
        ) VALUES (
            NEW.tenant_id,
            v_actor_profile_id,
            'profile_role_change',
            'profile',
            NEW.id::TEXT,
            jsonb_build_object('role', OLD.role),
            jsonb_build_object('role', NEW.role),
            'Role changed from ' || COALESCE(OLD.role, 'null') || ' to ' || NEW.role
        );
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: trigger_set_timestamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trigger_set_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


--
-- Name: update_user_role(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_user_role(target_user_id uuid, new_role text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    caller_id UUID := auth.uid();
    caller_profile_id UUID;
    caller_role TEXT;
    caller_tenant_id UUID;
    target_tenant_id UUID;
    target_old_role TEXT;
    allowed_roles TEXT[] := ARRAY['passenger', 'staff', 'admin', 'super_admin'];
BEGIN
    SELECT id, role, tenant_id
      INTO caller_profile_id, caller_role, caller_tenant_id
      FROM public.profiles
     WHERE supa_auth_id = caller_id;

    IF caller_role IS NULL THEN
        RETURN QUERY SELECT false, 'Caller profile not found'::TEXT;
        RETURN;
    END IF;

    IF caller_role NOT IN ('admin', 'super_admin') THEN
      RETURN QUERY SELECT false, 'Only admin or super_admin can update roles'::TEXT;
        RETURN;
    END IF;

    IF target_user_id = caller_profile_id THEN
        RETURN QUERY SELECT false, 'Cannot change your own role'::TEXT;
        RETURN;
    END IF;

    SELECT tenant_id, role
      INTO target_tenant_id, target_old_role
      FROM public.profiles
     WHERE id = target_user_id;

    IF target_tenant_id IS NULL THEN
        RETURN QUERY SELECT false, 'Target profile not found'::TEXT;
        RETURN;
    END IF;

    IF target_tenant_id <> caller_tenant_id THEN
        RETURN QUERY SELECT false, 'Cross-tenant role updates are not allowed'::TEXT;
        RETURN;
    END IF;

    IF new_role = 'super_admin' AND caller_role <> 'super_admin' THEN
      RETURN QUERY SELECT false, 'Only super_admin can assign super_admin role'::TEXT;
      RETURN;
    END IF;

    IF NOT (new_role = ANY(allowed_roles)) THEN
      RETURN QUERY SELECT false, 'Invalid role. Allowed: passenger, staff, admin, super_admin'::TEXT;
        RETURN;
    END IF;

    UPDATE public.profiles
       SET role = new_role,
           updated_at = NOW()
     WHERE id = target_user_id;

    INSERT INTO public.audit_log (
        tenant_id,
        actor_id,
        action,
        target_type,
        target_id,
        old_value,
        new_value,
        changes
    ) VALUES (
        caller_tenant_id,
        caller_profile_id,
        'role_change',
        'profile',
        target_user_id::TEXT,
        jsonb_build_object('role', target_old_role),
        jsonb_build_object('role', new_role),
        'Role updated from ' || COALESCE(target_old_role, 'null') || ' to ' || new_role
    );

    RETURN QUERY SELECT true, 'Role updated successfully'::TEXT;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ads (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    img_url text,
    "tenantId" uuid,
    text_status text
);


--
-- Name: ads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ads ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.ads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    tenant_id uuid,
    actor_id uuid,
    action text NOT NULL,
    target_type text,
    target_id text,
    old_value jsonb,
    new_value jsonb,
    changes text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_log_id_seq OWNED BY public.audit_log.id;


--
-- Name: audit_log_archive; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log_archive (
    id bigint DEFAULT nextval('public.audit_log_id_seq'::regclass) NOT NULL,
    tenant_id uuid,
    actor_id uuid,
    action text NOT NULL,
    target_type text,
    target_id text,
    old_value jsonb,
    new_value jsonb,
    changes text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: booking_passengers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_passengers (
    id bigint NOT NULL,
    booking_id bigint NOT NULL,
    name text NOT NULL,
    contact_phone text,
    national_id text,
    is_child boolean DEFAULT false,
    linked_profile_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    ticket_token uuid DEFAULT gen_random_uuid(),
    checked_in_at timestamp with time zone,
    checked_in_by uuid,
    ticket_number text
);


--
-- Name: booking_passengers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.booking_passengers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: booking_passengers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.booking_passengers_id_seq OWNED BY public.booking_passengers.id;


--
-- Name: booking_reschedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_reschedules (
    id bigint NOT NULL,
    tenant_id uuid NOT NULL,
    booking_id bigint NOT NULL,
    old_trip_id bigint NOT NULL,
    new_trip_id bigint NOT NULL,
    rescheduled_by_profile_id uuid,
    reason text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: booking_reschedules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.booking_reschedules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: booking_reschedules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.booking_reschedules_id_seq OWNED BY public.booking_reschedules.id;


--
-- Name: bookings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bookings (
    id bigint NOT NULL,
    tenant_id uuid NOT NULL,
    trip_id bigint,
    booked_by_profile_id uuid,
    booking_type text NOT NULL,
    total_passengers integer NOT NULL,
    total_fare numeric(10,2) NOT NULL,
    status text DEFAULT 'pending'::text,
    expires_at timestamp with time zone DEFAULT (now() + '30 days'::interval),
    reschedule_count integer DEFAULT 0 NOT NULL,
    original_booking_id bigint,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    route_id bigint,
    is_open_ticket boolean DEFAULT false,
    CONSTRAINT bookings_booking_type_check CHECK ((booking_type = ANY (ARRAY['online'::text, 'walkin'::text, 'ussd'::text]))),
    CONSTRAINT bookings_reschedule_count_check CHECK ((reschedule_count <= 1)),
    CONSTRAINT bookings_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'confirmed'::text, 'cancelled'::text]))),
    CONSTRAINT bookings_total_passengers_check CHECK ((total_passengers > 0)),
    CONSTRAINT bookings_trip_or_open_ticket_check CHECK ((((trip_id IS NOT NULL) AND (is_open_ticket = false)) OR ((trip_id IS NULL) AND (is_open_ticket = true) AND (route_id IS NOT NULL)))),
    CONSTRAINT bookings_trip_or_route_check CHECK (((trip_id IS NOT NULL) OR (route_id IS NOT NULL)))
);


--
-- Name: COLUMN bookings.trip_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.bookings.trip_id IS 'Trip ID - NULL for open tickets (date TBD), populated when trip is assigned';


--
-- Name: COLUMN bookings.route_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.bookings.route_id IS 'Required for open tickets (when trip_id is NULL). Indicates which route the ticket is valid for.';


--
-- Name: COLUMN bookings.is_open_ticket; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.bookings.is_open_ticket IS 'True if passenger has a floating ticket not yet assigned to a specific trip. trip_id will be NULL.';


--
-- Name: bookings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bookings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bookings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bookings_id_seq OWNED BY public.bookings.id;


--
-- Name: buses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.buses (
    id bigint NOT NULL,
    tenant_id uuid NOT NULL,
    registration_number text NOT NULL,
    capacity integer NOT NULL,
    seat_map jsonb,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    amenities jsonb DEFAULT '[]'::jsonb,
    CONSTRAINT buses_capacity_check CHECK ((capacity > 0))
);


--
-- Name: COLUMN buses.amenities; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.buses.amenities IS 'List of amenities e.g. ["Wi-Fi", "AC", "USB Ports"]';


--
-- Name: buses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.buses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: buses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.buses_id_seq OWNED BY public.buses.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text NOT NULL,
    message text NOT NULL,
    category public.notification_category NOT NULL,
    is_read boolean DEFAULT false,
    metadata jsonb DEFAULT '{}'::jsonb,
    tenant_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id bigint NOT NULL,
    booking_id bigint NOT NULL,
    amount numeric(10,2) NOT NULL,
    payment_method text NOT NULL,
    status text DEFAULT 'pending'::text,
    transaction_reference text,
    paid_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT payments_payment_method_check CHECK ((payment_method = ANY (ARRAY['mobile_money'::text, 'cash'::text, 'card'::text, 'bank'::text]))),
    CONSTRAINT payments_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'completed'::text, 'failed'::text, 'refunded'::text])))
);


--
-- Name: payments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.payments_id_seq OWNED BY public.payments.id;


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    supa_auth_id uuid,
    full_name text,
    phone text,
    national_id text,
    role text DEFAULT 'passenger'::text,
    tenant_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text,
    profile_url text DEFAULT ''::text,
    CONSTRAINT profiles_role_check CHECK ((role = ANY (ARRAY['passenger'::text, 'staff'::text, 'admin'::text, 'super_admin'::text])))
);


--
-- Name: refunds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refunds (
    id bigint NOT NULL,
    tenant_id uuid NOT NULL,
    booking_id bigint NOT NULL,
    payment_id bigint,
    refund_amount numeric(10,2) NOT NULL,
    deduction_percent numeric(5,2) DEFAULT 0,
    deduction_amount numeric(10,2) GENERATED ALWAYS AS (((refund_amount * deduction_percent) / (100)::numeric)) STORED,
    net_refund_amount numeric(10,2) GENERATED ALWAYS AS ((refund_amount - ((refund_amount * deduction_percent) / (100)::numeric))) STORED,
    status text DEFAULT 'pending'::text NOT NULL,
    refund_method text NOT NULL,
    transaction_reference text,
    processed_at timestamp with time zone,
    reason text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT refunds_refund_method_check CHECK ((refund_method = ANY (ARRAY['mobile_money'::text, 'cash'::text, 'bank'::text]))),
    CONSTRAINT refunds_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'processing'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: refunds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.refunds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: refunds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.refunds_id_seq OWNED BY public.refunds.id;


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permissions (
    id bigint NOT NULL,
    role text NOT NULL,
    permissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: role_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.role_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.role_permissions_id_seq OWNED BY public.role_permissions.id;


--
-- Name: routes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routes (
    id bigint NOT NULL,
    tenant_id uuid NOT NULL,
    route_code text NOT NULL,
    origin_stage_id bigint NOT NULL,
    destination_stage_id bigint NOT NULL,
    intermediate_stops jsonb,
    base_fare numeric(10,2) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: routes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.routes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: routes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.routes_id_seq OWNED BY public.routes.id;


--
-- Name: schedule_masters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedule_masters (
    id bigint NOT NULL,
    tenant_id uuid NOT NULL,
    route_id bigint NOT NULL,
    bus_id bigint NOT NULL,
    frequency text DEFAULT 'daily'::text NOT NULL,
    days_of_week integer[] DEFAULT '{0,1,2,3,4,5,6}'::integer[] NOT NULL,
    window_size integer DEFAULT 30 NOT NULL,
    departure_time time without time zone NOT NULL,
    arrival_time time without time zone,
    auto_extend_enabled boolean DEFAULT false NOT NULL,
    last_generated_date date NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT schedule_masters_frequency_check CHECK ((frequency = ANY (ARRAY['daily'::text, 'weekdays'::text, 'weekends'::text, 'custom'::text]))),
    CONSTRAINT schedule_masters_window_size_check CHECK (((window_size > 0) AND (window_size <= 90)))
);


--
-- Name: schedule_masters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.schedule_masters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: schedule_masters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.schedule_masters_id_seq OWNED BY public.schedule_masters.id;


--
-- Name: seat_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seat_assignments (
    id bigint NOT NULL,
    trip_id bigint NOT NULL,
    booking_passenger_id bigint NOT NULL,
    seat_label text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);

ALTER TABLE ONLY public.seat_assignments REPLICA IDENTITY FULL;


--
-- Name: seat_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seat_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seat_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.seat_assignments_id_seq OWNED BY public.seat_assignments.id;


--
-- Name: stages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stages (
    id bigint NOT NULL,
    tenant_id uuid NOT NULL,
    stage_name text NOT NULL,
    location text,
    is_major_stage boolean DEFAULT false,
    coordinates jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE stages; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.stages IS 'Bus stages/stops. Handles cases like Dedza using Lilongwe stage.';


--
-- Name: stages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stages_id_seq OWNED BY public.stages.id;


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    contact text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    settings jsonb DEFAULT '{}'::jsonb
);


--
-- Name: COLUMN tenants.settings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenants.settings IS 'JSONB settings for tenant including:
- logo_url: string - URL to company logo in Supabase Storage
- logo_storage_path: string - Storage path for logo file
- primary_color: string - Brand primary color (hex)
- secondary_color: string - Brand secondary color (hex)
- theme: object - UI theme preferences
- features: object - Feature toggles
- notifications: object - Notification settings
- receipts: object - Receipt customization
- booking_rules: object - Custom booking rules
- payment_config: object - Payment method settings';


--
-- Name: trips; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trips (
    id bigint NOT NULL,
    tenant_id uuid NOT NULL,
    route_id bigint NOT NULL,
    bus_id bigint,
    departure_datetime timestamp with time zone NOT NULL,
    arrival_datetime timestamp with time zone,
    boarding_stage_id bigint,
    alighting_stage_id bigint,
    status text DEFAULT 'scheduled'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    seat_conflict_warning boolean DEFAULT false,
    original_bus_id bigint,
    schedule_master_id bigint,
    CONSTRAINT trips_status_check CHECK ((status = ANY (ARRAY['scheduled'::text, 'active'::text, 'completed'::text, 'cancelled'::text])))
);

ALTER TABLE ONLY public.trips REPLICA IDENTITY FULL;


--
-- Name: COLUMN trips.seat_conflict_warning; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.trips.seat_conflict_warning IS 'True if bus was swapped and new bus has different seat layout. Staff should review seat assignments.';


--
-- Name: COLUMN trips.original_bus_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.trips.original_bus_id IS 'Original bus assigned when trip was created. Preserved for audit trail when bus is swapped.';


--
-- Name: trips_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.trips_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: trips_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.trips_id_seq OWNED BY public.trips.id;


--
-- Name: v_daily_sales_report; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_daily_sales_report AS
 SELECT t.tenant_id,
    date(b.created_at) AS sale_date,
    count(DISTINCT b.id) AS total_bookings,
    count(bp.id) AS total_passengers,
    sum(b.total_fare) AS total_revenue_mwk
   FROM ((public.bookings b
     JOIN public.trips t ON ((b.trip_id = t.id)))
     LEFT JOIN public.booking_passengers bp ON ((bp.booking_id = b.id)))
  WHERE (b.status = ANY (ARRAY['confirmed'::text, 'cancelled'::text]))
  GROUP BY t.tenant_id, (date(b.created_at))
  ORDER BY (date(b.created_at)) DESC;


--
-- Name: v_passenger_manifest; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_passenger_manifest AS
 SELECT t.id AS trip_id,
    t.departure_datetime,
    t.status AS trip_status,
    t.bus_id,
    r.route_code,
    os.stage_name AS origin_stage,
    ds.stage_name AS destination_stage,
    bs.stage_name AS boarding_stage,
    asg.stage_name AS alighting_stage,
    b.id AS booking_id,
    b.booking_type,
    b.status AS booking_status,
    bp.name AS passenger_name,
    bp.contact_phone,
    bp.national_id,
    bp.is_child,
    sa.seat_label,
    p.payment_method,
    p.status AS payment_status
   FROM (((((((((public.trips t
     JOIN public.routes r ON ((r.id = t.route_id)))
     JOIN public.stages os ON ((os.id = r.origin_stage_id)))
     JOIN public.stages ds ON ((ds.id = r.destination_stage_id)))
     LEFT JOIN public.stages bs ON ((bs.id = t.boarding_stage_id)))
     LEFT JOIN public.stages asg ON ((asg.id = t.alighting_stage_id)))
     JOIN public.bookings b ON ((b.trip_id = t.id)))
     JOIN public.booking_passengers bp ON ((bp.booking_id = b.id)))
     LEFT JOIN public.seat_assignments sa ON (((sa.trip_id = t.id) AND (sa.booking_passenger_id = bp.id))))
     LEFT JOIN public.payments p ON ((p.booking_id = b.id)))
  WHERE (b.status = ANY (ARRAY['confirmed'::text, 'pending'::text]))
  ORDER BY t.departure_datetime, sa.seat_label, bp.name;


--
-- Name: VIEW v_passenger_manifest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.v_passenger_manifest IS 'Passenger list for check-in with boarding/alighting stages';


--
-- Name: audit_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log ALTER COLUMN id SET DEFAULT nextval('public.audit_log_id_seq'::regclass);


--
-- Name: booking_passengers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_passengers ALTER COLUMN id SET DEFAULT nextval('public.booking_passengers_id_seq'::regclass);


--
-- Name: booking_reschedules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_reschedules ALTER COLUMN id SET DEFAULT nextval('public.booking_reschedules_id_seq'::regclass);


--
-- Name: bookings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings ALTER COLUMN id SET DEFAULT nextval('public.bookings_id_seq'::regclass);


--
-- Name: buses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buses ALTER COLUMN id SET DEFAULT nextval('public.buses_id_seq'::regclass);


--
-- Name: payments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments ALTER COLUMN id SET DEFAULT nextval('public.payments_id_seq'::regclass);


--
-- Name: refunds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds ALTER COLUMN id SET DEFAULT nextval('public.refunds_id_seq'::regclass);


--
-- Name: role_permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions ALTER COLUMN id SET DEFAULT nextval('public.role_permissions_id_seq'::regclass);


--
-- Name: routes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routes ALTER COLUMN id SET DEFAULT nextval('public.routes_id_seq'::regclass);


--
-- Name: schedule_masters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_masters ALTER COLUMN id SET DEFAULT nextval('public.schedule_masters_id_seq'::regclass);


--
-- Name: seat_assignments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seat_assignments ALTER COLUMN id SET DEFAULT nextval('public.seat_assignments_id_seq'::regclass);


--
-- Name: stages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages ALTER COLUMN id SET DEFAULT nextval('public.stages_id_seq'::regclass);


--
-- Name: trips id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips ALTER COLUMN id SET DEFAULT nextval('public.trips_id_seq'::regclass);


--
-- Name: ads ads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ads
    ADD CONSTRAINT ads_pkey PRIMARY KEY (id);


--
-- Name: audit_log_archive audit_log_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log_archive
    ADD CONSTRAINT audit_log_archive_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: booking_passengers booking_passengers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_pkey PRIMARY KEY (id);


--
-- Name: booking_passengers booking_passengers_ticket_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_ticket_number_key UNIQUE (ticket_number);


--
-- Name: booking_reschedules booking_reschedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_pkey PRIMARY KEY (id);


--
-- Name: bookings bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_pkey PRIMARY KEY (id);


--
-- Name: buses buses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buses
    ADD CONSTRAINT buses_pkey PRIMARY KEY (id);


--
-- Name: buses buses_tenant_id_registration_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buses
    ADD CONSTRAINT buses_tenant_id_registration_number_key UNIQUE (tenant_id, registration_number);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_national_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_national_id_key UNIQUE (national_id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_supa_auth_id_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_supa_auth_id_unique UNIQUE (supa_auth_id);


--
-- Name: refunds refunds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_role_key UNIQUE (role);


--
-- Name: routes routes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_pkey PRIMARY KEY (id);


--
-- Name: routes routes_tenant_id_route_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_tenant_id_route_code_key UNIQUE (tenant_id, route_code);


--
-- Name: schedule_masters schedule_masters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_masters
    ADD CONSTRAINT schedule_masters_pkey PRIMARY KEY (id);


--
-- Name: seat_assignments seat_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_pkey PRIMARY KEY (id);


--
-- Name: seat_assignments seat_assignments_trip_id_seat_label_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_trip_id_seat_label_key UNIQUE (trip_id, seat_label);


--
-- Name: stages stages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_pkey PRIMARY KEY (id);


--
-- Name: stages stages_tenant_id_stage_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_tenant_id_stage_name_key UNIQUE (tenant_id, stage_name);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: trips trips_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_pkey PRIMARY KEY (id);


--
-- Name: idx_audit_log_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_action ON public.audit_log USING btree (action);


--
-- Name: idx_audit_log_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_actor ON public.audit_log USING btree (actor_id);


--
-- Name: idx_audit_log_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_target ON public.audit_log USING btree (target_type, target_id);


--
-- Name: idx_audit_log_tenant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_tenant_created ON public.audit_log USING btree (tenant_id, created_at DESC);


--
-- Name: idx_booking_passengers_booking; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_booking_passengers_booking ON public.booking_passengers USING btree (booking_id);


--
-- Name: idx_bookings_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bookings_expires ON public.bookings USING btree (expires_at);


--
-- Name: idx_bookings_open_tickets; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bookings_open_tickets ON public.bookings USING btree (tenant_id, status) WHERE (trip_id IS NULL);


--
-- Name: idx_bookings_route_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bookings_route_id ON public.bookings USING btree (route_id);


--
-- Name: idx_bookings_tenant_trip; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bookings_tenant_trip ON public.bookings USING btree (tenant_id, trip_id);


--
-- Name: idx_passengers_ticket_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_passengers_ticket_token ON public.booking_passengers USING btree (ticket_token);


--
-- Name: idx_routes_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_routes_tenant ON public.routes USING btree (tenant_id);


--
-- Name: idx_schedule_masters_auto_extend; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_schedule_masters_auto_extend ON public.schedule_masters USING btree (tenant_id, auto_extend_enabled) WHERE (auto_extend_enabled = true);


--
-- Name: idx_schedule_masters_route; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_schedule_masters_route ON public.schedule_masters USING btree (route_id);


--
-- Name: idx_schedule_masters_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_schedule_masters_tenant ON public.schedule_masters USING btree (tenant_id);


--
-- Name: idx_seat_assignments_trip; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_seat_assignments_trip ON public.seat_assignments USING btree (trip_id);


--
-- Name: idx_stages_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stages_tenant ON public.stages USING btree (tenant_id);


--
-- Name: idx_tenants_settings; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenants_settings ON public.tenants USING gin (settings);


--
-- Name: idx_trips_bus_datetime; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trips_bus_datetime ON public.trips USING btree (tenant_id, bus_id, departure_datetime, arrival_datetime) WHERE (status = ANY (ARRAY['scheduled'::text, 'active'::text]));


--
-- Name: idx_trips_departure; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trips_departure ON public.trips USING btree (departure_datetime);


--
-- Name: idx_trips_departure_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trips_departure_date ON public.trips USING btree (tenant_id, departure_datetime);


--
-- Name: idx_trips_schedule_master; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trips_schedule_master ON public.trips USING btree (schedule_master_id);


--
-- Name: idx_trips_tenant_route; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trips_tenant_route ON public.trips USING btree (tenant_id, route_id);


--
-- Name: booking_passengers audit_booking_passengers; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_booking_passengers AFTER INSERT OR DELETE OR UPDATE ON public.booking_passengers FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: booking_reschedules audit_booking_reschedules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_booking_reschedules AFTER INSERT OR DELETE OR UPDATE ON public.booking_reschedules FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: bookings audit_bookings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_bookings AFTER INSERT OR DELETE OR UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: buses audit_buses; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_buses AFTER INSERT OR DELETE OR UPDATE ON public.buses FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: payments audit_payments; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_payments AFTER INSERT OR DELETE OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: profiles audit_profiles; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_profiles AFTER INSERT OR DELETE OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: refunds audit_refunds; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_refunds AFTER INSERT OR DELETE OR UPDATE ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: routes audit_routes; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_routes AFTER INSERT OR DELETE OR UPDATE ON public.routes FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: schedule_masters audit_schedule_masters; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_schedule_masters AFTER INSERT OR DELETE OR UPDATE ON public.schedule_masters FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: seat_assignments audit_seat_assignments; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_seat_assignments AFTER INSERT OR DELETE OR UPDATE ON public.seat_assignments FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: stages audit_stages; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_stages AFTER INSERT OR DELETE OR UPDATE ON public.stages FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: tenants audit_tenants; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_tenants AFTER INSERT OR DELETE OR UPDATE ON public.tenants FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: trips audit_trips; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_trips AFTER INSERT OR DELETE OR UPDATE ON public.trips FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: bookings set_timestamp_bookings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_bookings BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: buses set_timestamp_buses; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_buses BEFORE UPDATE ON public.buses FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: profiles set_timestamp_profiles; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_profiles BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: refunds set_timestamp_refunds; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_refunds BEFORE UPDATE ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: routes set_timestamp_routes; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_routes BEFORE UPDATE ON public.routes FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: schedule_masters set_timestamp_schedule_masters; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_schedule_masters BEFORE UPDATE ON public.schedule_masters FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: stages set_timestamp_stages; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_stages BEFORE UPDATE ON public.stages FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: tenants set_timestamp_tenants; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_tenants BEFORE UPDATE ON public.tenants FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: trips set_timestamp_trips; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp_trips BEFORE UPDATE ON public.trips FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: booking_passengers trigger_assign_ticket_number; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_assign_ticket_number BEFORE INSERT ON public.booking_passengers FOR EACH ROW WHEN ((new.ticket_number IS NULL)) EXECUTE FUNCTION public.generate_ticket_number();


--
-- Name: seat_assignments trigger_enforce_seat; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_enforce_seat BEFORE INSERT OR UPDATE ON public.seat_assignments FOR EACH ROW EXECUTE FUNCTION public.enforce_seat_assignment();


--
-- Name: profiles trigger_profile_role_changes; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_profile_role_changes AFTER UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.log_profile_role_changes();


--
-- Name: ads ads_tenantId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ads
    ADD CONSTRAINT "ads_tenantId_fkey" FOREIGN KEY ("tenantId") REFERENCES public.tenants(id);


--
-- Name: audit_log audit_log_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: audit_log audit_log_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: booking_passengers booking_passengers_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: booking_passengers booking_passengers_checked_in_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_checked_in_by_fkey FOREIGN KEY (checked_in_by) REFERENCES public.profiles(id);


--
-- Name: booking_reschedules booking_reschedules_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: booking_reschedules booking_reschedules_new_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_new_trip_id_fkey FOREIGN KEY (new_trip_id) REFERENCES public.trips(id);


--
-- Name: booking_reschedules booking_reschedules_old_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_old_trip_id_fkey FOREIGN KEY (old_trip_id) REFERENCES public.trips(id);


--
-- Name: booking_reschedules booking_reschedules_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: bookings bookings_booked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_booked_by_fkey FOREIGN KEY (booked_by_profile_id) REFERENCES public.profiles(id);


--
-- Name: bookings bookings_original_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_original_booking_id_fkey FOREIGN KEY (original_booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;


--
-- Name: bookings bookings_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.routes(id);


--
-- Name: bookings bookings_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: bookings bookings_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_trip_id_fkey FOREIGN KEY (trip_id) REFERENCES public.trips(id);


--
-- Name: buses buses_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buses
    ADD CONSTRAINT buses_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: payments payments_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (supa_auth_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE SET NULL;


--
-- Name: refunds refunds_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: refunds refunds_payment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.payments(id);


--
-- Name: refunds refunds_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: routes routes_destination_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_destination_stage_id_fkey FOREIGN KEY (destination_stage_id) REFERENCES public.stages(id);


--
-- Name: routes routes_origin_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_origin_stage_id_fkey FOREIGN KEY (origin_stage_id) REFERENCES public.stages(id);


--
-- Name: routes routes_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: schedule_masters schedule_masters_bus_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_masters
    ADD CONSTRAINT schedule_masters_bus_id_fkey FOREIGN KEY (bus_id) REFERENCES public.buses(id) ON DELETE CASCADE;


--
-- Name: schedule_masters schedule_masters_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_masters
    ADD CONSTRAINT schedule_masters_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.routes(id) ON DELETE CASCADE;


--
-- Name: schedule_masters schedule_masters_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_masters
    ADD CONSTRAINT schedule_masters_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: seat_assignments seat_assignments_booking_passenger_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_booking_passenger_id_fkey FOREIGN KEY (booking_passenger_id) REFERENCES public.booking_passengers(id);


--
-- Name: seat_assignments seat_assignments_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_trip_id_fkey FOREIGN KEY (trip_id) REFERENCES public.trips(id);


--
-- Name: stages stages_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: trips trips_alighting_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_alighting_stage_id_fkey FOREIGN KEY (alighting_stage_id) REFERENCES public.stages(id);


--
-- Name: trips trips_boarding_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_boarding_stage_id_fkey FOREIGN KEY (boarding_stage_id) REFERENCES public.stages(id);


--
-- Name: trips trips_bus_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_bus_id_fkey FOREIGN KEY (bus_id) REFERENCES public.buses(id);


--
-- Name: trips trips_original_bus_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_original_bus_id_fkey FOREIGN KEY (original_bus_id) REFERENCES public.buses(id);


--
-- Name: trips trips_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.routes(id);


--
-- Name: trips trips_schedule_master_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_schedule_master_id_fkey FOREIGN KEY (schedule_master_id) REFERENCES public.schedule_masters(id) ON DELETE SET NULL;


--
-- Name: trips trips_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: audit_log Audit log: admin read tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Audit log: admin read tenant" ON public.audit_log FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: audit_log Audit log: super_admin read all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Audit log: super_admin read all" ON public.audit_log FOR SELECT USING (public.is_super_admin());


--
-- Name: booking_passengers Booking passengers: passenger own bookings; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Booking passengers: passenger own bookings" ON public.booking_passengers FOR SELECT USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE (b.booked_by_profile_id = public.current_profile_id()))));


--
-- Name: booking_passengers Booking passengers: staff admin tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Booking passengers: staff admin tenant" ON public.booking_passengers FOR SELECT USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE ((b.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: booking_passengers Booking passengers: staff admin update tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Booking passengers: staff admin update tenant" ON public.booking_passengers FOR UPDATE USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE ((b.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text])))))) WITH CHECK ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE ((b.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: booking_passengers Booking passengers: super_admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Booking passengers: super_admin all" ON public.booking_passengers USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: bookings Bookings: passenger insert own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Bookings: passenger insert own" ON public.bookings FOR INSERT WITH CHECK (((booked_by_profile_id = public.current_profile_id()) AND (public."current_role"() = 'passenger'::text)));


--
-- Name: bookings Bookings: passenger read own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Bookings: passenger read own" ON public.bookings FOR SELECT USING ((booked_by_profile_id = public.current_profile_id()));


--
-- Name: bookings Bookings: passenger update own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Bookings: passenger update own" ON public.bookings FOR UPDATE USING ((booked_by_profile_id = public.current_profile_id())) WITH CHECK ((booked_by_profile_id = public.current_profile_id()));


--
-- Name: bookings Bookings: staff admin insert tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Bookings: staff admin insert tenant" ON public.bookings FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: bookings Bookings: staff admin read tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Bookings: staff admin read tenant" ON public.bookings FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: bookings Bookings: staff admin update tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Bookings: staff admin update tenant" ON public.bookings FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: bookings Bookings: super_admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Bookings: super_admin all" ON public.bookings USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: buses Buses: admin manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Buses: admin manage" ON public.buses USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: buses Buses: super_admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Buses: super_admin all" ON public.buses USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: buses Buses: tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Buses: tenant read" ON public.buses FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: payments Payments: passenger own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Payments: passenger own" ON public.payments FOR SELECT USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE (b.booked_by_profile_id = public.current_profile_id()))));


--
-- Name: payments Payments: passenger update own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Payments: passenger update own" ON public.payments FOR UPDATE USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE (b.booked_by_profile_id = public.current_profile_id())))) WITH CHECK ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE (b.booked_by_profile_id = public.current_profile_id()))));


--
-- Name: payments Payments: staff admin tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Payments: staff admin tenant" ON public.payments FOR SELECT USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE ((b.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: payments Payments: super_admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Payments: super_admin all" ON public.payments USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: profiles Profiles: admin read tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Profiles: admin read tenant" ON public.profiles FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: profiles Profiles: admin update tenant roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Profiles: admin update tenant roles" ON public.profiles FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])) AND (role = ANY (ARRAY['passenger'::text, 'staff'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (role = ANY (ARRAY['passenger'::text, 'staff'::text]))));


--
-- Name: profiles Profiles: read own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Profiles: read own" ON public.profiles FOR SELECT USING ((id = public.current_profile_id()));


--
-- Name: profiles Profiles: super_admin read all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Profiles: super_admin read all" ON public.profiles FOR SELECT USING (public.is_super_admin());


--
-- Name: profiles Profiles: update own non-role; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Profiles: update own non-role" ON public.profiles FOR UPDATE USING ((id = public.current_profile_id())) WITH CHECK (((id = public.current_profile_id()) AND (role = public."current_role"())));


--
-- Name: role_permissions Role permissions: read all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Role permissions: read all" ON public.role_permissions FOR SELECT USING (true);


--
-- Name: routes Routes: admin manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Routes: admin manage" ON public.routes USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: routes Routes: super_admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Routes: super_admin all" ON public.routes USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: routes Routes: tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Routes: tenant read" ON public.routes FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: seat_assignments Seat assignments: passenger own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Seat assignments: passenger own" ON public.seat_assignments FOR SELECT USING ((booking_passenger_id IN ( SELECT bp.id
   FROM (public.booking_passengers bp
     JOIN public.bookings b ON ((b.id = bp.booking_id)))
  WHERE (b.booked_by_profile_id = public.current_profile_id()))));


--
-- Name: seat_assignments Seat assignments: staff admin manage tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Seat assignments: staff admin manage tenant" ON public.seat_assignments USING ((trip_id IN ( SELECT t.id
   FROM public.trips t
  WHERE ((t.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text])))))) WITH CHECK ((trip_id IN ( SELECT t.id
   FROM public.trips t
  WHERE ((t.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: seat_assignments Seat assignments: staff admin tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Seat assignments: staff admin tenant" ON public.seat_assignments FOR SELECT USING ((trip_id IN ( SELECT t.id
   FROM public.trips t
  WHERE ((t.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: seat_assignments Seat assignments: super_admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Seat assignments: super_admin all" ON public.seat_assignments USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: stages Stages: admin manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Stages: admin manage" ON public.stages USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: stages Stages: super_admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Stages: super_admin all" ON public.stages USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: stages Stages: tenant read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Stages: tenant read" ON public.stages FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: tenants Tenants: admin update own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Tenants: admin update own" ON public.tenants FOR UPDATE USING (((id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])))) WITH CHECK (((id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: tenants Tenants: read own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Tenants: read own" ON public.tenants FOR SELECT USING ((id = public.current_tenant_id()));


--
-- Name: tenants Tenants: super_admin read all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Tenants: super_admin read all" ON public.tenants FOR SELECT USING (public.is_super_admin());


--
-- Name: trips Trips: admin delete tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Trips: admin delete tenant" ON public.trips FOR DELETE USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: trips Trips: passengers read published globally; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Trips: passengers read published globally" ON public.trips FOR SELECT USING (((status = ANY (ARRAY['scheduled'::text, 'active'::text])) AND (public."current_role"() = 'passenger'::text)));


--
-- Name: trips Trips: staff and admin insert tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Trips: staff and admin insert tenant" ON public.trips FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: trips Trips: staff and admin read tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Trips: staff and admin read tenant" ON public.trips FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: trips Trips: staff and admin update tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Trips: staff and admin update tenant" ON public.trips FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: trips Trips: super_admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Trips: super_admin all" ON public.trips USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: ads Users can view ads for their tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view ads for their tenant" ON public.ads FOR SELECT TO authenticated USING (("tenantId" = ((auth.jwt() ->> 'tenant_id'::text))::uuid));


--
-- PostgreSQL database dump complete
--

\unrestrict z1jBLSxbnCXerVSaKapcnA5eXXM7G30rmzL6ZwQiNRTEaOeFhqdH6L17N5abdbK

