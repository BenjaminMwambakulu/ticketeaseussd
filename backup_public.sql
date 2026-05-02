--
-- PostgreSQL database dump
--

\restrict P9Gr7Thc0bis1DNpczOBZkdzZCLGVoFp7Jk5hPKTsWHfP2vIn2TpqNdmj4ShOEP

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

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA public;


ALTER SCHEMA public OWNER TO postgres;

--
-- Name: notification_category; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.notification_category AS ENUM (
    'booking',
    'refund',
    'reschedule',
    'chat',
    'system',
    'trip_update',
    'reminder'
);


ALTER TYPE public.notification_category OWNER TO postgres;

--
-- Name: archive_old_audit_logs(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.archive_old_audit_logs() OWNER TO postgres;

--
-- Name: audit_table_change(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.audit_table_change() OWNER TO postgres;

--
-- Name: auto_update_trip_statuses(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.auto_update_trip_statuses() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_now timestamp with time zone := NOW();
    v_today date := CURRENT_DATE;
BEGIN

    -- 1. Set trips to 'active' when departure time has reached
    UPDATE public.trips
    SET 
        status = 'active',
        updated_at = NOW()
    WHERE status = 'scheduled'
      AND departure_datetime <= v_now
      AND tenant_id IS NOT NULL;

    -- 2. Set trips to 'completed' for past dates (at midnight / 12:00 AM logic)
    -- This runs best when scheduled around 12:00 AM or early morning
    UPDATE public.trips
    SET 
        status = 'completed',
        updated_at = NOW()
    WHERE status IN ('scheduled', 'active')
      AND departure_datetime::date < v_today          -- All trips from previous days
      AND status != 'cancelled'
      AND tenant_id IS NOT NULL;

    -- Optional: Log what was changed (for auditing)
    INSERT INTO public.audit_log (
        tenant_id,
        actor_id,
        action,
        target_type,
        target_id,
        changes,
        created_at
    )
    SELECT 
        t.tenant_id,
        NULL,                    -- System process
        'system_auto_status_update',
        'trip',
        t.id::text,
        CASE 
            WHEN t.status = 'active' THEN 'Auto changed from scheduled to active'
            ELSE 'Auto changed from ' || t.status || ' to completed (past date)'
        END,
        NOW()
    FROM public.trips t
    WHERE t.updated_at >= v_now - INTERVAL '5 minutes'   -- Only recently updated by this run
      AND t.tenant_id IS NOT NULL;

END;
$$;


ALTER FUNCTION public.auto_update_trip_statuses() OWNER TO postgres;

--
-- Name: check_bus_conflicts(uuid, bigint, timestamp with time zone, timestamp with time zone, bigint); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.check_bus_conflicts(p_tenant_id uuid, p_bus_id bigint, p_departure_datetime timestamp with time zone, p_arrival_datetime timestamp with time zone, p_exclude_trip_id bigint) OWNER TO postgres;

--
-- Name: check_in_passenger(uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.check_in_passenger(p_ticket_token uuid, p_staff_id uuid) OWNER TO postgres;

--
-- Name: current_profile_id(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.current_profile_id() OWNER TO postgres;

--
-- Name: current_role(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public."current_role"() OWNER TO postgres;

--
-- Name: current_tenant_id(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.current_tenant_id() OWNER TO postgres;

--
-- Name: enforce_seat_assignment(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enforce_seat_assignment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    bus_rec RECORD;
    conflict_exists BOOLEAN;
BEGIN
    -- A. Validate that the bus for this trip actually exists and has this seat label
    SELECT b.id, b.seat_map INTO bus_rec
    FROM public.trips t 
    JOIN public.buses b ON b.id = t.bus_id
    WHERE t.id = NEW.trip_id;

    IF bus_rec.id IS NULL THEN
        RAISE EXCEPTION 'Cannot assign seat: no bus assigned to this trip yet';
    END IF;

    IF bus_rec.seat_map IS NULL OR 
       NOT (bus_rec.seat_map->'seats' @> to_jsonb(ARRAY[NEW.seat_label]::text[])) THEN
        RAISE EXCEPTION 'Invalid seat % for this bus', NEW.seat_label;
    END IF;

    -- B. THE CONFLICT CHECK (Overlap Logic)
    -- A conflict exists ONLY IF the new passenger's journey overlaps with an existing one.
    -- Mathematical Overlap Rule: (NewStart < ExistingEnd) AND (NewEnd > ExistingStart)
    SELECT EXISTS (
        SELECT 1 FROM public.seat_assignments sa
        WHERE sa.trip_id = NEW.trip_id
          AND sa.seat_label = NEW.seat_label
          AND sa.id IS DISTINCT FROM NEW.id -- Don't conflict with yourself on updates
          AND (
              NEW.boarding_rank < sa.alighting_rank 
              AND NEW.alighting_rank > sa.boarding_rank
          )
    ) INTO conflict_exists;

    IF conflict_exists THEN
        RAISE EXCEPTION 'Seat % is already reserved for an overlapping segment of this trip.', 
            NEW.seat_label;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.enforce_seat_assignment() OWNER TO postgres;

--
-- Name: generate_booking_token(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_booking_token() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.booking_token IS NULL THEN
    NEW.booking_token := gen_random_uuid();
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.generate_booking_token() OWNER TO postgres;

--
-- Name: generate_ticket_number(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.generate_ticket_number() OWNER TO postgres;

--
-- Name: get_booked_counts(bigint[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_booked_counts(trip_ids bigint[]) RETURNS TABLE(t_id bigint, booked_count bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT trip_id, COUNT(*)
  FROM seat_assignments
  WHERE trip_id = ANY(trip_ids)
  GROUP BY trip_id;
END;
$$;


ALTER FUNCTION public.get_booked_counts(trip_ids bigint[]) OWNER TO postgres;

--
-- Name: get_leg_fare(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_leg_fare(p_route_id bigint, p_board_id bigint, p_alight_id bigint) RETURNS numeric
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_fare numeric;
BEGIN
    SELECT fare_amount INTO v_fare 
    FROM public.route_fares 
    WHERE route_id = p_route_id 
      AND boarding_stage_id = p_board_id 
      AND alighting_stage_id = p_alight_id;
      
    RETURN COALESCE(v_fare, 0);
END;
$$;


ALTER FUNCTION public.get_leg_fare(p_route_id bigint, p_board_id bigint, p_alight_id bigint) OWNER TO postgres;

--
-- Name: get_or_create_profile(text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.get_or_create_profile(p_full_name text, p_phone text, p_national_id text, p_tenant_id uuid) OWNER TO postgres;

--
-- Name: get_user_permissions(uuid); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.get_user_permissions(user_id uuid) OWNER TO postgres;

--
-- Name: handle_booking_confirmation(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.handle_booking_confirmation() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_full_name text;
    v_route_code text;
    v_origin text;
    v_destination text;
    v_departure_formatted text;
BEGIN
    -- Only run when status changes to 'confirmed'
    IF NEW.status = 'confirmed' AND (OLD.status IS NULL OR OLD.status != 'confirmed') THEN

        -- Get rich information
        SELECT 
            COALESCE(p.full_name, 'Valued Passenger'),
            r.route_code,
            os.stage_name,
            ds.stage_name,
            TO_CHAR(t.departure_datetime, 'DD Mon YYYY, HH24:MI')
        INTO 
            v_full_name, v_route_code, v_origin, v_destination, v_departure_formatted
        FROM public.bookings b
        LEFT JOIN public.profiles p ON p.id = b.booked_by_profile_id
        LEFT JOIN public.routes r ON r.id = b.route_id
        LEFT JOIN public.trips t ON t.id = b.trip_id
        LEFT JOIN public.stages os ON os.id = r.origin_stage_id
        LEFT JOIN public.stages ds ON ds.id = r.destination_stage_id
        WHERE b.id = NEW.id;

        -- Insert rich notification
        INSERT INTO public.notifications (
            profile_id,
            tenant_id,
            title,
            message,
            category,
            target_type,
            metadata,
            sent_by_profile_id
        )
        VALUES (
            NEW.booked_by_profile_id,
            NEW.tenant_id,
            'Booking Confirmed ✓',
            'Dear ' || v_full_name || ', your booking for ' || 
            v_route_code || ' (' || v_origin || ' → ' || v_destination || 
            ') on ' || v_departure_formatted || 
            ' has been confirmed successfully.' || 
            E'\n\nPassengers: ' || NEW.total_passengers || 
            ' | Amount: MWK ' || NEW.total_fare,
            
            'booking',
            'user',
            jsonb_build_object(
                'booking_id', NEW.id,
                'booking_token', NEW.booking_token,
                'trip_id', NEW.trip_id,
                'route_code', v_route_code,
                'total_fare', NEW.total_fare,
                'total_passengers', NEW.total_passengers
            ),
            NULL  -- sent by system
        );

    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.handle_booking_confirmation() OWNER TO postgres;

--
-- Name: handle_booking_confirmation_notification(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.handle_booking_confirmation_notification() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_full_name           text;
    v_route_info          text := 'Unknown Route';
    v_departure_formatted text := 'TBD';
BEGIN
    IF NEW.status = 'confirmed' 
       AND (OLD.status IS NULL OR OLD.status != 'confirmed') THEN

        SELECT 
            COALESCE(p.full_name, 'Valued Passenger'),
            COALESCE(r.route_code || ' - ' || os.stage_name || ' → ' || ds.stage_name, 'Unknown Route'),
            COALESCE(TO_CHAR(t.departure_datetime, 'DD Mon YYYY, HH24:MI'), 'TBD')
        INTO 
            v_full_name, 
            v_route_info, 
            v_departure_formatted
        FROM public.bookings b
        LEFT JOIN public.profiles p ON p.id = b.booked_by_profile_id
        LEFT JOIN public.routes r ON r.id = b.route_id
        LEFT JOIN public.stages os ON os.id = r.origin_stage_id
        LEFT JOIN public.stages ds ON ds.id = r.destination_stage_id
        LEFT JOIN public.trips t ON t.id = b.trip_id
        WHERE b.id = NEW.id;

        INSERT INTO public.notifications (
            profile_id, tenant_id, title, message, category, 
            target_type, metadata, sent_by_profile_id
        )
        VALUES (
            NEW.booked_by_profile_id,
            NEW.tenant_id,
            'Booking Confirmed ✓',
            'Dear ' || v_full_name || ',' || E'\n\n' ||
            'Your booking for **' || v_route_info || '** ' ||
            'on ' || v_departure_formatted || ' has been confirmed successfully.' ||
            E'\n\nPassengers: ' || COALESCE(NEW.total_passengers::text, '0') || 
            ' | Total: MWK ' || COALESCE(NEW.total_fare::text, '0'),

            'booking',
            'user',
            jsonb_build_object(
                'booking_id', NEW.id,
                'booking_token', NEW.booking_token,
                'trip_id', NEW.trip_id,
                'route_id', NEW.route_id,
                'total_fare', NEW.total_fare,
                'total_passengers', NEW.total_passengers
            ),
            NULL
        );

    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.handle_booking_confirmation_notification() OWNER TO postgres;

--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.handle_new_user() OWNER TO postgres;

--
-- Name: handle_new_user_sync(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.handle_new_user_sync() OWNER TO postgres;

--
-- Name: immutable_date(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.immutable_date(ts timestamp with time zone) RETURNS date
    LANGUAGE sql IMMUTABLE
    AS $_$
  SELECT ($1 AT TIME ZONE 'UTC')::date;
$_$;


ALTER FUNCTION public.immutable_date(ts timestamp with time zone) OWNER TO postgres;

--
-- Name: is_super_admin(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.is_super_admin() OWNER TO postgres;

--
-- Name: log_profile_role_changes(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.log_profile_role_changes() OWNER TO postgres;

--
-- Name: search_trips_smart(text, text, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_trips_smart(p_origin text, p_destination text, p_travel_date date) RETURNS TABLE(trip_id integer, route_code text, departure_time timestamp with time zone, arrival_time timestamp with time zone, base_fare numeric, relevance_score integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    t.id,
    r.route_code,
    t.departure_datetime,
    t.arrival_datetime,
    r.base_fare,
    -- Prioritization Logic (Relevance Score)
    CASE 
      WHEN r.route_code = (p_origin || '-' || p_destination) THEN 3  -- Exact Route Match
      WHEN s_orig.stage_name ILIKE p_origin AND s_dest.stage_name ILIKE p_destination THEN 2 -- Exact Location Match
      WHEN s_orig.stage_name ILIKE p_origin OR s_dest.stage_name ILIKE p_destination THEN 1 -- Partial Location Match
      ELSE 0
    END as relevance_score
  FROM trips t
  INNER JOIN routes r ON t.route_id = r.id
  INNER JOIN stages s_orig ON r.origin_stage_id = s_orig.id
  INNER JOIN stages s_dest ON r.destination_stage_id = s_dest.id
  WHERE 
    t.status IN ('scheduled', 'active')
    AND t.departure_datetime::DATE = p_travel_date
    AND (
      r.route_code ILIKE '%' || p_origin || '%' 
      OR r.route_code ILIKE '%' || p_destination || '%'
      OR s_orig.stage_name ILIKE p_origin
      OR s_dest.stage_name ILIKE p_destination
    )
  ORDER BY relevance_score DESC, t.departure_datetime ASC;
END;
$$;


ALTER FUNCTION public.search_trips_smart(p_origin text, p_destination text, p_travel_date date) OWNER TO postgres;

--
-- Name: send_booking_reminder(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.send_booking_reminder() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN 
        SELECT DISTINCT ON (b.booked_by_profile_id, t.id)
            b.id AS booking_id,
            b.booked_by_profile_id,
            b.tenant_id,
            b.total_passengers,
            b.total_fare,
            b.booking_token,
            t.id AS trip_id,
            r.route_code,
            COALESCE(bs.stage_name, os.stage_name) AS origin,
            COALESCE(als.stage_name, ds.stage_name) AS destination,
            t.departure_datetime,
            TO_CHAR(t.departure_datetime, 'DD Mon YYYY, HH24:MI') AS departure_formatted,
            EXTRACT(EPOCH FROM (t.departure_datetime - NOW())) / 3600 AS hours_left,
            COALESCE(p.full_name, 'Passenger') AS passenger_name
        FROM public.bookings b
        JOIN public.trips t ON t.id = b.trip_id
        JOIN public.profiles p ON p.id = b.booked_by_profile_id
        LEFT JOIN public.routes r ON r.id = t.route_id
        LEFT JOIN public.stages os ON os.id = r.origin_stage_id
        LEFT JOIN public.stages ds ON ds.id = r.destination_stage_id
        LEFT JOIN public.stages bs ON bs.id = t.boarding_stage_id
        LEFT JOIN public.stages als ON als.id = t.alighting_stage_id
        WHERE b.status = 'confirmed'
          AND t.status IN ('scheduled', 'active')
          AND t.departure_datetime > NOW()
          AND t.departure_datetime < NOW() + INTERVAL '48 hours'
          AND NOT EXISTS (
              SELECT 1 FROM public.notifications n 
              WHERE n.metadata->>'trip_id' = t.id::text      -- ← dedup by trip not booking
                AND n.profile_id = b.booked_by_profile_id   -- ← per user
                AND n.category = 'reminder'
                AND n.created_at > NOW() - INTERVAL '24 hours'
          )
        ORDER BY b.booked_by_profile_id, t.id, b.created_at DESC  -- latest booking wins
    LOOP
        INSERT INTO public.notifications (
            profile_id,
            tenant_id,
            title,
            message,
            category,
            target_type,
            metadata
        )
        VALUES (
            rec.booked_by_profile_id,
            rec.tenant_id,
            'Trip Reminder ⏰',
            'Dear ' || rec.passenger_name || ',' || E'\n\n' ||
            'Your booking for **' || COALESCE(rec.route_code, 'Your Route') || '** ' ||
            '(' || COALESCE(rec.origin, '?') || ' → ' || COALESCE(rec.destination, '?') || ') ' ||
            'is scheduled for **' || rec.departure_formatted || '**.' ||
            E'\n\nPlease arrive at the station at least 30 minutes early.' ||
            E'\n\nPassengers: ' || rec.total_passengers || 
            ' | Total: MWK ' || rec.total_fare::text,

            'reminder'::public.notification_category,
            'user',
            jsonb_build_object(
                'booking_id', rec.booking_id,
                'booking_token', rec.booking_token,
                'trip_id', rec.trip_id,
                'route_code', rec.route_code,
                'origin', rec.origin,
                'destination', rec.destination,
                'departure_datetime', rec.departure_formatted,
                'hours_left', rec.hours_left::int
            )
        );

    END LOOP;
END;
$$;


ALTER FUNCTION public.send_booking_reminder() OWNER TO postgres;

--
-- Name: send_booking_sms(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.send_booking_sms() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_message text;
  rec RECORD;
  v_edge_url text := 'https://aqjfskbmiycsebzegtys.supabase.co/functions/v1/send-sms';  -- ← CHANGE THIS
  v_anon_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFxamZza2JtaXljc2ViemVndHlzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzEzMjc4ODMsImV4cCI6MjA4NjkwMzg4M30.XvL91tb8vPROVxvGtdB4SJam-zzAs76g-rvHQ6OmbLo';  -- ← CHANGE TO YOUR SUPABASE ANON KEY (from Settings → API)
BEGIN
  -- Only for confirmed USSD bookings with completed payment
  IF NEW.status = 'confirmed' 
     AND NEW.booking_type = 'ussd'
     AND EXISTS (SELECT 1 FROM public.payments 
                 WHERE booking_id = NEW.id AND status = 'completed') 
  THEN
    FOR rec IN 
      SELECT 
        bp.id AS passenger_id,
        bp.name,
        bp.contact_phone,
        bp.ticket_number,
        r.route_code,
        t.departure_datetime,
        b.total_fare
      FROM public.booking_passengers bp
      JOIN public.bookings b ON b.id = bp.booking_id
      JOIN public.trips t ON t.id = b.trip_id
      JOIN public.routes r ON r.id = t.route_id
      WHERE bp.booking_id = NEW.id
    LOOP
      v_message := format(
        'Dear %s, Your USSD Ticket %s is CONFIRMED for %s on %s. Fare: MWK %s. Safe journey!',
        rec.name, 
        rec.ticket_number,
        rec.route_code,
        to_char(rec.departure_datetime, 'DD Mon HH24:MI'),
        rec.total_fare
      );

      -- FIXED http_post call (this is the most reliable version)
      PERFORM net.http_post(
        url := v_edge_url,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_anon_key
        ),
        body := jsonb_build_object(
          'phone', rec.contact_phone,
          'message', v_message,
          'booking_id', NEW.id,
          'passenger_id', rec.passenger_id
        )
      );

      -- Log the attempt (even if http_post fails)
      INSERT INTO public.sms_logs (
        tenant_id, booking_id, passenger_id, phone, message, status, response
      ) VALUES (
        NEW.tenant_id, 
        NEW.id, 
        rec.passenger_id, 
        rec.contact_phone, 
        v_message, 
        'sent',
        jsonb_build_object('note', 'http_post called from trigger')
      );
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.send_booking_sms() OWNER TO postgres;

--
-- Name: send_notification(text, text, public.notification_category, text, uuid, uuid, bigint, bigint, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.send_notification(p_title text, p_message text, p_category public.notification_category, p_target_type text, p_profile_id uuid DEFAULT NULL::uuid, p_tenant_id uuid DEFAULT NULL::uuid, p_trip_id bigint DEFAULT NULL::bigint, p_route_id bigint DEFAULT NULL::bigint, p_sent_by_profile_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_notification_id uuid;
BEGIN
    INSERT INTO public.notifications (
        title, message, category, target_type,
        profile_id, tenant_id, trip_id, route_id,
        sent_by_profile_id, metadata
    )
    VALUES (
        p_title, p_message, p_category, p_target_type,
        p_profile_id, p_tenant_id, p_trip_id, p_route_id,
        p_sent_by_profile_id, p_metadata
    )
    RETURNING id INTO v_notification_id;

    RETURN v_notification_id;
END;
$$;


ALTER FUNCTION public.send_notification(p_title text, p_message text, p_category public.notification_category, p_target_type text, p_profile_id uuid, p_tenant_id uuid, p_trip_id bigint, p_route_id bigint, p_sent_by_profile_id uuid, p_metadata jsonb) OWNER TO postgres;

--
-- Name: send_trip_delay_update(bigint, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.send_trip_delay_update(p_trip_id bigint, p_new_departure_time text, p_sent_by_profile_id uuid DEFAULT NULL::uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    PERFORM public.send_trip_update(
        p_trip_id := p_trip_id,
        p_title := 'Trip Delay Notice ⏳',
        p_message := 'Dear Passenger,' || E'\n\n' ||
                     'Your trip has been delayed.' || E'\n\n' ||
                     'New departure time: **' || p_new_departure_time || '**.' || E'\n\n' ||
                     'We apologize for any inconvenience caused.',
        p_sent_by_profile_id := p_sent_by_profile_id
    );
END;
$$;


ALTER FUNCTION public.send_trip_delay_update(p_trip_id bigint, p_new_departure_time text, p_sent_by_profile_id uuid) OWNER TO postgres;

--
-- Name: send_trip_update(bigint, text, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.send_trip_update(p_trip_id bigint, p_title text, p_message text, p_sent_by_profile_id uuid DEFAULT NULL::uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    INSERT INTO public.notifications (
        profile_id,
        tenant_id,
        title,
        message,
        category,
        target_type,
        metadata,
        sent_by_profile_id
    )
    SELECT 
        b.booked_by_profile_id,
        b.tenant_id,
        p_title,
        p_message,
        'system'::public.notification_category,
        'trip',
        jsonb_build_object(
            'trip_id', p_trip_id,
            'booking_id', b.id,
            'booking_token', b.booking_token,
            'is_trip_update', true,
            'update_type', 'general'
        ),
        p_sent_by_profile_id          -- This can be NULL
    FROM public.bookings b
    WHERE b.trip_id = p_trip_id 
      AND b.status = 'confirmed';

    RAISE NOTICE 'Trip update notifications sent successfully to passengers on trip_id: %', p_trip_id;
END;
$$;


ALTER FUNCTION public.send_trip_update(p_trip_id bigint, p_title text, p_message text, p_sent_by_profile_id uuid) OWNER TO postgres;

--
-- Name: test_send_reminder(uuid, bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.test_send_reminder(p_profile_id uuid, p_booking_id bigint DEFAULT NULL::bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    rec RECORD;
BEGIN
    SELECT 
        b.id AS booking_id,
        b.booked_by_profile_id,
        b.tenant_id,
        b.total_passengers,
        b.total_fare,
        b.booking_token,
        r.route_code,
        os.stage_name AS origin,
        ds.stage_name AS destination,
        t.departure_datetime,
        TO_CHAR(t.departure_datetime, 'DD Mon YYYY, HH24:MI') AS departure_formatted
    INTO rec
    FROM public.bookings b
    LEFT JOIN public.trips t ON t.id = b.trip_id
    LEFT JOIN public.routes r ON r.id = b.route_id
    LEFT JOIN public.stages os ON os.id = r.origin_stage_id
    LEFT JOIN public.stages ds ON ds.id = r.destination_stage_id
    WHERE b.booked_by_profile_id = p_profile_id
      AND (p_booking_id IS NULL OR b.id = p_booking_id)
    ORDER BY b.created_at DESC
    LIMIT 1;

    IF rec.booking_id IS NULL THEN
        RAISE EXCEPTION 'No booking found for profile_id %', p_profile_id;
    END IF;

    -- Insert Test Reminder Notification
    INSERT INTO public.notifications (
        profile_id,
        tenant_id,
        title,
        message,
        category,
        target_type,
        metadata
    )
    VALUES (
        rec.booked_by_profile_id,
        rec.tenant_id,
        'Trip Reminder ⏰',
        'Dear Passenger,' || E'\n\n' ||
        'This is a **TEST REMINDER** for demonstration purposes.' || E'\n\n' ||
        'Your booking for **' || COALESCE(rec.route_code, 'Your Route') || '** ' ||
        '(' || COALESCE(rec.origin, '?') || ' → ' || COALESCE(rec.destination, '?') || ') ' ||
        'is scheduled for **' || rec.departure_formatted || '**.' ||
        E'\n\nPlease be at the station 30 minutes early.',

        'reminder'::public.notification_category,
        'user',
        jsonb_build_object(
            'booking_id', rec.booking_id,
            'booking_token', rec.booking_token,
            'is_test', true,
            'note', 'This is a test reminder for stakeholder demo'
        )
    );

    RAISE NOTICE 'Test reminder sent successfully to profile_id: %', p_profile_id;
END;
$$;


ALTER FUNCTION public.test_send_reminder(p_profile_id uuid, p_booking_id bigint) OWNER TO postgres;

--
-- Name: trigger_set_timestamp(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trigger_set_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trigger_set_timestamp() OWNER TO postgres;

--
-- Name: update_user_role(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.update_user_role(target_user_id uuid, new_role text) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ads; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ads (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    img_url text,
    "tenantId" uuid,
    text_status text,
    metadata jsonb DEFAULT '{}'::jsonb
);


ALTER TABLE public.ads OWNER TO postgres;

--
-- Name: ads_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
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
-- Name: audit_log; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.audit_log OWNER TO postgres;

--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.audit_log_id_seq OWNER TO postgres;

--
-- Name: audit_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.audit_log_id_seq OWNED BY public.audit_log.id;


--
-- Name: audit_log_archive; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.audit_log_archive OWNER TO postgres;

--
-- Name: booking_passengers; Type: TABLE; Schema: public; Owner: postgres
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
    ticket_number text,
    is_return boolean DEFAULT false,
    return_date timestamp with time zone
);


ALTER TABLE public.booking_passengers OWNER TO postgres;

--
-- Name: booking_passengers_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.booking_passengers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.booking_passengers_id_seq OWNER TO postgres;

--
-- Name: booking_passengers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.booking_passengers_id_seq OWNED BY public.booking_passengers.id;


--
-- Name: booking_reschedules; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.booking_reschedules OWNER TO postgres;

--
-- Name: booking_reschedules_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.booking_reschedules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.booking_reschedules_id_seq OWNER TO postgres;

--
-- Name: booking_reschedules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.booking_reschedules_id_seq OWNED BY public.booking_reschedules.id;


--
-- Name: bookings; Type: TABLE; Schema: public; Owner: postgres
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
    booking_token uuid DEFAULT gen_random_uuid(),
    CONSTRAINT bookings_booking_type_check CHECK ((booking_type = ANY (ARRAY['online'::text, 'walkin'::text, 'ussd'::text]))),
    CONSTRAINT bookings_reschedule_count_check CHECK ((reschedule_count <= 1)),
    CONSTRAINT bookings_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'confirmed'::text, 'cancelled'::text]))),
    CONSTRAINT bookings_total_passengers_check CHECK ((total_passengers > 0)),
    CONSTRAINT bookings_trip_or_open_ticket_check CHECK ((((trip_id IS NOT NULL) AND (is_open_ticket = false)) OR ((trip_id IS NULL) AND (is_open_ticket = true) AND (route_id IS NOT NULL)))),
    CONSTRAINT bookings_trip_or_route_check CHECK (((trip_id IS NOT NULL) OR (route_id IS NOT NULL)))
);


ALTER TABLE public.bookings OWNER TO postgres;

--
-- Name: COLUMN bookings.trip_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.bookings.trip_id IS 'Trip ID - NULL for open tickets (date TBD), populated when trip is assigned';


--
-- Name: COLUMN bookings.route_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.bookings.route_id IS 'Required for open tickets (when trip_id is NULL). Indicates which route the ticket is valid for.';


--
-- Name: COLUMN bookings.is_open_ticket; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.bookings.is_open_ticket IS 'True if passenger has a floating ticket not yet assigned to a specific trip. trip_id will be NULL.';


--
-- Name: bookings_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.bookings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.bookings_id_seq OWNER TO postgres;

--
-- Name: bookings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.bookings_id_seq OWNED BY public.bookings.id;


--
-- Name: buses; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.buses OWNER TO postgres;

--
-- Name: COLUMN buses.amenities; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.buses.amenities IS 'List of amenities e.g. ["Wi-Fi", "AC", "USB Ports"]';


--
-- Name: buses_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.buses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.buses_id_seq OWNER TO postgres;

--
-- Name: buses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.buses_id_seq OWNED BY public.buses.id;


--
-- Name: migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.migrations (
    id integer NOT NULL,
    migration character varying(255) NOT NULL,
    batch integer NOT NULL
);


ALTER TABLE public.migrations OWNER TO postgres;

--
-- Name: migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.migrations_id_seq OWNER TO postgres;

--
-- Name: migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.migrations_id_seq OWNED BY public.migrations.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text NOT NULL,
    message text NOT NULL,
    category public.notification_category NOT NULL,
    is_read boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    tenant_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    profile_id uuid,
    target_type text,
    trip_id bigint,
    route_id bigint,
    sent_by_profile_id uuid,
    expires_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT notifications_target_type_check CHECK ((target_type = ANY (ARRAY['user'::text, 'tenant'::text, 'trip'::text, 'route'::text, 'all_passengers'::text, 'custom'::text])))
);


ALTER TABLE public.notifications OWNER TO postgres;

--
-- Name: payments; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.payments OWNER TO postgres;

--
-- Name: payments_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.payments_id_seq OWNER TO postgres;

--
-- Name: payments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.payments_id_seq OWNED BY public.payments.id;


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: postgres
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
    payment_pin_hash text,
    CONSTRAINT profiles_role_check CHECK ((role = ANY (ARRAY['passenger'::text, 'staff'::text, 'admin'::text, 'super_admin'::text])))
);


ALTER TABLE public.profiles OWNER TO postgres;

--
-- Name: refunds; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.refunds OWNER TO postgres;

--
-- Name: refunds_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.refunds_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.refunds_id_seq OWNER TO postgres;

--
-- Name: refunds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.refunds_id_seq OWNED BY public.refunds.id;


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.role_permissions (
    id bigint NOT NULL,
    role text NOT NULL,
    permissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.role_permissions OWNER TO postgres;

--
-- Name: role_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.role_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.role_permissions_id_seq OWNER TO postgres;

--
-- Name: role_permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.role_permissions_id_seq OWNED BY public.role_permissions.id;


--
-- Name: route_fares; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.route_fares (
    id bigint NOT NULL,
    tenant_id uuid,
    route_id bigint,
    boarding_stage_id bigint,
    alighting_stage_id bigint,
    fare_amount numeric NOT NULL,
    currency text DEFAULT 'MWK'::text,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.route_fares OWNER TO postgres;

--
-- Name: route_fares_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.route_fares ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.route_fares_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: routes; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.routes OWNER TO postgres;

--
-- Name: routes_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.routes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.routes_id_seq OWNER TO postgres;

--
-- Name: routes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.routes_id_seq OWNED BY public.routes.id;


--
-- Name: schedule_masters; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.schedule_masters OWNER TO postgres;

--
-- Name: schedule_masters_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.schedule_masters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.schedule_masters_id_seq OWNER TO postgres;

--
-- Name: schedule_masters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.schedule_masters_id_seq OWNED BY public.schedule_masters.id;


--
-- Name: seat_assignments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.seat_assignments (
    id bigint NOT NULL,
    trip_id bigint NOT NULL,
    booking_passenger_id bigint NOT NULL,
    seat_label text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    boarding_stage_id bigint,
    alighting_stage_id bigint,
    boarding_rank integer,
    alighting_rank integer
);

ALTER TABLE ONLY public.seat_assignments REPLICA IDENTITY FULL;


ALTER TABLE public.seat_assignments OWNER TO postgres;

--
-- Name: seat_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.seat_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.seat_assignments_id_seq OWNER TO postgres;

--
-- Name: seat_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.seat_assignments_id_seq OWNED BY public.seat_assignments.id;


--
-- Name: sms_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sms_logs (
    id bigint NOT NULL,
    tenant_id uuid,
    booking_id bigint,
    passenger_id bigint,
    phone text NOT NULL,
    message text NOT NULL,
    status text DEFAULT 'sent'::text,
    response jsonb,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT sms_logs_status_check CHECK ((status = ANY (ARRAY['sent'::text, 'delivered'::text, 'failed'::text])))
);


ALTER TABLE public.sms_logs OWNER TO postgres;

--
-- Name: sms_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.sms_logs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.sms_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: stages; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.stages OWNER TO postgres;

--
-- Name: TABLE stages; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.stages IS 'Bus stages/stops. Handles cases like Dedza using Lilongwe stage.';


--
-- Name: stages_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.stages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.stages_id_seq OWNER TO postgres;

--
-- Name: stages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.stages_id_seq OWNED BY public.stages.id;


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    contact text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    settings jsonb DEFAULT '{}'::jsonb,
    logo text
);


ALTER TABLE public.tenants OWNER TO postgres;

--
-- Name: COLUMN tenants.settings; Type: COMMENT; Schema: public; Owner: postgres
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
-- Name: trips; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.trips OWNER TO postgres;

--
-- Name: COLUMN trips.seat_conflict_warning; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.trips.seat_conflict_warning IS 'True if bus was swapped and new bus has different seat layout. Staff should review seat assignments.';


--
-- Name: COLUMN trips.original_bus_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.trips.original_bus_id IS 'Original bus assigned when trip was created. Preserved for audit trail when bus is swapped.';


--
-- Name: trips_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.trips_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.trips_id_seq OWNER TO postgres;

--
-- Name: trips_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.trips_id_seq OWNED BY public.trips.id;


--
-- Name: v_booking_notification; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_booking_notification AS
 SELECT b.id,
    b.booking_token,
    b.booked_by_profile_id,
    b.tenant_id,
    b.trip_id,
    b.route_id,
    b.total_fare,
    b.total_passengers,
    b.status,
    b.created_at,
    b.is_open_ticket,
    r.route_code,
    os.stage_name AS origin_stage,
    ds.stage_name AS destination_stage,
    t.departure_datetime,
    t.arrival_datetime,
    COALESCE(bu.registration_number, 'N/A'::text) AS bus_registration,
    concat(r.route_code, ' - ', os.stage_name, ' → ', ds.stage_name) AS full_route_name,
    to_char(t.departure_datetime, 'DD Mon, HH24:MI'::text) AS departure_time_formatted
   FROM (((((public.bookings b
     LEFT JOIN public.routes r ON ((r.id = b.route_id)))
     LEFT JOIN public.trips t ON ((t.id = b.trip_id)))
     LEFT JOIN public.stages os ON ((os.id = r.origin_stage_id)))
     LEFT JOIN public.stages ds ON ((ds.id = r.destination_stage_id)))
     LEFT JOIN public.buses bu ON ((bu.id = t.bus_id)))
  WHERE (b.status = ANY (ARRAY['confirmed'::text, 'pending'::text, 'cancelled'::text]));


ALTER VIEW public.v_booking_notification OWNER TO postgres;

--
-- Name: v_daily_sales_report; Type: VIEW; Schema: public; Owner: postgres
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


ALTER VIEW public.v_daily_sales_report OWNER TO postgres;

--
-- Name: v_passenger_manifest; Type: VIEW; Schema: public; Owner: postgres
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


ALTER VIEW public.v_passenger_manifest OWNER TO postgres;

--
-- Name: VIEW v_passenger_manifest; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON VIEW public.v_passenger_manifest IS 'Passenger list for check-in with boarding/alighting stages';


--
-- Name: audit_log id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log ALTER COLUMN id SET DEFAULT nextval('public.audit_log_id_seq'::regclass);


--
-- Name: booking_passengers id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_passengers ALTER COLUMN id SET DEFAULT nextval('public.booking_passengers_id_seq'::regclass);


--
-- Name: booking_reschedules id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_reschedules ALTER COLUMN id SET DEFAULT nextval('public.booking_reschedules_id_seq'::regclass);


--
-- Name: bookings id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bookings ALTER COLUMN id SET DEFAULT nextval('public.bookings_id_seq'::regclass);


--
-- Name: buses id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.buses ALTER COLUMN id SET DEFAULT nextval('public.buses_id_seq'::regclass);


--
-- Name: migrations id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.migrations ALTER COLUMN id SET DEFAULT nextval('public.migrations_id_seq'::regclass);


--
-- Name: payments id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments ALTER COLUMN id SET DEFAULT nextval('public.payments_id_seq'::regclass);


--
-- Name: refunds id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds ALTER COLUMN id SET DEFAULT nextval('public.refunds_id_seq'::regclass);


--
-- Name: role_permissions id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permissions ALTER COLUMN id SET DEFAULT nextval('public.role_permissions_id_seq'::regclass);


--
-- Name: routes id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routes ALTER COLUMN id SET DEFAULT nextval('public.routes_id_seq'::regclass);


--
-- Name: schedule_masters id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schedule_masters ALTER COLUMN id SET DEFAULT nextval('public.schedule_masters_id_seq'::regclass);


--
-- Name: seat_assignments id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.seat_assignments ALTER COLUMN id SET DEFAULT nextval('public.seat_assignments_id_seq'::regclass);


--
-- Name: stages id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stages ALTER COLUMN id SET DEFAULT nextval('public.stages_id_seq'::regclass);


--
-- Name: trips id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips ALTER COLUMN id SET DEFAULT nextval('public.trips_id_seq'::regclass);


--
-- Data for Name: ads; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ads (id, created_at, img_url, "tenantId", text_status, metadata) FROM stdin;
1	2026-04-23 20:54:45.547535+02	https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/advertisation-banner/ad-banners/0.49668469739160614.jpg	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Travel with us	{}
4	2026-04-26 10:49:47.046113+02	https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/advertisation-banner/ad-banners/0.3079735994963356.jpg	665a127e-0619-4505-9538-34df0b6d5f7a	New Bus in town	{}
6	2026-04-26 11:23:07.150689+02	https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/advertisation-banner/ad-banners/0.64372001550897.jpg	544618e1-b774-4eb4-abf9-c3cb2d99265f	Safer and Reliable	{}
\.


--
-- Data for Name: audit_log; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.audit_log (id, tenant_id, actor_id, action, target_type, target_id, old_value, new_value, changes, created_at) FROM stdin;
1	\N	\N	insert_profiles	profiles	dfd092e2-457f-4887-a196-1c55c2627cda	\N	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "passenger", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": null, "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-23T18:38:29.208447+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	\N	2026-04-23 20:38:29.208447+02
2	\N	\N	update_profiles	profiles	dfd092e2-457f-4887-a196-1c55c2627cda	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "passenger", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": null, "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-23T18:38:29.208447+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "super_admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": null, "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-23T18:44:56.254156+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	Changed: role	2026-04-23 20:44:56.254156+02
3	\N	\N	profile_role_change	profile	dfd092e2-457f-4887-a196-1c55c2627cda	{"role": "passenger"}	{"role": "super_admin"}	Role changed from passenger to super_admin	2026-04-23 20:44:56.254156+02
4	\N	\N	insert_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-23T18:46:31.162243+00:00"}	\N	2026-04-23 20:46:31.162243+02
5	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	insert_profiles	profiles	47bb28e7-6c61-4564-ab23-ca14e9971210	\N	{"id": "47bb28e7-6c61-4564-ab23-ca14e9971210", "role": "passenger", "email": "mwambakulubenjamin2o5@gmail.com", "phone": null, "full_name": "Vamp2o5 Machawi", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:46:31.247198+00:00", "updated_at": "2026-04-23T18:46:31.247198+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "33b4bcc0-dcfe-4da2-852d-54bfb4897e01", "payment_pin_hash": null}	\N	2026-04-23 20:46:31.247198+02
6	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_profiles	profiles	47bb28e7-6c61-4564-ab23-ca14e9971210	{"id": "47bb28e7-6c61-4564-ab23-ca14e9971210", "role": "passenger", "email": "mwambakulubenjamin2o5@gmail.com", "phone": null, "full_name": "Vamp2o5 Machawi", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:46:31.247198+00:00", "updated_at": "2026-04-23T18:46:31.247198+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "33b4bcc0-dcfe-4da2-852d-54bfb4897e01", "payment_pin_hash": null}	{"id": "47bb28e7-6c61-4564-ab23-ca14e9971210", "role": "admin", "email": "mwambakulubenjamin2o5@gmail.com", "phone": null, "full_name": "Vamp2o5 Machawi", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:46:31.247198+00:00", "updated_at": "2026-04-23T18:46:31.862636+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "33b4bcc0-dcfe-4da2-852d-54bfb4897e01", "payment_pin_hash": null}	Changed: role	2026-04-23 20:46:31.862636+02
7	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	profile_role_change	profile	47bb28e7-6c61-4564-ab23-ca14e9971210	{"role": "passenger"}	{"role": "admin"}	Role changed from passenger to admin	2026-04-23 20:46:31.862636+02
8	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-23T18:46:31.162243+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "logo_storage_path": "new-provider/logo-1776969977318.jpg"}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-23T18:46:32.355435+00:00"}	Changed: settings	2026-04-23 20:46:32.355435+02
9	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_buses	buses	1	\N	{"id": 1, "capacity": 72, "seat_map": {"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}, "16A": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 1}, "16B": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 2}, "16C": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 3}, "16D": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 4}, "17A": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 1}, "17B": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 2}, "17C": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 3}, "17D": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 4}, "18A": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 1}, "18B": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 2}, "18C": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 3}, "18D": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D", "16A", "16B", "16C", "16D", "17A", "17B", "17C", "17D", "18A", "18B", "18C", "18D"], "column_layout": "2,2"}, "amenities": ["Wi-Fi", "AC"], "is_active": true, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:47:46.696976+00:00", "updated_at": "2026-04-23T18:47:46.696976+00:00", "registration_number": "BLK 6929"}	\N	2026-04-23 20:47:46.696976+02
10	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_stages	stages	1	\N	{"id": 1, "location": "Ntcheu", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:48:15.74275+00:00", "stage_name": "Ntcheu Depot", "updated_at": "2026-04-23T18:48:15.74275+00:00", "coordinates": null, "is_major_stage": false}	\N	2026-04-23 20:48:15.74275+02
11	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_stages	stages	2	\N	{"id": 2, "location": "Lilongwe", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:48:41.432767+00:00", "stage_name": "Grand Business Park", "updated_at": "2026-04-23T18:48:41.432767+00:00", "coordinates": null, "is_major_stage": true}	\N	2026-04-23 20:48:41.432767+02
12	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_stages	stages	3	\N	{"id": 3, "location": "Blantyre", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:49:06.597609+00:00", "stage_name": "Chichiri City Mall", "updated_at": "2026-04-23T18:49:06.597609+00:00", "coordinates": null, "is_major_stage": true}	\N	2026-04-23 20:49:06.597609+02
13	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_routes	routes	1	\N	{"id": 1, "base_fare": 85000.00, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:49:33.314348+00:00", "route_code": "Blantyre - Lilongwe", "updated_at": "2026-04-23T18:49:33.314348+00:00", "origin_stage_id": 3, "intermediate_stops": [{"order": 1, "location": "Ntcheu", "stage_id": 1, "stage_name": "Ntcheu Depot"}], "destination_stage_id": 2}	\N	2026-04-23 20:49:33.314348+02
107	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	4	\N	{"id": 4, "trip_id": 2, "created_at": "2026-04-24T08:58:13.903712+00:00", "seat_label": "3B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 4}	\N	2026-04-24 10:58:13.903712+02
14	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_schedule_masters	schedule_masters	1	\N	{"id": 1, "bus_id": 1, "route_id": 1, "frequency": "daily", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:04.986446+00:00", "updated_at": "2026-04-23T18:51:04.986446+00:00", "window_size": 30, "arrival_time": "17:30:00", "days_of_week": [0, 1, 2, 3, 4, 5, 6], "departure_time": "13:30:00", "auto_extend_enabled": true, "last_generated_date": "2026-05-22"}	\N	2026-04-23 20:51:04.986446+02
15	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	1	\N	{"id": 1, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-23T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-23T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
16	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	2	\N	{"id": 2, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-24T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-24T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
17	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	3	\N	{"id": 3, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-25T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-25T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
18	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	4	\N	{"id": 4, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-26T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
19	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	5	\N	{"id": 5, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-27T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
20	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	6	\N	{"id": 6, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-28T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
21	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	7	\N	{"id": 7, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-29T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
22	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	8	\N	{"id": 8, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-30T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
23	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	9	\N	{"id": 9, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-01T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-01T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
24	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	10	\N	{"id": 10, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-02T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-02T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
25	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	11	\N	{"id": 11, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-03T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-03T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
108	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	4	\N	{"id": 4, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-24T10:58:13.303666+00:00", "booking_id": 4, "created_at": "2026-04-24T08:58:14.514303+00:00", "payment_method": "mobile_money", "transaction_reference": "a87ff167-75c5-42cf-9a45-9fe49378fae1"}	\N	2026-04-24 10:58:14.514303+02
773	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	157	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
26	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	12	\N	{"id": 12, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-04T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-04T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
27	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	13	\N	{"id": 13, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-05T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-05T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
28	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	14	\N	{"id": 14, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-06T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-06T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
29	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	15	\N	{"id": 15, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-07T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-07T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
30	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	16	\N	{"id": 16, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-08T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-08T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
31	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	17	\N	{"id": 17, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-09T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-09T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
32	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	18	\N	{"id": 18, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-10T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-10T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
33	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	19	\N	{"id": 19, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-11T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-11T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
34	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	20	\N	{"id": 20, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-12T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-12T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
35	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	21	\N	{"id": 21, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-13T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-13T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
36	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	22	\N	{"id": 22, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-14T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-14T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
37	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	23	\N	{"id": 23, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-15T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-15T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
38	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	24	\N	{"id": 24, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-16T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-16T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
39	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	25	\N	{"id": 25, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-17T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-17T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
40	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	26	\N	{"id": 26, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-18T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-18T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
41	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	27	\N	{"id": 27, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-19T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-19T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
42	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	28	\N	{"id": 28, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-20T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-20T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
43	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	29	\N	{"id": 29, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-21T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-21T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
44	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	30	\N	{"id": 30, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-05-22T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-05-22T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	\N	2026-04-23 20:51:05.42981+02
45	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_buses	buses	2	\N	{"id": 2, "capacity": 60, "seat_map": {"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D"], "column_layout": "2,2"}, "amenities": ["Snack Service"], "is_active": true, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:53:56.490233+00:00", "updated_at": "2026-04-23T18:53:56.490233+00:00", "registration_number": "MK 89806"}	\N	2026-04-23 20:53:56.490233+02
46	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_routes	routes	2	\N	{"id": 2, "base_fare": 85000.00, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:55:52.705378+00:00", "route_code": "Lilongwe - Blantyre", "updated_at": "2026-04-23T18:55:52.705378+00:00", "origin_stage_id": 2, "intermediate_stops": [{"order": 1, "location": "Ntcheu", "stage_id": 1, "stage_name": "Ntcheu Depot"}], "destination_stage_id": 3}	\N	2026-04-23 20:55:52.705378+02
47	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_stages	stages	4	\N	{"id": 4, "location": "Mzimba", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:57:11.449629+00:00", "stage_name": "Mzuzu Terminal", "updated_at": "2026-04-23T18:57:11.449629+00:00", "coordinates": null, "is_major_stage": true}	\N	2026-04-23 20:57:11.449629+02
48	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_stages	stages	5	\N	{"id": 5, "location": "Kasungu", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:57:40.336187+00:00", "stage_name": "Kasungu Stage", "updated_at": "2026-04-23T18:57:40.336187+00:00", "coordinates": null, "is_major_stage": false}	\N	2026-04-23 20:57:40.336187+02
49	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_routes	routes	3	\N	{"id": 3, "base_fare": 150000.00, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:58:38.180751+00:00", "route_code": "Mzimba - Blantyre", "updated_at": "2026-04-23T18:58:38.180751+00:00", "origin_stage_id": 4, "intermediate_stops": [{"order": 1, "location": "Kasungu", "stage_id": 5, "stage_name": "Kasungu Stage"}, {"order": 2, "location": "Lilongwe", "stage_id": 2, "stage_name": "Grand Business Park"}, {"order": 3, "location": "Ntcheu", "stage_id": 1, "stage_name": "Ntcheu Depot"}], "destination_stage_id": 3}	\N	2026-04-23 20:58:38.180751+02
62	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	41	\N	{"id": 41, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-03T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-03T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
170	\N	\N	delete_payments	payments	7	{"id": 7, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-24T11:26:46.694031+00:00", "booking_id": 7, "created_at": "2026-04-24T09:26:47.95239+00:00", "payment_method": "mobile_money", "transaction_reference": "43169a4e-fa2d-4f94-8f2f-0fef91e85b97"}	\N	\N	2026-04-24 11:59:20.281174+02
50	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	update_profiles	profiles	47bb28e7-6c61-4564-ab23-ca14e9971210	{"id": "47bb28e7-6c61-4564-ab23-ca14e9971210", "role": "admin", "email": "mwambakulubenjamin2o5@gmail.com", "phone": null, "full_name": "Vamp2o5 Machawi", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:46:31.247198+00:00", "updated_at": "2026-04-23T18:46:31.862636+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "33b4bcc0-dcfe-4da2-852d-54bfb4897e01", "payment_pin_hash": null}	{"id": "47bb28e7-6c61-4564-ab23-ca14e9971210", "role": "admin", "email": "mwambakulubenjamin2o5@gmail.com", "phone": null, "full_name": "Vamp2o5 Machawi", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:46:31.247198+00:00", "updated_at": "2026-04-23T19:00:19.851857+00:00", "national_id": null, "profile_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/profile-photos/profiles/profile-47bb28e7-6c61-4564-ab23-ca14e9971210-1776970815221.jpg", "supa_auth_id": "33b4bcc0-dcfe-4da2-852d-54bfb4897e01", "payment_pin_hash": null}	Changed: profile_url	2026-04-23 21:00:19.851857+02
51	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_schedule_masters	schedule_masters	2	\N	{"id": 2, "bus_id": 2, "route_id": 2, "frequency": "daily", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:07.798603+00:00", "updated_at": "2026-04-23T19:02:07.798603+00:00", "window_size": 30, "arrival_time": "13:30:00", "days_of_week": [0, 1, 2, 3, 4, 5, 6], "departure_time": "07:30:00", "auto_extend_enabled": true, "last_generated_date": "2026-05-22"}	\N	2026-04-23 21:02:07.798603+02
52	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	31	\N	{"id": 31, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-23T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-23T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
53	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	32	\N	{"id": 32, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-24T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-24T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
54	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	33	\N	{"id": 33, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-25T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-25T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
55	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	34	\N	{"id": 34, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
56	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	35	\N	{"id": 35, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
57	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	36	\N	{"id": 36, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
58	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	37	\N	{"id": 37, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
59	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	38	\N	{"id": 38, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
60	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	39	\N	{"id": 39, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-01T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-01T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
61	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	40	\N	{"id": 40, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-02T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-02T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
63	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	42	\N	{"id": 42, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-04T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-04T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
64	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	43	\N	{"id": 43, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-05T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-05T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
65	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	44	\N	{"id": 44, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-06T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-06T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
66	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	45	\N	{"id": 45, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-07T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-07T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
67	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	46	\N	{"id": 46, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-08T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-08T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
68	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	47	\N	{"id": 47, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-09T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-09T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
69	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	48	\N	{"id": 48, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-10T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-10T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
70	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	49	\N	{"id": 49, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-11T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-11T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
71	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	50	\N	{"id": 50, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-12T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-12T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
72	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	51	\N	{"id": 51, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-13T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-13T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
73	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	52	\N	{"id": 52, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-14T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-14T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
74	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	53	\N	{"id": 53, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-15T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-15T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
75	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	54	\N	{"id": 54, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-16T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-16T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
76	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	55	\N	{"id": 55, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-17T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-17T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
77	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	56	\N	{"id": 56, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-18T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-18T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
78	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	57	\N	{"id": 57, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-19T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-19T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
79	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	58	\N	{"id": 58, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-20T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-20T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
80	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	59	\N	{"id": 59, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-21T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-21T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
81	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	insert_trips	trips	60	\N	{"id": 60, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-05-22T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-05-22T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	\N	2026-04-23 21:02:08.117478+02
82	\N	\N	insert_profiles	profiles	043233e0-e1ad-43df-9313-e3faca433214	\N	{"id": "043233e0-e1ad-43df-9313-e3faca433214", "role": "passenger", "email": "gondwetamara557@gmail.com", "phone": null, "full_name": "Tamara Gondwe", "tenant_id": null, "created_at": "2026-04-23T19:16:20.867766+00:00", "updated_at": "2026-04-23T19:16:20.867766+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "36a82f88-2eb2-4852-8aa5-7142f4062d00", "payment_pin_hash": null}	\N	2026-04-23 21:16:20.867766+02
83	\N	\N	update_profiles	profiles	043233e0-e1ad-43df-9313-e3faca433214	{"id": "043233e0-e1ad-43df-9313-e3faca433214", "role": "passenger", "email": "gondwetamara557@gmail.com", "phone": null, "full_name": "Tamara Gondwe", "tenant_id": null, "created_at": "2026-04-23T19:16:20.867766+00:00", "updated_at": "2026-04-23T19:16:20.867766+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "36a82f88-2eb2-4852-8aa5-7142f4062d00", "payment_pin_hash": null}	{"id": "043233e0-e1ad-43df-9313-e3faca433214", "role": "admin", "email": "gondwetamara557@gmail.com", "phone": null, "full_name": "Tamara Gondwe", "tenant_id": null, "created_at": "2026-04-23T19:16:20.867766+00:00", "updated_at": "2026-04-23T19:16:50.345602+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "36a82f88-2eb2-4852-8aa5-7142f4062d00", "payment_pin_hash": null}	Changed: role	2026-04-23 21:16:50.345602+02
84	\N	\N	profile_role_change	profile	043233e0-e1ad-43df-9313-e3faca433214	{"role": "passenger"}	{"role": "admin"}	Role changed from passenger to admin	2026-04-23 21:16:50.345602+02
85	\N	\N	insert_tenants	tenants	59404003-a715-4e9f-82b1-671a8e2b0b12	\N	{"id": "59404003-a715-4e9f-82b1-671a8e2b0b12", "logo": null, "name": "Sososo", "contact": "0885705304", "settings": {}, "is_active": true, "created_at": "2026-04-23T19:18:20.630438+00:00", "updated_at": "2026-04-23T19:18:20.630438+00:00"}	\N	2026-04-23 21:18:20.630438+02
86	\N	\N	delete_tenants	tenants	59404003-a715-4e9f-82b1-671a8e2b0b12	{"id": "59404003-a715-4e9f-82b1-671a8e2b0b12", "logo": null, "name": "Sososo", "contact": "0885705304", "settings": {}, "is_active": true, "created_at": "2026-04-23T19:18:20.630438+00:00", "updated_at": "2026-04-23T19:18:20.630438+00:00"}	\N	\N	2026-04-23 21:18:20.816162+02
87	\N	\N	delete_profiles	profiles	043233e0-e1ad-43df-9313-e3faca433214	{"id": "043233e0-e1ad-43df-9313-e3faca433214", "role": "admin", "email": "gondwetamara557@gmail.com", "phone": null, "full_name": "Tamara Gondwe", "tenant_id": null, "created_at": "2026-04-23T19:16:20.867766+00:00", "updated_at": "2026-04-23T19:16:50.345602+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "36a82f88-2eb2-4852-8aa5-7142f4062d00", "payment_pin_hash": null}	\N	\N	2026-04-23 21:18:50.80237+02
88	\N	\N	insert_tenants	tenants	3dce9d0c-181d-4a54-911c-471959d7065d	\N	{"id": "3dce9d0c-181d-4a54-911c-471959d7065d", "logo": null, "name": "Sososo", "contact": "0885705304", "settings": {}, "is_active": true, "created_at": "2026-04-23T19:19:22.856095+00:00", "updated_at": "2026-04-23T19:19:22.856095+00:00"}	\N	2026-04-23 21:19:22.856095+02
89	3dce9d0c-181d-4a54-911c-471959d7065d	\N	insert_profiles	profiles	8231bfd4-c74e-4c83-b231-69a74e5d6f29	\N	{"id": "8231bfd4-c74e-4c83-b231-69a74e5d6f29", "role": "passenger", "email": "gondwetamara557@gmail.com", "phone": null, "full_name": "Tamara", "tenant_id": "3dce9d0c-181d-4a54-911c-471959d7065d", "created_at": "2026-04-23T19:19:22.989139+00:00", "updated_at": "2026-04-23T19:19:22.989139+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "0fff0cfa-219c-4a6f-8669-489daa2183e2", "payment_pin_hash": null}	\N	2026-04-23 21:19:22.989139+02
106	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	4	\N	{"id": 4, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 4, "created_at": "2026-04-24T08:58:12.917253+00:00", "national_id": null, "return_date": null, "ticket_token": "e3c6f0ad-115a-400f-9bc0-f5cbbfb4837a", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-A3EC0357", "linked_profile_id": null}	\N	2026-04-24 10:58:12.917253+02
90	3dce9d0c-181d-4a54-911c-471959d7065d	\N	update_profiles	profiles	8231bfd4-c74e-4c83-b231-69a74e5d6f29	{"id": "8231bfd4-c74e-4c83-b231-69a74e5d6f29", "role": "passenger", "email": "gondwetamara557@gmail.com", "phone": null, "full_name": "Tamara", "tenant_id": "3dce9d0c-181d-4a54-911c-471959d7065d", "created_at": "2026-04-23T19:19:22.989139+00:00", "updated_at": "2026-04-23T19:19:22.989139+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "0fff0cfa-219c-4a6f-8669-489daa2183e2", "payment_pin_hash": null}	{"id": "8231bfd4-c74e-4c83-b231-69a74e5d6f29", "role": "admin", "email": "gondwetamara557@gmail.com", "phone": null, "full_name": "Tamara", "tenant_id": "3dce9d0c-181d-4a54-911c-471959d7065d", "created_at": "2026-04-23T19:19:22.989139+00:00", "updated_at": "2026-04-23T19:19:23.494966+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "0fff0cfa-219c-4a6f-8669-489daa2183e2", "payment_pin_hash": null}	Changed: role	2026-04-23 21:19:23.494966+02
91	3dce9d0c-181d-4a54-911c-471959d7065d	\N	profile_role_change	profile	8231bfd4-c74e-4c83-b231-69a74e5d6f29	{"role": "passenger"}	{"role": "admin"}	Role changed from passenger to admin	2026-04-23 21:19:23.494966+02
92	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	1	\N	{"id": 1, "status": "confirmed", "trip_id": 36, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:26:36.363365+00:00", "expires_at": "2026-05-23T19:26:36.363365+00:00", "total_fare": 850500.00, "updated_at": "2026-04-23T19:26:36.363365+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-23 21:26:36.363365+02
93	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	1	\N	{"id": 1, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 1, "created_at": "2026-04-23T19:26:36.77212+00:00", "national_id": null, "return_date": null, "ticket_token": "21a8b86d-b028-48c3-b171-611d0841492e", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-6C75EBD5", "linked_profile_id": null}	\N	2026-04-23 21:26:36.77212+02
94	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	1	\N	{"id": 1, "trip_id": 36, "created_at": "2026-04-23T19:26:37.185692+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 1}	\N	2026-04-23 21:26:37.185692+02
95	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	1	\N	{"id": 1, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-23T21:26:36.35978+00:00", "booking_id": 1, "created_at": "2026-04-23T19:26:37.550232+00:00", "payment_method": "mobile_money", "transaction_reference": "c78b4ced-204a-4033-8987-27bfe9653309"}	\N	2026-04-23 21:26:37.550232+02
96	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	2	\N	{"id": 2, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T20:38:44.144067+00:00", "expires_at": "2026-05-23T20:38:44.144067+00:00", "total_fare": 850500.00, "updated_at": "2026-04-23T20:38:44.144067+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-23 22:38:44.144067+02
97	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	2	\N	{"id": 2, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 2, "created_at": "2026-04-23T20:38:44.685055+00:00", "national_id": null, "return_date": null, "ticket_token": "fa48a6ef-01ca-4277-84c4-dcddd25c0106", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-A9A5ED44", "linked_profile_id": null}	\N	2026-04-23 22:38:44.685055+02
98	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	2	\N	{"id": 2, "trip_id": 2, "created_at": "2026-04-23T20:38:45.088908+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 2}	\N	2026-04-23 22:38:45.088908+02
99	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	2	\N	{"id": 2, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-23T22:38:44.254837+00:00", "booking_id": 2, "created_at": "2026-04-23T20:38:45.4759+00:00", "payment_method": "mobile_money", "transaction_reference": "6a84ac6b-eff0-49c8-af6e-6f34f721a4b2"}	\N	2026-04-23 22:38:45.4759+02
100	\N	\N	insert_profiles	profiles	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	\N	{"id": "a3d20b4f-07ff-474d-81ca-a7b7f884fa76", "role": "passenger", "email": "lamecknsomba1@gmail.com", "phone": null, "full_name": "lameck nsomba", "tenant_id": null, "created_at": "2026-04-24T06:26:24.288361+00:00", "updated_at": "2026-04-24T06:26:24.288361+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "33c5c85d-9ad1-40b8-a35c-c8792cb5bc2d", "payment_pin_hash": null}	\N	2026-04-24 08:26:24.288361+02
101	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	3	\N	{"id": 3, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T07:12:07.270913+00:00", "expires_at": "2026-05-24T07:12:07.270913+00:00", "total_fare": 850500.00, "updated_at": "2026-04-24T07:12:07.270913+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 09:12:07.270913+02
102	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	3	\N	{"id": 3, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 3, "created_at": "2026-04-24T07:12:07.969745+00:00", "national_id": null, "return_date": null, "ticket_token": "8f7f25b6-669e-45e7-8274-f6b63df673ff", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-338B39AD", "linked_profile_id": null}	\N	2026-04-24 09:12:07.969745+02
103	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	3	\N	{"id": 3, "trip_id": 2, "created_at": "2026-04-24T07:12:08.482716+00:00", "seat_label": "2B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 3}	\N	2026-04-24 09:12:08.482716+02
104	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	3	\N	{"id": 3, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-24T09:12:08.893039+00:00", "booking_id": 3, "created_at": "2026-04-24T07:12:10.200408+00:00", "payment_method": "mobile_money", "transaction_reference": "7caf8811-c3bb-41c1-a5f4-1b504944f144"}	\N	2026-04-24 09:12:10.200408+02
105	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	4	\N	{"id": 4, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T08:58:12.115468+00:00", "expires_at": "2026-05-24T08:58:12.115468+00:00", "total_fare": 850500.00, "updated_at": "2026-04-24T08:58:12.115468+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 10:58:12.115468+02
109	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	5	\N	{"id": 5, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:05:25.617664+00:00", "expires_at": "2026-05-24T09:05:25.617664+00:00", "total_fare": 850500.00, "updated_at": "2026-04-24T09:05:25.617664+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 11:05:25.617664+02
110	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	5	\N	{"id": 5, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 5, "created_at": "2026-04-24T09:05:26.107257+00:00", "national_id": null, "return_date": null, "ticket_token": "52f3f2fa-e7da-4876-bc1f-c580a3011278", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-147DDCC8", "linked_profile_id": null}	\N	2026-04-24 11:05:26.107257+02
111	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	5	\N	{"id": 5, "trip_id": 2, "created_at": "2026-04-24T09:05:26.513368+00:00", "seat_label": "5B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 5}	\N	2026-04-24 11:05:26.513368+02
112	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	5	\N	{"id": 5, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-24T11:05:25.742587+00:00", "booking_id": 5, "created_at": "2026-04-24T09:05:26.950997+00:00", "payment_method": "mobile_money", "transaction_reference": "0aadced5-2bd7-491a-8b83-a9dcab60d412"}	\N	2026-04-24 11:05:26.950997+02
113	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	6	\N	{"id": 6, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:15:48.928016+00:00", "expires_at": "2026-05-24T09:15:48.928016+00:00", "total_fare": 850500.00, "updated_at": "2026-04-24T09:15:48.928016+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 11:15:48.928016+02
114	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	6	\N	{"id": 6, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 6, "created_at": "2026-04-24T09:15:49.658537+00:00", "national_id": null, "return_date": null, "ticket_token": "dccff3e0-6ad9-464d-a90b-c2b61f568a39", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-3F5634A4", "linked_profile_id": null}	\N	2026-04-24 11:15:49.658537+02
115	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	6	\N	{"id": 6, "trip_id": 2, "created_at": "2026-04-24T09:15:50.077004+00:00", "seat_label": "2A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 6}	\N	2026-04-24 11:15:50.077004+02
116	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	6	\N	{"id": 6, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-24T11:15:49.26841+00:00", "booking_id": 6, "created_at": "2026-04-24T09:15:50.44088+00:00", "payment_method": "mobile_money", "transaction_reference": "3f7200cb-7112-442d-8890-e617ab587a23"}	\N	2026-04-24 11:15:50.44088+02
117	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	7	\N	{"id": 7, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:26:46.459842+00:00", "expires_at": "2026-05-24T09:26:46.459842+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T09:26:46.459842+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 11:26:46.459842+02
118	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	7	\N	{"id": 7, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 7, "created_at": "2026-04-24T09:26:47.050506+00:00", "national_id": null, "return_date": null, "ticket_token": "8936a9c6-dcf5-48d8-ba55-699124271bbd", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-D5DD2D2D", "linked_profile_id": null}	\N	2026-04-24 11:26:47.050506+02
119	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	7	\N	{"id": 7, "trip_id": 2, "created_at": "2026-04-24T09:26:47.45482+00:00", "seat_label": "2C", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 7}	\N	2026-04-24 11:26:47.45482+02
120	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	7	\N	{"id": 7, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-24T11:26:46.694031+00:00", "booking_id": 7, "created_at": "2026-04-24T09:26:47.95239+00:00", "payment_method": "mobile_money", "transaction_reference": "43169a4e-fa2d-4f94-8f2f-0fef91e85b97"}	\N	2026-04-24 11:26:47.95239+02
121	3dce9d0c-181d-4a54-911c-471959d7065d	\N	update_profiles	profiles	dfd092e2-457f-4887-a196-1c55c2627cda	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "super_admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": null, "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-23T18:44:56.254156+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "super_admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": "3dce9d0c-181d-4a54-911c-471959d7065d", "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-24T09:35:20.654853+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	Changed: tenant_id	2026-04-24 11:35:20.654853+02
122	3dce9d0c-181d-4a54-911c-471959d7065d	\N	update_profiles	profiles	dfd092e2-457f-4887-a196-1c55c2627cda	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "super_admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": "3dce9d0c-181d-4a54-911c-471959d7065d", "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-24T09:35:20.654853+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": "3dce9d0c-181d-4a54-911c-471959d7065d", "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-24T09:35:29.611056+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	Changed: role	2026-04-24 11:35:29.611056+02
123	3dce9d0c-181d-4a54-911c-471959d7065d	\N	profile_role_change	profile	dfd092e2-457f-4887-a196-1c55c2627cda	{"role": "super_admin"}	{"role": "admin"}	Role changed from super_admin to admin	2026-04-24 11:35:29.611056+02
774	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	187	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
124	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_profiles	profiles	dfd092e2-457f-4887-a196-1c55c2627cda	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": "3dce9d0c-181d-4a54-911c-471959d7065d", "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-24T09:35:29.611056+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-24T09:36:28.122316+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	Changed: tenant_id	2026-04-24 11:36:28.122316+02
125	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_bookings	bookings	8	\N	{"id": 8, "status": "confirmed", "trip_id": 33, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:52:55.495813+00:00", "expires_at": "2026-05-24T09:52:55.495813+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T09:52:55.495813+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "a3d20b4f-07ff-474d-81ca-a7b7f884fa76"}	\N	2026-04-24 11:52:55.495813+02
126	\N	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_booking_passengers	booking_passengers	8	\N	{"id": 8, "name": "lameck nsomba", "is_child": false, "is_return": false, "booking_id": 8, "created_at": "2026-04-24T09:52:56.254358+00:00", "national_id": null, "return_date": null, "ticket_token": "a34d7b76-bdc4-4e9c-ad4f-69daea76e6d0", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-32539241", "linked_profile_id": null}	\N	2026-04-24 11:52:56.254358+02
127	\N	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_seat_assignments	seat_assignments	8	\N	{"id": 8, "trip_id": 33, "created_at": "2026-04-24T09:52:56.831059+00:00", "seat_label": "1C", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 8}	\N	2026-04-24 11:52:56.831059+02
128	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_bookings	bookings	9	\N	{"id": 9, "status": "confirmed", "trip_id": 33, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:52:57.0058+00:00", "expires_at": "2026-05-24T09:52:57.0058+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T09:52:57.0058+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "a3d20b4f-07ff-474d-81ca-a7b7f884fa76"}	\N	2026-04-24 11:52:57.0058+02
129	\N	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_payments	payments	8	\N	{"id": 8, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-24T11:52:57.657801+00:00", "booking_id": 8, "created_at": "2026-04-24T09:52:57.165087+00:00", "payment_method": "mobile_money", "transaction_reference": "ece1b407-3015-4775-8469-0fd76eeb4f64"}	\N	2026-04-24 11:52:57.165087+02
130	\N	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_booking_passengers	booking_passengers	9	\N	{"id": 9, "name": "lameck nsomba", "is_child": false, "is_return": false, "booking_id": 9, "created_at": "2026-04-24T09:52:57.335979+00:00", "national_id": null, "return_date": null, "ticket_token": "b4af4b21-5601-409a-ae7b-f54991d2dbc5", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-7E12E14D", "linked_profile_id": null}	\N	2026-04-24 11:52:57.335979+02
131	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	delete_bookings	bookings	9	{"id": 9, "status": "confirmed", "trip_id": 33, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:52:57.0058+00:00", "expires_at": "2026-05-24T09:52:57.0058+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T09:52:57.0058+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "a3d20b4f-07ff-474d-81ca-a7b7f884fa76"}	\N	\N	2026-04-24 11:52:59.089809+02
132	\N	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	delete_booking_passengers	booking_passengers	9	{"id": 9, "name": "lameck nsomba", "is_child": false, "is_return": false, "booking_id": 9, "created_at": "2026-04-24T09:52:57.335979+00:00", "national_id": null, "return_date": null, "ticket_token": "b4af4b21-5601-409a-ae7b-f54991d2dbc5", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-7E12E14D", "linked_profile_id": null}	\N	\N	2026-04-24 11:52:59.089809+02
171	\N	\N	delete_booking_passengers	booking_passengers	8	{"id": 8, "name": "lameck nsomba", "is_child": false, "is_return": false, "booking_id": 8, "created_at": "2026-04-24T09:52:56.254358+00:00", "national_id": null, "return_date": null, "ticket_token": "a34d7b76-bdc4-4e9c-ad4f-69daea76e6d0", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-32539241", "linked_profile_id": null}	\N	\N	2026-04-24 11:59:20.281174+02
141	\N	\N	delete_seat_assignments	seat_assignments	1	{"id": 1, "trip_id": 36, "created_at": "2026-04-23T19:26:37.185692+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 1}	\N	\N	2026-04-24 11:59:08.620527+02
142	\N	\N	delete_seat_assignments	seat_assignments	2	{"id": 2, "trip_id": 2, "created_at": "2026-04-23T20:38:45.088908+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 2}	\N	\N	2026-04-24 11:59:08.620527+02
143	\N	\N	delete_seat_assignments	seat_assignments	3	{"id": 3, "trip_id": 2, "created_at": "2026-04-24T07:12:08.482716+00:00", "seat_label": "2B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 3}	\N	\N	2026-04-24 11:59:08.620527+02
144	\N	\N	delete_seat_assignments	seat_assignments	4	{"id": 4, "trip_id": 2, "created_at": "2026-04-24T08:58:13.903712+00:00", "seat_label": "3B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 4}	\N	\N	2026-04-24 11:59:08.620527+02
145	\N	\N	delete_seat_assignments	seat_assignments	5	{"id": 5, "trip_id": 2, "created_at": "2026-04-24T09:05:26.513368+00:00", "seat_label": "5B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 5}	\N	\N	2026-04-24 11:59:08.620527+02
146	\N	\N	delete_seat_assignments	seat_assignments	6	{"id": 6, "trip_id": 2, "created_at": "2026-04-24T09:15:50.077004+00:00", "seat_label": "2A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 6}	\N	\N	2026-04-24 11:59:08.620527+02
147	\N	\N	delete_seat_assignments	seat_assignments	7	{"id": 7, "trip_id": 2, "created_at": "2026-04-24T09:26:47.45482+00:00", "seat_label": "2C", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 7}	\N	\N	2026-04-24 11:59:08.620527+02
148	\N	\N	delete_seat_assignments	seat_assignments	8	{"id": 8, "trip_id": 33, "created_at": "2026-04-24T09:52:56.831059+00:00", "seat_label": "1C", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 8}	\N	\N	2026-04-24 11:59:08.620527+02
149	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	delete_bookings	bookings	1	{"id": 1, "status": "confirmed", "trip_id": 36, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:26:36.363365+00:00", "expires_at": "2026-05-23T19:26:36.363365+00:00", "total_fare": 850500.00, "updated_at": "2026-04-23T19:26:36.363365+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	\N	2026-04-24 11:59:20.281174+02
150	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	delete_bookings	bookings	2	{"id": 2, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T20:38:44.144067+00:00", "expires_at": "2026-05-23T20:38:44.144067+00:00", "total_fare": 850500.00, "updated_at": "2026-04-23T20:38:44.144067+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	\N	2026-04-24 11:59:20.281174+02
151	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	delete_bookings	bookings	3	{"id": 3, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T07:12:07.270913+00:00", "expires_at": "2026-05-24T07:12:07.270913+00:00", "total_fare": 850500.00, "updated_at": "2026-04-24T07:12:07.270913+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	\N	2026-04-24 11:59:20.281174+02
152	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	delete_bookings	bookings	4	{"id": 4, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T08:58:12.115468+00:00", "expires_at": "2026-05-24T08:58:12.115468+00:00", "total_fare": 850500.00, "updated_at": "2026-04-24T08:58:12.115468+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	\N	2026-04-24 11:59:20.281174+02
775	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	217	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
153	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	delete_bookings	bookings	5	{"id": 5, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:05:25.617664+00:00", "expires_at": "2026-05-24T09:05:25.617664+00:00", "total_fare": 850500.00, "updated_at": "2026-04-24T09:05:25.617664+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	\N	2026-04-24 11:59:20.281174+02
154	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	delete_bookings	bookings	6	{"id": 6, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:15:48.928016+00:00", "expires_at": "2026-05-24T09:15:48.928016+00:00", "total_fare": 850500.00, "updated_at": "2026-04-24T09:15:48.928016+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	\N	2026-04-24 11:59:20.281174+02
155	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	delete_bookings	bookings	7	{"id": 7, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:26:46.459842+00:00", "expires_at": "2026-05-24T09:26:46.459842+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T09:26:46.459842+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	\N	2026-04-24 11:59:20.281174+02
156	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	delete_bookings	bookings	8	{"id": 8, "status": "confirmed", "trip_id": 33, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T09:52:55.495813+00:00", "expires_at": "2026-05-24T09:52:55.495813+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T09:52:55.495813+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "a3d20b4f-07ff-474d-81ca-a7b7f884fa76"}	\N	\N	2026-04-24 11:59:20.281174+02
157	\N	\N	delete_booking_passengers	booking_passengers	1	{"id": 1, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 1, "created_at": "2026-04-23T19:26:36.77212+00:00", "national_id": null, "return_date": null, "ticket_token": "21a8b86d-b028-48c3-b171-611d0841492e", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-6C75EBD5", "linked_profile_id": null}	\N	\N	2026-04-24 11:59:20.281174+02
158	\N	\N	delete_payments	payments	1	{"id": 1, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-23T21:26:36.35978+00:00", "booking_id": 1, "created_at": "2026-04-23T19:26:37.550232+00:00", "payment_method": "mobile_money", "transaction_reference": "c78b4ced-204a-4033-8987-27bfe9653309"}	\N	\N	2026-04-24 11:59:20.281174+02
159	\N	\N	delete_booking_passengers	booking_passengers	2	{"id": 2, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 2, "created_at": "2026-04-23T20:38:44.685055+00:00", "national_id": null, "return_date": null, "ticket_token": "fa48a6ef-01ca-4277-84c4-dcddd25c0106", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-A9A5ED44", "linked_profile_id": null}	\N	\N	2026-04-24 11:59:20.281174+02
160	\N	\N	delete_payments	payments	2	{"id": 2, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-23T22:38:44.254837+00:00", "booking_id": 2, "created_at": "2026-04-23T20:38:45.4759+00:00", "payment_method": "mobile_money", "transaction_reference": "6a84ac6b-eff0-49c8-af6e-6f34f721a4b2"}	\N	\N	2026-04-24 11:59:20.281174+02
161	\N	\N	delete_booking_passengers	booking_passengers	3	{"id": 3, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 3, "created_at": "2026-04-24T07:12:07.969745+00:00", "national_id": null, "return_date": null, "ticket_token": "8f7f25b6-669e-45e7-8274-f6b63df673ff", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-338B39AD", "linked_profile_id": null}	\N	\N	2026-04-24 11:59:20.281174+02
162	\N	\N	delete_payments	payments	3	{"id": 3, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-24T09:12:08.893039+00:00", "booking_id": 3, "created_at": "2026-04-24T07:12:10.200408+00:00", "payment_method": "mobile_money", "transaction_reference": "7caf8811-c3bb-41c1-a5f4-1b504944f144"}	\N	\N	2026-04-24 11:59:20.281174+02
163	\N	\N	delete_booking_passengers	booking_passengers	4	{"id": 4, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 4, "created_at": "2026-04-24T08:58:12.917253+00:00", "national_id": null, "return_date": null, "ticket_token": "e3c6f0ad-115a-400f-9bc0-f5cbbfb4837a", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-A3EC0357", "linked_profile_id": null}	\N	\N	2026-04-24 11:59:20.281174+02
164	\N	\N	delete_payments	payments	4	{"id": 4, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-24T10:58:13.303666+00:00", "booking_id": 4, "created_at": "2026-04-24T08:58:14.514303+00:00", "payment_method": "mobile_money", "transaction_reference": "a87ff167-75c5-42cf-9a45-9fe49378fae1"}	\N	\N	2026-04-24 11:59:20.281174+02
165	\N	\N	delete_booking_passengers	booking_passengers	5	{"id": 5, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 5, "created_at": "2026-04-24T09:05:26.107257+00:00", "national_id": null, "return_date": null, "ticket_token": "52f3f2fa-e7da-4876-bc1f-c580a3011278", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-147DDCC8", "linked_profile_id": null}	\N	\N	2026-04-24 11:59:20.281174+02
166	\N	\N	delete_payments	payments	5	{"id": 5, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-24T11:05:25.742587+00:00", "booking_id": 5, "created_at": "2026-04-24T09:05:26.950997+00:00", "payment_method": "mobile_money", "transaction_reference": "0aadced5-2bd7-491a-8b83-a9dcab60d412"}	\N	\N	2026-04-24 11:59:20.281174+02
167	\N	\N	delete_booking_passengers	booking_passengers	6	{"id": 6, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 6, "created_at": "2026-04-24T09:15:49.658537+00:00", "national_id": null, "return_date": null, "ticket_token": "dccff3e0-6ad9-464d-a90b-c2b61f568a39", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-3F5634A4", "linked_profile_id": null}	\N	\N	2026-04-24 11:59:20.281174+02
168	\N	\N	delete_payments	payments	6	{"id": 6, "amount": 850500.00, "status": "completed", "paid_at": "2026-04-24T11:15:49.26841+00:00", "booking_id": 6, "created_at": "2026-04-24T09:15:50.44088+00:00", "payment_method": "mobile_money", "transaction_reference": "3f7200cb-7112-442d-8890-e617ab587a23"}	\N	\N	2026-04-24 11:59:20.281174+02
169	\N	\N	delete_booking_passengers	booking_passengers	7	{"id": 7, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 7, "created_at": "2026-04-24T09:26:47.050506+00:00", "national_id": null, "return_date": null, "ticket_token": "8936a9c6-dcf5-48d8-ba55-699124271bbd", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-D5DD2D2D", "linked_profile_id": null}	\N	\N	2026-04-24 11:59:20.281174+02
172	\N	\N	delete_payments	payments	8	{"id": 8, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-24T11:52:57.657801+00:00", "booking_id": 8, "created_at": "2026-04-24T09:52:57.165087+00:00", "payment_method": "mobile_money", "transaction_reference": "ece1b407-3015-4775-8469-0fd76eeb4f64"}	\N	\N	2026-04-24 11:59:20.281174+02
173	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	10	\N	{"id": 10, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T10:11:18.932848+00:00", "expires_at": "2026-05-24T10:11:18.932848+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T10:11:18.932848+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 12:11:18.932848+02
174	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	10	\N	{"id": 10, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 10, "created_at": "2026-04-24T10:11:19.401908+00:00", "national_id": null, "return_date": null, "ticket_token": "aa2c82c6-7141-4080-84fd-d793fdbf4f61", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-0D7896F4", "linked_profile_id": null}	\N	2026-04-24 12:11:19.401908+02
175	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	10	\N	{"id": 10, "trip_id": 2, "created_at": "2026-04-24T10:11:19.811345+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 10}	\N	2026-04-24 12:11:19.811345+02
176	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	9	\N	{"id": 9, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-24T12:11:19.042383+00:00", "booking_id": 10, "created_at": "2026-04-24T10:11:20.211806+00:00", "payment_method": "mobile_money", "transaction_reference": "2b21c632-41c4-442b-a705-dcc54f6db2e6"}	\N	2026-04-24 12:11:20.211806+02
177	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_bookings	bookings	11	\N	{"id": 11, "status": "confirmed", "trip_id": 33, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T10:11:36.351299+00:00", "expires_at": "2026-05-24T10:11:36.351299+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T10:11:36.351299+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "a3d20b4f-07ff-474d-81ca-a7b7f884fa76"}	\N	2026-04-24 12:11:36.351299+02
178	\N	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_booking_passengers	booking_passengers	11	\N	{"id": 11, "name": "lameck nsomba", "is_child": false, "is_return": false, "booking_id": 11, "created_at": "2026-04-24T10:11:36.764039+00:00", "national_id": null, "return_date": null, "ticket_token": "e38da37b-f7ea-42cc-b522-84282397fd5c", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-802FE49F", "linked_profile_id": null}	\N	2026-04-24 12:11:36.764039+02
179	\N	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_seat_assignments	seat_assignments	11	\N	{"id": 11, "trip_id": 33, "created_at": "2026-04-24T10:11:37.181738+00:00", "seat_label": "1B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 11}	\N	2026-04-24 12:11:37.181738+02
180	\N	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	insert_payments	payments	10	\N	{"id": 10, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-24T12:11:38.005214+00:00", "booking_id": 11, "created_at": "2026-04-24T10:11:37.575972+00:00", "payment_method": "mobile_money", "transaction_reference": "a1901e6f-bfd0-4699-9e8f-c45b00ca75f6"}	\N	2026-04-24 12:11:37.575972+02
181	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	12	\N	{"id": 12, "status": "confirmed", "trip_id": 2, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T10:14:30.114853+00:00", "expires_at": "2026-05-24T10:14:30.114853+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T10:14:30.114853+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 12:14:30.114853+02
182	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	12	\N	{"id": 12, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 12, "created_at": "2026-04-24T10:14:30.851317+00:00", "national_id": null, "return_date": null, "ticket_token": "1bd666bc-9022-4063-8a28-31ba3697cd57", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-9BF19690", "linked_profile_id": null}	\N	2026-04-24 12:14:30.851317+02
183	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	12	\N	{"id": 12, "trip_id": 2, "created_at": "2026-04-24T10:14:31.31674+00:00", "seat_label": "1B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 12}	\N	2026-04-24 12:14:31.31674+02
184	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	11	\N	{"id": 11, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-24T12:14:30.637555+00:00", "booking_id": 12, "created_at": "2026-04-24T10:14:31.836127+00:00", "payment_method": "mobile_money", "transaction_reference": "f1888113-c752-4dcf-b28d-879bfed61b49"}	\N	2026-04-24 12:14:31.836127+02
185	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	13	\N	{"id": 13, "status": "confirmed", "trip_id": 3, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T10:29:18.910607+00:00", "expires_at": "2026-05-24T10:29:18.910607+00:00", "total_fare": 85500.00, "updated_at": "2026-04-24T10:29:18.910607+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 12:29:18.910607+02
186	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	13	\N	{"id": 13, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 13, "created_at": "2026-04-24T10:29:19.307704+00:00", "national_id": null, "return_date": null, "ticket_token": "92ff3495-b430-4969-9051-70cefba658b3", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-219D2665", "linked_profile_id": null}	\N	2026-04-24 12:29:19.307704+02
187	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	13	\N	{"id": 13, "trip_id": 3, "created_at": "2026-04-24T10:29:19.730611+00:00", "seat_label": "1B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 13}	\N	2026-04-24 12:29:19.730611+02
188	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	12	\N	{"id": 12, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-24T12:29:18.967456+00:00", "booking_id": 13, "created_at": "2026-04-24T10:29:20.127176+00:00", "payment_method": "mobile_money", "transaction_reference": "9aaa6a15-9861-4c2d-afdc-bccc240976fb"}	\N	2026-04-24 12:29:20.127176+02
189	\N	8231bfd4-c74e-4c83-b231-69a74e5d6f29	update_tenants	tenants	3dce9d0c-181d-4a54-911c-471959d7065d	{"id": "3dce9d0c-181d-4a54-911c-471959d7065d", "logo": null, "name": "Sososo", "contact": "0885705304", "settings": {}, "is_active": true, "created_at": "2026-04-23T19:19:22.856095+00:00", "updated_at": "2026-04-23T19:19:22.856095+00:00"}	{"id": "3dce9d0c-181d-4a54-911c-471959d7065d", "logo": null, "name": "Sososo", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Sososo"}, "features": {"enable_refunds": true, "enable_reschedule": true, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T19:19:22.856095+00:00", "updated_at": "2026-04-24T11:44:47.256353+00:00"}	Changed: settings	2026-04-24 13:44:47.256353+02
190	\N	8231bfd4-c74e-4c83-b231-69a74e5d6f29	update_tenants	tenants	3dce9d0c-181d-4a54-911c-471959d7065d	{"id": "3dce9d0c-181d-4a54-911c-471959d7065d", "logo": null, "name": "Sososo", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Sososo"}, "features": {"enable_refunds": true, "enable_reschedule": true, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T19:19:22.856095+00:00", "updated_at": "2026-04-24T11:44:47.256353+00:00"}	{"id": "3dce9d0c-181d-4a54-911c-471959d7065d", "logo": null, "name": "Sososo", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Sososo"}, "features": {"enable_refunds": true, "enable_reschedule": true, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 25}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T19:19:22.856095+00:00", "updated_at": "2026-04-24T11:45:18.413638+00:00"}	Changed: settings	2026-04-24 13:45:18.413638+02
191	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_buses	buses	3	\N	{"id": 3, "capacity": 72, "seat_map": {"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}, "16A": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 1}, "16B": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 2}, "16C": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 3}, "16D": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 4}, "17A": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 1}, "17B": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 2}, "17C": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 3}, "17D": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 4}, "18A": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 1}, "18B": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 2}, "18C": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 3}, "18D": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D", "16A", "16B", "16C", "16D", "17A", "17B", "17C", "17D", "18A", "18B", "18C", "18D"], "column_layout": "2,2"}, "amenities": ["Wi-Fi"], "is_active": true, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T12:21:38.48612+00:00", "updated_at": "2026-04-24T12:21:38.48612+00:00", "registration_number": "test1234"}	\N	2026-04-24 14:21:38.48612+02
192	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_trips	trips	61	\N	{"id": 61, "bus_id": 3, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T12:37:21.20186+00:00", "updated_at": "2026-04-24T12:37:21.20186+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-25T19:43:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-25T18:41:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-24 14:37:21.20186+02
193	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	14	\N	{"id": 14, "status": "confirmed", "trip_id": 34, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T13:06:15.184226+00:00", "expires_at": "2026-05-24T13:06:15.184226+00:00", "total_fare": 170500.00, "updated_at": "2026-04-24T13:06:15.184226+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 2, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-24 15:06:15.184226+02
194	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	14	\N	{"id": 14, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 14, "created_at": "2026-04-24T13:06:15.753414+00:00", "national_id": null, "return_date": null, "ticket_token": "8dc199d9-354f-4c4f-b49a-ef64ae0a1e00", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-FF2CFFC2", "linked_profile_id": null}	\N	2026-04-24 15:06:15.753414+02
195	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	14	\N	{"id": 14, "trip_id": 34, "created_at": "2026-04-24T13:06:16.26912+00:00", "seat_label": "2B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 14}	\N	2026-04-24 15:06:16.26912+02
196	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	15	\N	{"id": 15, "name": "smile", "is_child": false, "is_return": false, "booking_id": 14, "created_at": "2026-04-24T13:06:16.810963+00:00", "national_id": null, "return_date": null, "ticket_token": "1648c0d3-c681-4583-a94e-98018f225b0c", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-A343941C", "linked_profile_id": null}	\N	2026-04-24 15:06:16.810963+02
197	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	15	\N	{"id": 15, "trip_id": 34, "created_at": "2026-04-24T13:06:17.577788+00:00", "seat_label": "2D", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 15}	\N	2026-04-24 15:06:17.577788+02
198	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	13	\N	{"id": 13, "amount": 170500.00, "status": "completed", "paid_at": "2026-04-24T15:05:35.445309+00:00", "booking_id": 14, "created_at": "2026-04-24T13:06:18.157214+00:00", "payment_method": "mobile_money", "transaction_reference": "8e63b737-8fae-402a-811c-e100dd77d077"}	\N	2026-04-24 15:06:18.157214+02
199	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_trips	trips	62	\N	{"id": 62, "bus_id": null, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-25T18:43:44.248282+00:00", "updated_at": "2026-04-25T18:43:44.248282+00:00", "original_bus_id": null, "arrival_datetime": null, "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-25T18:43:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-25 20:43:44.248282+02
242	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_stages	stages	9	\N	{"id": 9, "location": "Ntcheu", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:25:13.065675+00:00", "stage_name": "Ntcheu Depot", "updated_at": "2026-04-26T08:25:13.065675+00:00", "coordinates": null, "is_major_stage": false}	\N	2026-04-26 10:25:13.065675+02
200	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	update_trips	trips	62	{"id": 62, "bus_id": null, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-25T18:43:44.248282+00:00", "updated_at": "2026-04-25T18:43:44.248282+00:00", "original_bus_id": null, "arrival_datetime": null, "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-25T18:43:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 62, "bus_id": null, "status": "cancelled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-25T18:43:44.248282+00:00", "updated_at": "2026-04-25T18:43:59.533665+00:00", "original_bus_id": null, "arrival_datetime": null, "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-25T18:43:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-25 20:43:59.533665+02
201	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "logo_storage_path": "new-provider/logo-1776969977318.jpg"}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-23T18:46:32.355435+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 8, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:38.924142+00:00"}	Changed: settings	2026-04-25 23:05:38.924142+02
202	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 8, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:38.924142+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 80, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:38.92414+00:00"}	Changed: settings	2026-04-25 23:05:38.92414+02
203	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 80, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:38.92414+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 8, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:43.482799+00:00"}	Changed: settings	2026-04-25 23:05:43.482799+02
204	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 8, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:43.482799+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 0, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:43.683075+00:00"}	Changed: settings	2026-04-25 23:05:43.683075+02
205	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 0, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:45.505183+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 1, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:46.743463+00:00"}	Changed: settings	2026-04-25 23:05:46.743463+02
206	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 1, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:46.743463+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:47.943742+00:00"}	Changed: settings	2026-04-25 23:05:47.943742+02
207	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:05:47.943742+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 11, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:13.153232+00:00"}	Changed: settings	2026-04-25 23:06:13.153232+02
208	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 11, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:13.153232+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:13.92774+00:00"}	Changed: settings	2026-04-25 23:06:13.92774+02
209	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:13.92774+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 11, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:16.104207+00:00"}	Changed: settings	2026-04-25 23:06:16.104207+02
210	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 11, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:16.104207+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 12, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:18.105464+00:00"}	Changed: settings	2026-04-25 23:06:18.105464+02
211	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 12, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:18.105464+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 11, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:18.904741+00:00"}	Changed: settings	2026-04-25 23:06:18.904741+02
212	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 11, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:18.904741+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:19.642816+00:00"}	Changed: settings	2026-04-25 23:06:19.642816+02
213	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:19.642816+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 9, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:20.283912+00:00"}	Changed: settings	2026-04-25 23:06:20.283912+02
214	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 9, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:20.283912+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 8, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:20.89119+00:00"}	Changed: settings	2026-04-25 23:06:20.89119+02
215	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 8, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:20.89119+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 7, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:22.333993+00:00"}	Changed: settings	2026-04-25 23:06:22.333993+02
216	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 7, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:22.333993+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 6, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:22.850576+00:00"}	Changed: settings	2026-04-25 23:06:22.850576+02
217	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 6, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:22.850576+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 5, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:23.47349+00:00"}	Changed: settings	2026-04-25 23:06:23.47349+02
218	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 5, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:23.47349+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 4, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:24.12184+00:00"}	Changed: settings	2026-04-25 23:06:24.12184+02
219	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 4, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:24.12184+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 5, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:25.726442+00:00"}	Changed: settings	2026-04-25 23:06:25.726442+02
220	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 5, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:25.726442+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 4, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:26.198701+00:00"}	Changed: settings	2026-04-25 23:06:26.198701+02
221	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 4, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:26.198701+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 3, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:26.779308+00:00"}	Changed: settings	2026-04-25 23:06:26.779308+02
222	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 3, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:26.779308+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 4, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:29.070771+00:00"}	Changed: settings	2026-04-25 23:06:29.070771+02
223	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 4, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:29.070771+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 3, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:29.615872+00:00"}	Changed: settings	2026-04-25 23:06:29.615872+02
224	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 3, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:29.615872+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 2, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:30.139728+00:00"}	Changed: settings	2026-04-25 23:06:30.139728+02
225	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 2, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:30.139728+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 1, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:30.607493+00:00"}	Changed: settings	2026-04-25 23:06:30.607493+02
226	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 1, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:30.607493+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 0, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:31.098764+00:00"}	Changed: settings	2026-04-25 23:06:31.098764+02
227	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 0, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:31.098764+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 1, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:32.039385+00:00"}	Changed: settings	2026-04-25 23:06:32.039385+02
228	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_tenants	tenants	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 1, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:32.039385+00:00"}	{"id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "logo": null, "name": "Machawi", "contact": "0885705304", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-23T18:46:31.162243+00:00", "updated_at": "2026-04-25T21:06:53.942586+00:00"}	Changed: settings	2026-04-25 23:06:53.942586+02
229	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_profiles	profiles	dfd092e2-457f-4887-a196-1c55c2627cda	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-24T09:36:28.122316+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "super_admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-26T08:06:13.990268+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	Changed: role	2026-04-26 10:06:13.990268+02
230	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	profile_role_change	profile	dfd092e2-457f-4887-a196-1c55c2627cda	{"role": "admin"}	{"role": "super_admin"}	Role changed from admin to super_admin	2026-04-26 10:06:13.990268+02
776	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	247	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
231	\N	\N	update_profiles	profiles	dfd092e2-457f-4887-a196-1c55c2627cda	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "super_admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-26T08:06:13.990268+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	{"id": "dfd092e2-457f-4887-a196-1c55c2627cda", "role": "super_admin", "email": "bit-023-22@must.ac.mw", "phone": null, "full_name": "Vamp2o5", "tenant_id": null, "created_at": "2026-04-23T18:38:29.208447+00:00", "updated_at": "2026-04-26T08:06:32.333178+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "84d8de5c-282b-45ee-8877-739bc1e9c562", "payment_pin_hash": null}	Changed: tenant_id	2026-04-26 10:06:32.333178+02
232	\N	\N	insert_tenants	tenants	665a127e-0619-4505-9538-34df0b6d5f7a	\N	{"id": "665a127e-0619-4505-9538-34df0b6d5f7a", "logo": null, "name": "Tam Tam", "contact": "0987674562", "settings": {}, "is_active": true, "created_at": "2026-04-26T08:08:37.797183+00:00", "updated_at": "2026-04-26T08:08:37.797183+00:00"}	\N	2026-04-26 10:08:37.797183+02
233	665a127e-0619-4505-9538-34df0b6d5f7a	\N	insert_profiles	profiles	e60a8d5b-b935-447a-9cb1-8c0595dc159b	\N	{"id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b", "role": "passenger", "email": "yefot32203@hacknapp.com", "phone": null, "full_name": "Tam Tam Admin", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:08:37.895339+00:00", "updated_at": "2026-04-26T08:08:37.895339+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "f36d71fe-8556-49f1-be0a-8c29862c20ac", "payment_pin_hash": null}	\N	2026-04-26 10:08:37.895339+02
234	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_profiles	profiles	e60a8d5b-b935-447a-9cb1-8c0595dc159b	{"id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b", "role": "passenger", "email": "yefot32203@hacknapp.com", "phone": null, "full_name": "Tam Tam Admin", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:08:37.895339+00:00", "updated_at": "2026-04-26T08:08:37.895339+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "f36d71fe-8556-49f1-be0a-8c29862c20ac", "payment_pin_hash": null}	{"id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b", "role": "admin", "email": "yefot32203@hacknapp.com", "phone": null, "full_name": "Tam Tam Admin", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:08:37.895339+00:00", "updated_at": "2026-04-26T08:08:38.488748+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "f36d71fe-8556-49f1-be0a-8c29862c20ac", "payment_pin_hash": null}	Changed: role	2026-04-26 10:08:38.488748+02
235	665a127e-0619-4505-9538-34df0b6d5f7a	\N	profile_role_change	profile	e60a8d5b-b935-447a-9cb1-8c0595dc159b	{"role": "passenger"}	{"role": "admin"}	Role changed from passenger to admin	2026-04-26 10:08:38.488748+02
236	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_buses	buses	4	\N	{"id": 4, "capacity": 65, "seat_map": {"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "1E": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 5}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "2E": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 5}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "3E": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 5}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "4E": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 5}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "5E": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 5}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "6E": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 5}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "7E": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 5}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "8E": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 5}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "9E": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 5}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "10E": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 5}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "11E": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 5}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "12E": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 5}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "13E": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 5}}, "seats": ["1A", "1B", "1C", "1D", "1E", "2A", "2B", "2C", "2D", "2E", "3A", "3B", "3C", "3D", "3E", "4A", "4B", "4C", "4D", "4E", "5A", "5B", "5C", "5D", "5E", "6A", "6B", "6C", "6D", "6E", "7A", "7B", "7C", "7D", "7E", "8A", "8B", "8C", "8D", "8E", "9A", "9B", "9C", "9D", "9E", "10A", "10B", "10C", "10D", "10E", "11A", "11B", "11C", "11D", "11E", "12A", "12B", "12C", "12D", "12E", "13A", "13B", "13C", "13D", "13E"], "column_layout": "2,3"}, "amenities": ["Wi-Fi", "USB Ports"], "is_active": true, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:21:53.027326+00:00", "updated_at": "2026-04-26T08:21:53.027326+00:00", "registration_number": "LL 10000"}	\N	2026-04-26 10:21:53.027326+02
237	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_buses	buses	5	\N	{"id": 5, "capacity": 72, "seat_map": {"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}, "16A": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 1}, "16B": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 2}, "16C": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 3}, "16D": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 4}, "17A": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 1}, "17B": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 2}, "17C": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 3}, "17D": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 4}, "18A": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 1}, "18B": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 2}, "18C": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 3}, "18D": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D", "16A", "16B", "16C", "16D", "17A", "17B", "17C", "17D", "18A", "18B", "18C", "18D"], "column_layout": "2,2"}, "amenities": ["Snack Service", "Reclining Seats"], "is_active": true, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:22:17.71488+00:00", "updated_at": "2026-04-26T08:22:17.71488+00:00", "registration_number": "LL 20000"}	\N	2026-04-26 10:22:17.71488+02
238	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_buses	buses	6	\N	{"id": 6, "capacity": 64, "seat_map": {"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}, "16A": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 1}, "16B": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 2}, "16C": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 3}, "16D": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D", "16A", "16B", "16C", "16D"], "column_layout": "2,2"}, "amenities": ["Wi-Fi", "Entertainment Screen", "AC", "USB Ports", "Luggage Storage"], "is_active": true, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:22:58.4505+00:00", "updated_at": "2026-04-26T08:22:58.4505+00:00", "registration_number": "LL 30000"}	\N	2026-04-26 10:22:58.4505+02
239	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_stages	stages	6	\N	{"id": 6, "location": "Mzimba", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:23:39.616992+00:00", "stage_name": "Mzuzu Terminal", "updated_at": "2026-04-26T08:23:39.616992+00:00", "coordinates": null, "is_major_stage": true}	\N	2026-04-26 10:23:39.616992+02
240	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_stages	stages	7	\N	{"id": 7, "location": "Lilongwe", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:24:14.355728+00:00", "stage_name": "Gateway Mall", "updated_at": "2026-04-26T08:24:14.355728+00:00", "coordinates": null, "is_major_stage": true}	\N	2026-04-26 10:24:14.355728+02
241	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_stages	stages	8	\N	{"id": 8, "location": "Blantyre", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:24:43.962661+00:00", "stage_name": "Wenera Terminal", "updated_at": "2026-04-26T08:24:43.962661+00:00", "coordinates": null, "is_major_stage": true}	\N	2026-04-26 10:24:43.962661+02
243	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_stages	stages	10	\N	{"id": 10, "location": "Blantyre", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:25:32.501305+00:00", "stage_name": "Zalewa", "updated_at": "2026-04-26T08:25:32.501305+00:00", "coordinates": null, "is_major_stage": false}	\N	2026-04-26 10:25:32.501305+02
244	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_stages	stages	11	\N	{"id": 11, "location": "Kasungu", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:25:48.675999+00:00", "stage_name": "Kasungu Depot", "updated_at": "2026-04-26T08:25:48.675999+00:00", "coordinates": null, "is_major_stage": false}	\N	2026-04-26 10:25:48.675999+02
245	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_routes	routes	5	\N	{"id": 5, "base_fare": 85000.00, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:29:58.47588+00:00", "route_code": "Blantyre - Lilongwe", "updated_at": "2026-04-26T08:29:58.47588+00:00", "origin_stage_id": 8, "intermediate_stops": [{"order": 1, "location": "Blantyre", "stage_id": 10, "stage_name": "Zalewa"}, {"order": 2, "location": "Ntcheu", "stage_id": 9, "stage_name": "Ntcheu Depot"}], "destination_stage_id": 7}	\N	2026-04-26 10:29:58.47588+02
246	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_routes	routes	6	\N	{"id": 6, "base_fare": 85000.00, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:32:02.310289+00:00", "route_code": "Lilongwe - Blantyre", "updated_at": "2026-04-26T08:32:02.310289+00:00", "origin_stage_id": 7, "intermediate_stops": [{"order": 1, "location": "Ntcheu", "stage_id": 9, "stage_name": "Ntcheu Depot"}, {"order": 2, "location": "Blantyre", "stage_id": 10, "stage_name": "Zalewa"}], "destination_stage_id": 8}	\N	2026-04-26 10:32:02.310289+02
247	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_routes	routes	7	\N	{"id": 7, "base_fare": 100000.00, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:33:21.432272+00:00", "route_code": "Lilongwe - Mzimba", "updated_at": "2026-04-26T08:33:21.432272+00:00", "origin_stage_id": 7, "intermediate_stops": [{"order": 1, "location": "Kasungu", "stage_id": 11, "stage_name": "Kasungu Depot"}], "destination_stage_id": 6}	\N	2026-04-26 10:33:21.432272+02
248	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_routes	routes	8	\N	{"id": 8, "base_fare": 100000.00, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:34:09.044413+00:00", "route_code": "Mzimba - Lilongwe", "updated_at": "2026-04-26T08:34:09.044413+00:00", "origin_stage_id": 6, "intermediate_stops": [{"order": 1, "location": "Kasungu", "stage_id": 11, "stage_name": "Kasungu Depot"}], "destination_stage_id": 7}	\N	2026-04-26 10:34:09.044413+02
249	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	63	\N	{"id": 63, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
250	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	64	\N	{"id": 64, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
251	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	65	\N	{"id": 65, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
252	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	66	\N	{"id": 66, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
253	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	67	\N	{"id": 67, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
254	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	68	\N	{"id": 68, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-01T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-01T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
255	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	69	\N	{"id": 69, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-02T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-02T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
505	\N	\N	insert_profiles	profiles	a0797122-a56d-44f3-827a-f0ff0c183dde	\N	{"id": "a0797122-a56d-44f3-827a-f0ff0c183dde", "role": "passenger", "email": "bit-020-22@must.ac.mw", "phone": null, "full_name": "smile Minyaliwa", "tenant_id": null, "created_at": "2026-04-26T20:23:11.494898+00:00", "updated_at": "2026-04-26T20:23:11.494898+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "fa14e42d-4a4d-4d90-a86b-3212d001cdcf", "payment_pin_hash": null}	\N	2026-04-26 22:23:11.494898+02
256	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	70	\N	{"id": 70, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-03T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-03T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
257	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	71	\N	{"id": 71, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-04T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-04T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
258	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	72	\N	{"id": 72, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-05T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-05T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
259	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	73	\N	{"id": 73, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-06T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-06T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
260	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	74	\N	{"id": 74, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-07T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-07T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
261	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	75	\N	{"id": 75, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-08T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-08T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
262	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	76	\N	{"id": 76, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-09T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-09T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
263	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	77	\N	{"id": 77, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-10T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-10T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
264	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	78	\N	{"id": 78, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-11T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-11T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
265	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	79	\N	{"id": 79, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-12T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-12T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
266	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	80	\N	{"id": 80, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-13T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-13T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
267	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	81	\N	{"id": 81, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-14T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-14T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
268	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	82	\N	{"id": 82, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-15T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-15T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
269	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	83	\N	{"id": 83, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-16T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-16T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
270	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	84	\N	{"id": 84, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-17T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-17T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
271	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	85	\N	{"id": 85, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-18T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-18T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
272	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	86	\N	{"id": 86, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-19T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-19T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
273	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	87	\N	{"id": 87, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-20T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-20T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
274	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	88	\N	{"id": 88, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-21T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-21T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
275	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	89	\N	{"id": 89, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-22T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-22T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
276	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	90	\N	{"id": 90, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-23T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-23T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
277	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	91	\N	{"id": 91, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-24T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-24T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
278	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	92	\N	{"id": 92, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-25T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-05-25T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:39:45.758516+02
279	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	93	\N	{"id": 93, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-26T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
280	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	94	\N	{"id": 94, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-27T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
281	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	95	\N	{"id": 95, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-28T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
282	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	96	\N	{"id": 96, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-29T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
283	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	97	\N	{"id": 97, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-30T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
284	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	98	\N	{"id": 98, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-01T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-01T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
285	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	99	\N	{"id": 99, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-02T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-02T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
286	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	100	\N	{"id": 100, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-03T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-03T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
287	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	101	\N	{"id": 101, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-04T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-04T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
288	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	102	\N	{"id": 102, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-05T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-05T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
289	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	103	\N	{"id": 103, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-06T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-06T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
290	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	104	\N	{"id": 104, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-07T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-07T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
291	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	105	\N	{"id": 105, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-08T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-08T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
292	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	106	\N	{"id": 106, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-09T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-09T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
293	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	107	\N	{"id": 107, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-10T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-10T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
294	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	108	\N	{"id": 108, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-11T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-11T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
295	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	109	\N	{"id": 109, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-12T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-12T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
296	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	110	\N	{"id": 110, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-13T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-13T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
297	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	111	\N	{"id": 111, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-14T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-14T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
298	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	112	\N	{"id": 112, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-15T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-15T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
299	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	113	\N	{"id": 113, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-16T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-16T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
300	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	114	\N	{"id": 114, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-17T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-17T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
301	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	115	\N	{"id": 115, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-18T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-18T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
302	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	116	\N	{"id": 116, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-19T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-19T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
303	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	117	\N	{"id": 117, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-20T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-20T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
304	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	118	\N	{"id": 118, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-21T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-21T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
305	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	119	\N	{"id": 119, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-22T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-22T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
306	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	120	\N	{"id": 120, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-23T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-23T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
307	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	121	\N	{"id": 121, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-24T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-24T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
308	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	122	\N	{"id": 122, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-05-25T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-05-25T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:40:31.871268+02
309	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	123	\N	{"id": 123, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
310	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	124	\N	{"id": 124, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
311	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	125	\N	{"id": 125, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
312	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	126	\N	{"id": 126, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
313	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	127	\N	{"id": 127, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
314	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	128	\N	{"id": 128, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-01T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-01T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
315	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	129	\N	{"id": 129, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-02T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-02T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
316	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	130	\N	{"id": 130, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-03T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-03T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
317	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	131	\N	{"id": 131, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-04T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-04T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
318	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	132	\N	{"id": 132, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-05T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-05T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
319	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	133	\N	{"id": 133, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-06T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-06T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
320	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	134	\N	{"id": 134, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-07T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-07T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
321	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	135	\N	{"id": 135, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-08T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-08T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
322	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	136	\N	{"id": 136, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-09T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-09T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
323	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	137	\N	{"id": 137, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-10T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-10T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
324	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	138	\N	{"id": 138, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-11T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-11T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
325	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	139	\N	{"id": 139, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-12T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-12T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
326	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	140	\N	{"id": 140, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-13T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-13T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
327	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	141	\N	{"id": 141, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-14T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-14T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
328	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	142	\N	{"id": 142, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-15T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-15T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
329	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	143	\N	{"id": 143, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-16T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-16T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
330	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	144	\N	{"id": 144, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-17T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-17T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
331	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	145	\N	{"id": 145, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-18T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-18T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
332	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	146	\N	{"id": 146, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-19T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-19T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
333	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	147	\N	{"id": 147, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-20T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-20T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
334	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	148	\N	{"id": 148, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-21T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-21T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
335	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	149	\N	{"id": 149, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-22T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-22T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
336	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	150	\N	{"id": 150, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-23T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-23T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
337	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	151	\N	{"id": 151, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-24T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-24T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
338	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	152	\N	{"id": 152, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-25T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-05-25T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:44:25.218603+02
339	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	153	\N	{"id": 153, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
340	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	154	\N	{"id": 154, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
341	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	155	\N	{"id": 155, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
342	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	156	\N	{"id": 156, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
343	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	157	\N	{"id": 157, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
344	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	158	\N	{"id": 158, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-01T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-01T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
345	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	159	\N	{"id": 159, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-02T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-02T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
346	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	160	\N	{"id": 160, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-03T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-03T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
347	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	161	\N	{"id": 161, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-04T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-04T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
348	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	162	\N	{"id": 162, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-05T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-05T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
349	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	163	\N	{"id": 163, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-06T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-06T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
350	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	164	\N	{"id": 164, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-07T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-07T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
351	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	165	\N	{"id": 165, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-08T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-08T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
352	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	166	\N	{"id": 166, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-09T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-09T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
353	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	167	\N	{"id": 167, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-10T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-10T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
354	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	168	\N	{"id": 168, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-11T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-11T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
355	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	169	\N	{"id": 169, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-12T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-12T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
356	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	170	\N	{"id": 170, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-13T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-13T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
357	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	171	\N	{"id": 171, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-14T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-14T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
358	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	172	\N	{"id": 172, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-15T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-15T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
359	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	173	\N	{"id": 173, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-16T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-16T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
360	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	174	\N	{"id": 174, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-17T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-17T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
361	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	175	\N	{"id": 175, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-18T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-18T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
362	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	176	\N	{"id": 176, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-19T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-19T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
363	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	177	\N	{"id": 177, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-20T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-20T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
364	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	178	\N	{"id": 178, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-21T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-21T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
365	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	179	\N	{"id": 179, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-22T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-22T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
366	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	180	\N	{"id": 180, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-23T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-23T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
367	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	181	\N	{"id": 181, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-24T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-24T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
368	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	182	\N	{"id": 182, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-05-25T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-05-25T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 10:45:05.562627+02
369	\N	\N	insert_tenants	tenants	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T08:54:59.408617+00:00"}	\N	2026-04-26 10:54:59.408617+02
370	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	insert_profiles	profiles	f9755628-51c0-40f9-abb4-371f85908664	\N	{"id": "f9755628-51c0-40f9-abb4-371f85908664", "role": "passenger", "email": "jvu8yuy3rs@ruutukf.com", "phone": null, "full_name": "Kwezy Admin", "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T08:54:59.50937+00:00", "updated_at": "2026-04-26T08:54:59.50937+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "7083337e-e508-4e1a-b4d8-c6941eed7763", "payment_pin_hash": null}	\N	2026-04-26 10:54:59.50937+02
371	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_profiles	profiles	f9755628-51c0-40f9-abb4-371f85908664	{"id": "f9755628-51c0-40f9-abb4-371f85908664", "role": "passenger", "email": "jvu8yuy3rs@ruutukf.com", "phone": null, "full_name": "Kwezy Admin", "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T08:54:59.50937+00:00", "updated_at": "2026-04-26T08:54:59.50937+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "7083337e-e508-4e1a-b4d8-c6941eed7763", "payment_pin_hash": null}	{"id": "f9755628-51c0-40f9-abb4-371f85908664", "role": "admin", "email": "jvu8yuy3rs@ruutukf.com", "phone": null, "full_name": "Kwezy Admin", "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T08:54:59.50937+00:00", "updated_at": "2026-04-26T08:55:00.27621+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "7083337e-e508-4e1a-b4d8-c6941eed7763", "payment_pin_hash": null}	Changed: role	2026-04-26 10:55:00.27621+02
372	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	profile_role_change	profile	f9755628-51c0-40f9-abb4-371f85908664	{"role": "passenger"}	{"role": "admin"}	Role changed from passenger to admin	2026-04-26 10:55:00.27621+02
508	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	16	\N	{"id": 16, "trip_id": 35, "created_at": "2026-04-27T21:41:36.255208+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 16}	\N	2026-04-27 23:41:36.255208+02
373	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_buses	buses	7	\N	{"id": 7, "capacity": 60, "seat_map": {"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D"], "column_layout": "2,2"}, "amenities": ["Wi-Fi", "AC", "USB Ports", "Entertainment Screen", "Reclining Seats"], "is_active": true, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T08:58:32.770003+00:00", "updated_at": "2026-04-26T08:58:32.770003+00:00", "registration_number": "KWZ 10000"}	\N	2026-04-26 10:58:32.770003+02
374	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_buses	buses	8	\N	{"id": 8, "capacity": 60, "seat_map": {"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D"], "column_layout": "2,2"}, "amenities": ["AC", "Wi-Fi", "USB Ports", "Entertainment Screen", "Reclining Seats", "Snack Service"], "is_active": true, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T08:59:05.612474+00:00", "updated_at": "2026-04-26T08:59:05.612474+00:00", "registration_number": "KWZ 20000"}	\N	2026-04-26 10:59:05.612474+02
375	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_stages	stages	12	\N	{"id": 12, "location": "Ntcheu", "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T08:59:38.325232+00:00", "stage_name": "Ntcheu", "updated_at": "2026-04-26T08:59:38.325232+00:00", "coordinates": null, "is_major_stage": false}	\N	2026-04-26 10:59:38.325232+02
376	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_stages	stages	13	\N	{"id": 13, "location": "Lilongwe", "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:00:03.440946+00:00", "stage_name": "Gateway Mall", "updated_at": "2026-04-26T09:00:03.440946+00:00", "coordinates": null, "is_major_stage": true}	\N	2026-04-26 11:00:03.440946+02
377	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_stages	stages	14	\N	{"id": 14, "location": "Blantyre", "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:00:28.232695+00:00", "stage_name": "Chichiri Mall Terminal", "updated_at": "2026-04-26T09:00:28.232695+00:00", "coordinates": null, "is_major_stage": true}	\N	2026-04-26 11:00:28.232695+02
378	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_routes	routes	9	\N	{"id": 9, "base_fare": 85000.00, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:01:09.628376+00:00", "route_code": "Blantyre - Lilongwe", "updated_at": "2026-04-26T09:01:09.628376+00:00", "origin_stage_id": 14, "intermediate_stops": [{"order": 1, "location": "Ntcheu", "stage_id": 12, "stage_name": "Ntcheu"}], "destination_stage_id": 13}	\N	2026-04-26 11:01:09.628376+02
379	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_routes	routes	10	\N	{"id": 10, "base_fare": 85000.00, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:02:00.418973+00:00", "route_code": "Lilongwe - Blantyre", "updated_at": "2026-04-26T09:02:00.418973+00:00", "origin_stage_id": 13, "intermediate_stops": [{"order": 1, "location": "Ntcheu", "stage_id": 12, "stage_name": "Ntcheu"}], "destination_stage_id": 14}	\N	2026-04-26 11:02:00.418973+02
380	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	183	\N	{"id": 183, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
381	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	184	\N	{"id": 184, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
382	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	185	\N	{"id": 185, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
383	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	186	\N	{"id": 186, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
384	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	187	\N	{"id": 187, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
777	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	277	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
385	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	188	\N	{"id": 188, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-01T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-01T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
386	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	189	\N	{"id": 189, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-02T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-02T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
387	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	190	\N	{"id": 190, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-03T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-03T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
388	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	191	\N	{"id": 191, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-04T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-04T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
389	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	192	\N	{"id": 192, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-05T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-05T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
390	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	193	\N	{"id": 193, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-06T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-06T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
391	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	194	\N	{"id": 194, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-07T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-07T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
392	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	195	\N	{"id": 195, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-08T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-08T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
393	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	196	\N	{"id": 196, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-09T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-09T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
394	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	197	\N	{"id": 197, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-10T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-10T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
395	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	198	\N	{"id": 198, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-11T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-11T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
396	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	199	\N	{"id": 199, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-12T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-12T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
397	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	200	\N	{"id": 200, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-13T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-13T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
398	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	201	\N	{"id": 201, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-14T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-14T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
399	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	202	\N	{"id": 202, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-15T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-15T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
400	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	203	\N	{"id": 203, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-16T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-16T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
401	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	204	\N	{"id": 204, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-17T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-17T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
402	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	205	\N	{"id": 205, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-18T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-18T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
403	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	206	\N	{"id": 206, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-19T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-19T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
404	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	207	\N	{"id": 207, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-20T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-20T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
405	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	208	\N	{"id": 208, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-21T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-21T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
406	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	209	\N	{"id": 209, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-22T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-22T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
407	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	210	\N	{"id": 210, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-23T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-23T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
408	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	211	\N	{"id": 211, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-24T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-24T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
409	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	212	\N	{"id": 212, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-25T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-25T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:03:42.237938+02
410	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	213	\N	{"id": 213, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
411	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	214	\N	{"id": 214, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
412	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	215	\N	{"id": 215, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
413	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	216	\N	{"id": 216, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
414	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	217	\N	{"id": 217, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
415	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	218	\N	{"id": 218, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-01T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-01T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
416	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	219	\N	{"id": 219, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-02T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-02T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
417	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	220	\N	{"id": 220, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-03T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-03T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
418	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	221	\N	{"id": 221, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-04T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-04T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
419	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	222	\N	{"id": 222, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-05T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-05T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
420	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	223	\N	{"id": 223, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-06T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-06T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
421	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	224	\N	{"id": 224, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-07T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-07T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
422	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	225	\N	{"id": 225, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-08T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-08T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
423	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	226	\N	{"id": 226, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-09T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-09T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
424	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	227	\N	{"id": 227, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-10T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-10T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
425	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	228	\N	{"id": 228, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-11T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-11T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
426	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	229	\N	{"id": 229, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-12T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-12T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
427	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	230	\N	{"id": 230, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-13T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-13T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
428	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	231	\N	{"id": 231, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-14T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-14T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
429	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	232	\N	{"id": 232, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-15T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-15T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
430	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	233	\N	{"id": 233, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-16T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-16T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
431	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	234	\N	{"id": 234, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-17T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-17T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
432	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	235	\N	{"id": 235, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-18T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-18T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
433	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	236	\N	{"id": 236, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-19T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-19T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
434	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	237	\N	{"id": 237, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-20T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-20T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
435	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	238	\N	{"id": 238, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-21T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-21T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
436	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	239	\N	{"id": 239, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-22T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-22T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
437	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	240	\N	{"id": 240, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-23T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-23T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
438	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	241	\N	{"id": 241, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-24T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-24T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
439	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	242	\N	{"id": 242, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-25T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-25T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:04:24.648751+02
440	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	243	\N	{"id": 243, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
441	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	244	\N	{"id": 244, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
442	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	245	\N	{"id": 245, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
443	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	246	\N	{"id": 246, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
444	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	247	\N	{"id": 247, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
445	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	248	\N	{"id": 248, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-01T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-01T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
446	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	249	\N	{"id": 249, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-02T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-02T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
447	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	250	\N	{"id": 250, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-03T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-03T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
448	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	251	\N	{"id": 251, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-04T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-04T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
449	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	252	\N	{"id": 252, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-05T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-05T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
450	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	253	\N	{"id": 253, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-06T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-06T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
451	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	254	\N	{"id": 254, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-07T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-07T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
452	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	255	\N	{"id": 255, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-08T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-08T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
453	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	256	\N	{"id": 256, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-09T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-09T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
454	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	257	\N	{"id": 257, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-10T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-10T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
455	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	258	\N	{"id": 258, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-11T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-11T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
456	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	259	\N	{"id": 259, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-12T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-12T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
457	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	260	\N	{"id": 260, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-13T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-13T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
458	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	261	\N	{"id": 261, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-14T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-14T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
459	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	262	\N	{"id": 262, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-15T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-15T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
460	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	263	\N	{"id": 263, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-16T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-16T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
461	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	264	\N	{"id": 264, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-17T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-17T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
462	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	265	\N	{"id": 265, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-18T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-18T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
463	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	266	\N	{"id": 266, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-19T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-19T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
464	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	267	\N	{"id": 267, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-20T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-20T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
465	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	268	\N	{"id": 268, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-21T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-21T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
466	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	269	\N	{"id": 269, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-22T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-22T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
467	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	270	\N	{"id": 270, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-23T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-23T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
468	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	271	\N	{"id": 271, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-24T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-24T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
469	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	272	\N	{"id": 272, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-05-25T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-05-25T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:05:40.108108+02
470	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	273	\N	{"id": 273, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
471	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	274	\N	{"id": 274, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
472	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	275	\N	{"id": 275, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
473	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	276	\N	{"id": 276, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
474	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	277	\N	{"id": 277, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
475	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	278	\N	{"id": 278, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-01T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-01T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
476	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	279	\N	{"id": 279, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-02T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-02T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
477	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	280	\N	{"id": 280, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-03T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-03T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
478	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	281	\N	{"id": 281, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-04T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-04T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
479	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	282	\N	{"id": 282, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-05T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-05T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
480	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	283	\N	{"id": 283, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-06T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-06T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
481	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	284	\N	{"id": 284, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-07T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-07T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
482	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	285	\N	{"id": 285, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-08T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-08T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
483	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	286	\N	{"id": 286, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-09T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-09T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
484	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	287	\N	{"id": 287, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-10T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-10T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
485	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	288	\N	{"id": 288, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-11T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-11T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
486	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	289	\N	{"id": 289, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-12T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-12T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
487	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	290	\N	{"id": 290, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-13T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-13T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
488	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	291	\N	{"id": 291, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-14T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-14T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
489	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	292	\N	{"id": 292, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-15T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-15T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
490	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	293	\N	{"id": 293, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-16T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-16T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
491	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	294	\N	{"id": 294, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-17T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-17T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
492	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	295	\N	{"id": 295, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-18T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-18T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
493	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	296	\N	{"id": 296, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-19T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-19T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
494	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	297	\N	{"id": 297, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-20T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-20T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
495	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	298	\N	{"id": 298, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-21T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-21T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
496	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	299	\N	{"id": 299, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-22T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-22T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
497	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	300	\N	{"id": 300, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-23T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-23T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
498	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	301	\N	{"id": 301, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-24T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-24T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
499	544618e1-b774-4eb4-abf9-c3cb2d99265f	f9755628-51c0-40f9-abb4-371f85908664	insert_trips	trips	302	\N	{"id": 302, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-05-25T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-05-25T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-26 11:06:51.59765+02
506	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	15	\N	{"id": 15, "status": "confirmed", "trip_id": 35, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-27T21:41:35.516129+00:00", "expires_at": "2026-05-27T21:41:35.516129+00:00", "total_fare": 85500.00, "updated_at": "2026-04-27T21:41:35.516129+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-27 23:41:35.516129+02
507	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	16	\N	{"id": 16, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 15, "created_at": "2026-04-27T21:41:35.913572+00:00", "national_id": null, "return_date": null, "ticket_token": "b1c89158-7fb8-4415-8cd5-9bff3eabbbc7", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-10641771", "linked_profile_id": null}	\N	2026-04-27 23:41:35.913572+02
500	\N	f9755628-51c0-40f9-abb4-371f85908664	update_tenants	tenants	544618e1-b774-4eb4-abf9-c3cb2d99265f	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T08:54:59.408617+00:00"}	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 1, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:21:38.548913+00:00"}	Changed: settings	2026-04-26 11:21:38.548913+02
501	\N	f9755628-51c0-40f9-abb4-371f85908664	update_tenants	tenants	544618e1-b774-4eb4-abf9-c3cb2d99265f	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 1, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:21:38.548913+00:00"}	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:21:38.561111+00:00"}	Changed: settings	2026-04-26 11:21:38.561111+02
502	\N	f9755628-51c0-40f9-abb4-371f85908664	update_tenants	tenants	544618e1-b774-4eb4-abf9-c3cb2d99265f	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:21:38.561111+00:00"}	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "return_trip_discount": 10, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:33:07.737537+00:00"}	Changed: settings	2026-04-26 11:33:07.737537+02
503	\N	f9755628-51c0-40f9-abb4-371f85908664	update_tenants	tenants	544618e1-b774-4eb4-abf9-c3cb2d99265f	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "return_trip_discount": 10, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:33:07.737537+00:00"}	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "return_trip_discount": 1, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:33:07.737537+00:00"}	Changed: settings	2026-04-26 11:33:07.737537+02
504	\N	f9755628-51c0-40f9-abb4-371f85908664	update_tenants	tenants	544618e1-b774-4eb4-abf9-c3cb2d99265f	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "return_trip_discount": 1, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:33:07.737537+00:00"}	{"id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "logo": null, "name": "Kwezy Buses", "contact": "0987876482", "settings": {"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"child_discount": 5, "enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "return_trip_discount": 10, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}, "is_active": true, "created_at": "2026-04-26T08:54:59.408617+00:00", "updated_at": "2026-04-26T09:33:11.761338+00:00"}	Changed: settings	2026-04-26 11:33:11.761338+02
509	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	14	\N	{"id": 14, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-27T23:41:35.64214+00:00", "booking_id": 15, "created_at": "2026-04-27T21:41:36.632306+00:00", "payment_method": "mobile_money", "transaction_reference": "fed98991-4430-416d-a186-34b9d23d1f2f"}	\N	2026-04-27 23:41:36.632306+02
510	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_bookings	bookings	16	\N	{"id": 16, "status": "confirmed", "trip_id": 67, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T10:24:32.664612+00:00", "expires_at": "2026-04-30T06:00:00+00:00", "total_fare": 55000.00, "updated_at": "2026-04-28T10:24:32.664612+00:00", "booking_type": "walkin", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b"}	\N	2026-04-28 12:24:32.664612+02
511	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_booking_passengers	booking_passengers	17	\N	{"id": 17, "name": "Natasha Mbamba", "is_child": true, "is_return": false, "booking_id": 16, "created_at": "2026-04-28T10:24:35.357526+00:00", "national_id": "123456", "return_date": null, "ticket_token": "a6fc5794-22ca-43c7-9607-2b3da3be083b", "checked_in_at": null, "checked_in_by": null, "contact_phone": "0881119452", "ticket_number": "TE-C3B084CD", "linked_profile_id": null}	\N	2026-04-28 12:24:35.357526+02
512	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_seat_assignments	seat_assignments	17	\N	{"id": 17, "trip_id": 67, "created_at": "2026-04-28T10:24:36.685813+00:00", "seat_label": "1A", "boarding_rank": 1, "alighting_rank": 3, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 17}	\N	2026-04-28 12:24:36.685813+02
513	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_payments	payments	15	\N	{"id": 15, "amount": 55000.00, "status": "completed", "paid_at": "2026-04-28T10:24:36.831+00:00", "booking_id": 16, "created_at": "2026-04-28T10:24:37.516377+00:00", "payment_method": "cash", "transaction_reference": "DASH-1777371876831"}	\N	2026-04-28 12:24:37.516377+02
514	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	update_bookings	bookings	16	{"id": 16, "status": "confirmed", "trip_id": 67, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T10:24:32.664612+00:00", "expires_at": "2026-04-30T06:00:00+00:00", "total_fare": 55000.00, "updated_at": "2026-04-28T10:24:32.664612+00:00", "booking_type": "walkin", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b"}	{"id": 16, "status": "cancelled", "trip_id": 67, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T10:24:32.664612+00:00", "expires_at": "2026-04-30T06:00:00+00:00", "total_fare": 55000.00, "updated_at": "2026-04-28T10:33:49.950305+00:00", "booking_type": "walkin", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b"}	Changed: status	2026-04-28 12:33:49.950305+02
515	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_refunds	refunds	1	\N	{"id": 1, "reason": "Eyeyrieoers", "status": "pending", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "booking_id": 16, "created_at": "2026-04-28T10:33:50.831972+00:00", "payment_id": 15, "updated_at": "2026-04-28T10:33:50.831972+00:00", "processed_at": null, "refund_amount": 55000.00, "refund_method": "cash", "deduction_amount": 5500.00, "deduction_percent": 10.00, "net_refund_amount": 49500.00, "transaction_reference": null}	\N	2026-04-28 12:33:50.831972+02
516	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	update_refunds	refunds	1	{"id": 1, "reason": "Eyeyrieoers", "status": "pending", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "booking_id": 16, "created_at": "2026-04-28T10:33:50.831972+00:00", "payment_id": 15, "updated_at": "2026-04-28T10:33:50.831972+00:00", "processed_at": null, "refund_amount": 55000.00, "refund_method": "cash", "deduction_amount": 5500.00, "deduction_percent": 10.00, "net_refund_amount": 49500.00, "transaction_reference": null}	{"id": 1, "reason": "Eyeyrieoers", "status": "completed", "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "booking_id": 16, "created_at": "2026-04-28T10:33:50.831972+00:00", "payment_id": 15, "updated_at": "2026-04-28T10:53:19.620069+00:00", "processed_at": "2026-04-28T10:53:19.442+00:00", "refund_amount": 55000.00, "refund_method": "cash", "deduction_amount": 5500.00, "deduction_percent": 10.00, "net_refund_amount": 49500.00, "transaction_reference": null}	Changed: status, processed_at	2026-04-28 12:53:19.620069+02
518	665a127e-0619-4505-9538-34df0b6d5f7a	\N	insert_bookings	bookings	18	\N	{"id": 18, "status": "confirmed", "trip_id": 67, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T11:13:51.022504+00:00", "expires_at": "2026-04-30T11:13:51.022504+00:00", "total_fare": 25000.00, "updated_at": "2026-04-28T11:13:51.022504+00:00", "booking_type": "walkin", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b"}	\N	2026-04-28 13:13:51.022504+02
519	\N	\N	insert_payments	payments	16	\N	{"id": 16, "amount": 25000.00, "status": "completed", "paid_at": "2026-04-28T11:13:51.022504+00:00", "booking_id": 18, "created_at": "2026-04-28T11:13:51.022504+00:00", "payment_method": "cash", "transaction_reference": "TEST-REVENUE-1777374831.022504"}	\N	2026-04-28 13:13:51.022504+02
520	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_bookings	bookings	19	\N	{"id": 19, "status": "confirmed", "trip_id": 66, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T12:19:34.523437+00:00", "expires_at": "2026-04-29T06:00:00+00:00", "total_fare": 85000.00, "updated_at": "2026-04-28T12:19:34.523437+00:00", "booking_type": "walkin", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b"}	\N	2026-04-28 14:19:34.523437+02
521	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_booking_passengers	booking_passengers	18	\N	{"id": 18, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 19, "created_at": "2026-04-28T12:19:36.498936+00:00", "national_id": null, "return_date": null, "ticket_token": "74eec408-f517-479f-8eb0-18777b235bae", "checked_in_at": null, "checked_in_by": null, "contact_phone": "0885705304", "ticket_number": "TE-3AC9FD97", "linked_profile_id": null}	\N	2026-04-28 14:19:36.498936+02
522	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_seat_assignments	seat_assignments	18	\N	{"id": 18, "trip_id": 66, "created_at": "2026-04-28T12:19:39.1454+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 3, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 18}	\N	2026-04-28 14:19:39.1454+02
523	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_payments	payments	17	\N	{"id": 17, "amount": 85000.00, "status": "completed", "paid_at": "2026-04-28T12:19:39.364+00:00", "booking_id": 19, "created_at": "2026-04-28T12:19:41.185977+00:00", "payment_method": "cash", "transaction_reference": "DASH-1777378779364"}	\N	2026-04-28 14:19:41.185977+02
524	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_trips	trips	303	\N	{"id": 303, "bus_id": 6, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T12:24:19.12221+00:00", "updated_at": "2026-04-28T12:24:19.12221+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-28T17:00:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-28T12:50:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	\N	2026-04-28 14:24:19.12221+02
525	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_bookings	bookings	20	\N	{"id": 20, "status": "confirmed", "trip_id": 303, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T12:26:37.363877+00:00", "expires_at": "2026-04-28T12:50:00+00:00", "total_fare": 100000.00, "updated_at": "2026-04-28T12:26:37.363877+00:00", "booking_type": "walkin", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b"}	\N	2026-04-28 14:26:37.363877+02
526	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_booking_passengers	booking_passengers	19	\N	{"id": 19, "name": "LL 30000", "is_child": false, "is_return": false, "booking_id": 20, "created_at": "2026-04-28T12:26:37.695009+00:00", "national_id": null, "return_date": null, "ticket_token": "9055db66-31e2-4de5-bded-4ba79c72656f", "checked_in_at": null, "checked_in_by": null, "contact_phone": "090909090", "ticket_number": "TE-EB7141FC", "linked_profile_id": null}	\N	2026-04-28 14:26:37.695009+02
527	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_seat_assignments	seat_assignments	19	\N	{"id": 19, "trip_id": 303, "created_at": "2026-04-28T12:26:38.387015+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 19}	\N	2026-04-28 14:26:38.387015+02
528	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_payments	payments	18	\N	{"id": 18, "amount": 100000.00, "status": "completed", "paid_at": "2026-04-28T12:26:38.557+00:00", "booking_id": 20, "created_at": "2026-04-28T12:26:38.786688+00:00", "payment_method": "cash", "transaction_reference": "DASH-1777379198557"}	\N	2026-04-28 14:26:38.786688+02
529	665a127e-0619-4505-9538-34df0b6d5f7a	\N	delete_bookings	bookings	18	{"id": 18, "status": "confirmed", "trip_id": 67, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T11:13:51.022504+00:00", "expires_at": "2026-04-30T11:13:51.022504+00:00", "total_fare": 25000.00, "updated_at": "2026-04-28T11:13:51.022504+00:00", "booking_type": "walkin", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b"}	\N	\N	2026-04-28 14:55:38.02683+02
530	\N	\N	delete_payments	payments	16	{"id": 16, "amount": 25000.00, "status": "completed", "paid_at": "2026-04-28T11:13:51.022504+00:00", "booking_id": 18, "created_at": "2026-04-28T11:13:51.022504+00:00", "payment_method": "cash", "transaction_reference": "TEST-REVENUE-1777374831.022504"}	\N	\N	2026-04-28 14:55:38.02683+02
531	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	1	{"id": 1, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-23T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-23T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 1, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-23T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-23T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
532	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	2	{"id": 2, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-24T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-24T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 2, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-24T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-24T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
533	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	3	{"id": 3, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-25T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-25T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 3, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-25T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-25T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
655	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_reschedules	booking_reschedules	1	\N	{"id": 1, "reason": "tyty", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "booking_id": 15, "created_at": "2026-04-29T07:23:32.799937+00:00", "new_trip_id": 38, "old_trip_id": 35, "rescheduled_by_profile_id": null}	\N	2026-04-29 09:23:32.799937+02
534	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	4	{"id": 4, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-26T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 4, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-26T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
535	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	5	{"id": 5, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-27T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 5, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-27T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
536	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	6	{"id": 6, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-28T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 6, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-28T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
537	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	31	{"id": 31, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-23T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-23T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 31, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-23T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-23T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
538	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	32	{"id": 32, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-24T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-24T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 32, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-24T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-24T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
539	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	33	{"id": 33, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-25T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-25T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 33, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-25T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-25T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
540	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	34	{"id": 34, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 34, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
541	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	35	{"id": 35, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 35, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
542	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	36	{"id": 36, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 36, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
543	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	37	{"id": 37, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 37, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
544	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	61	{"id": 61, "bus_id": 3, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T12:37:21.20186+00:00", "updated_at": "2026-04-24T12:37:21.20186+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-25T19:43:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-25T18:41:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 61, "bus_id": 3, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T12:37:21.20186+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-25T19:43:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-25T18:41:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
545	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	63	{"id": 63, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 63, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
546	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	64	{"id": 64, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 64, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
547	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	65	{"id": 65, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 65, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
548	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	66	{"id": 66, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 66, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
549	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	93	{"id": 93, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-26T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 93, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-26T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
550	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	94	{"id": 94, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-27T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 94, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-27T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
551	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	95	{"id": 95, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-28T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 95, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-28T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
552	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	123	{"id": 123, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 123, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
553	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	124	{"id": 124, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 124, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
554	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	125	{"id": 125, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 125, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
555	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	126	{"id": 126, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 126, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
556	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	153	{"id": 153, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 153, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
557	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	154	{"id": 154, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 154, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
558	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	155	{"id": 155, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 155, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
559	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	183	{"id": 183, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 183, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
560	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	184	{"id": 184, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 184, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
561	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	185	{"id": 185, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 185, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
562	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	186	{"id": 186, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 186, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
563	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	213	{"id": 213, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 213, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
564	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	214	{"id": 214, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 214, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
565	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	215	{"id": 215, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 215, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
566	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	216	{"id": 216, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 216, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
567	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	243	{"id": 243, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 243, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
568	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	244	{"id": 244, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 244, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
569	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	245	{"id": 245, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 245, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
570	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	273	{"id": 273, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 273, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
571	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	274	{"id": 274, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 274, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
572	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	275	{"id": 275, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 275, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
573	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	303	{"id": 303, "bus_id": 6, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T12:24:19.12221+00:00", "updated_at": "2026-04-28T12:24:19.12221+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-28T17:00:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-28T12:50:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 303, "bus_id": 6, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T12:24:19.12221+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-28T17:00:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-28T12:50:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
574	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	61	{"id": 61, "bus_id": 3, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T12:37:21.20186+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-25T19:43:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-25T18:41:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 61, "bus_id": 3, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T12:37:21.20186+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-25T19:43:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-25T18:41:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
575	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	1	{"id": 1, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-23T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-23T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 1, "bus_id": 1, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-23T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-23T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
576	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	2	{"id": 2, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-24T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-24T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 2, "bus_id": 1, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-24T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-24T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
577	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	3	{"id": 3, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-25T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-25T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 3, "bus_id": 1, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-25T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-25T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
578	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	4	{"id": 4, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-26T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 4, "bus_id": 1, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-26T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
579	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	5	{"id": 5, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-27T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 5, "bus_id": 1, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-27T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
580	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	6	{"id": 6, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-28T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 6, "bus_id": 1, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-28T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
581	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	31	{"id": 31, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-23T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-23T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 31, "bus_id": 2, "status": "completed", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-23T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-23T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
582	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	32	{"id": 32, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-24T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-24T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 32, "bus_id": 2, "status": "completed", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-24T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-24T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
583	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	303	{"id": 303, "bus_id": 6, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T12:24:19.12221+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-28T17:00:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-28T12:50:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 303, "bus_id": 6, "status": "completed", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-28T12:24:19.12221+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": null, "arrival_datetime": "2026-04-28T17:00:00+00:00", "boarding_stage_id": null, "alighting_stage_id": null, "departure_datetime": "2026-04-28T12:50:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
584	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	33	{"id": 33, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-25T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-25T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 33, "bus_id": 2, "status": "completed", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-25T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-25T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
585	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	34	{"id": 34, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 34, "bus_id": 2, "status": "completed", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
586	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	35	{"id": 35, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 35, "bus_id": 2, "status": "completed", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
587	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	36	{"id": 36, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 36, "bus_id": 2, "status": "completed", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
588	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	63	{"id": 63, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 63, "bus_id": 4, "status": "completed", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
589	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	64	{"id": 64, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 64, "bus_id": 4, "status": "completed", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
590	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	65	{"id": 65, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 65, "bus_id": 4, "status": "completed", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
591	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	93	{"id": 93, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-26T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 93, "bus_id": 4, "status": "completed", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-26T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-26T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
592	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	94	{"id": 94, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-27T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 94, "bus_id": 4, "status": "completed", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-27T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-27T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
593	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	95	{"id": 95, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-28T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 95, "bus_id": 4, "status": "completed", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-28T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-28T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
594	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	123	{"id": 123, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 123, "bus_id": 5, "status": "completed", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-26T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
595	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	124	{"id": 124, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 124, "bus_id": 5, "status": "completed", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-27T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
596	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	125	{"id": 125, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 125, "bus_id": 5, "status": "completed", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-28T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
597	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	153	{"id": 153, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 153, "bus_id": 5, "status": "completed", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-26T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-26T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
598	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	154	{"id": 154, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 154, "bus_id": 5, "status": "completed", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-27T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-27T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
599	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	155	{"id": 155, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 155, "bus_id": 5, "status": "completed", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-28T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-28T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
600	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	183	{"id": 183, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 183, "bus_id": 7, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
601	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	184	{"id": 184, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 184, "bus_id": 7, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
602	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	185	{"id": 185, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 185, "bus_id": 7, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
603	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	213	{"id": 213, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 213, "bus_id": 8, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
604	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	214	{"id": 214, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 214, "bus_id": 8, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
605	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	215	{"id": 215, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 215, "bus_id": 8, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
606	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	243	{"id": 243, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 243, "bus_id": 8, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
607	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	244	{"id": 244, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 244, "bus_id": 8, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
608	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	245	{"id": 245, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 245, "bus_id": 8, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
609	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	273	{"id": 273, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 273, "bus_id": 7, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-26T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-26T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
610	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	274	{"id": 274, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 274, "bus_id": 7, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-27T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-27T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
611	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	275	{"id": 275, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 275, "bus_id": 7, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-28T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-28T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-29 09:18:33.763091+02
612	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	61	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
613	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	37	\N	\N	Auto changed from scheduled to active	2026-04-29 09:18:33.763091+02
614	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	66	\N	\N	Auto changed from scheduled to active	2026-04-29 09:18:33.763091+02
615	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	126	\N	\N	Auto changed from scheduled to active	2026-04-29 09:18:33.763091+02
616	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	186	\N	\N	Auto changed from scheduled to active	2026-04-29 09:18:33.763091+02
617	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	216	\N	\N	Auto changed from scheduled to active	2026-04-29 09:18:33.763091+02
618	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	1	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
619	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	2	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
620	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	3	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
621	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	4	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
622	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	5	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
623	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	6	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
624	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	31	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
625	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	32	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
626	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	303	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
627	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	33	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
628	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	34	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
629	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	35	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
630	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	36	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
631	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	63	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
632	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	64	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
633	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	65	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
634	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	93	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
635	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	94	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
636	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	95	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
637	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	123	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
638	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	124	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
639	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	125	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
640	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	153	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
641	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	154	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
642	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	155	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
643	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	183	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
644	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	184	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
645	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	185	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
646	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	213	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
647	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	214	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
648	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	215	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
649	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	243	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
650	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	244	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
651	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	245	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
652	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	273	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
653	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	274	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
654	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	275	\N	\N	Auto changed from completed to completed (past date)	2026-04-29 09:18:33.763091+02
794	\N	\N	insert_seat_assignments	seat_assignments	38	\N	{"id": 38, "trip_id": 188, "created_at": "2026-05-01T07:50:57.302155+00:00", "seat_label": "10C", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 37}	\N	2026-05-01 09:50:57.302155+02
656	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	update_bookings	bookings	15	{"id": 15, "status": "confirmed", "trip_id": 35, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-27T21:41:35.516129+00:00", "expires_at": "2026-05-27T21:41:35.516129+00:00", "total_fare": 85500.00, "updated_at": "2026-04-27T21:41:35.516129+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 15, "status": "confirmed", "trip_id": 38, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-27T21:41:35.516129+00:00", "expires_at": "2026-05-27T21:41:35.516129+00:00", "total_fare": 85500.00, "updated_at": "2026-04-29T07:23:33.489457+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 1, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: trip_id, reschedule_count	2026-04-29 09:23:33.489457+02
657	\N	dfd092e2-457f-4887-a196-1c55c2627cda	update_seat_assignments	seat_assignments	16	{"id": 16, "trip_id": 35, "created_at": "2026-04-27T21:41:36.255208+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 16}	{"id": 16, "trip_id": 38, "created_at": "2026-04-27T21:41:36.255208+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 16}	Changed: trip_id	2026-04-29 09:23:34.833579+02
658	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	update_bookings	bookings	14	{"id": 14, "status": "confirmed", "trip_id": 34, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T13:06:15.184226+00:00", "expires_at": "2026-05-24T13:06:15.184226+00:00", "total_fare": 170500.00, "updated_at": "2026-04-24T13:06:15.184226+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 2, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 14, "status": "cancelled", "trip_id": 34, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-24T13:06:15.184226+00:00", "expires_at": "2026-05-24T13:06:15.184226+00:00", "total_fare": 170500.00, "updated_at": "2026-04-29T07:27:21.292114+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 2, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: status	2026-04-29 09:27:21.292114+02
659	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	dfd092e2-457f-4887-a196-1c55c2627cda	insert_refunds	refunds	2	\N	{"id": 2, "reason": "rtrfg", "status": "pending", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "booking_id": 14, "created_at": "2026-04-29T07:27:22.547954+00:00", "payment_id": 13, "updated_at": "2026-04-29T07:27:22.547954+00:00", "processed_at": null, "refund_amount": 170500.00, "refund_method": "mobile_money", "deduction_amount": 17050.00, "deduction_percent": 10.00, "net_refund_amount": 153450.00, "transaction_reference": null}	\N	2026-04-29 09:27:22.547954+02
660	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	47bb28e7-6c61-4564-ab23-ca14e9971210	update_refunds	refunds	2	{"id": 2, "reason": "rtrfg", "status": "pending", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "booking_id": 14, "created_at": "2026-04-29T07:27:22.547954+00:00", "payment_id": 13, "updated_at": "2026-04-29T07:27:22.547954+00:00", "processed_at": null, "refund_amount": 170500.00, "refund_method": "mobile_money", "deduction_amount": 17050.00, "deduction_percent": 10.00, "net_refund_amount": 153450.00, "transaction_reference": null}	{"id": 2, "reason": "rtrfg", "status": "completed", "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "booking_id": 14, "created_at": "2026-04-29T07:27:22.547954+00:00", "payment_id": 13, "updated_at": "2026-04-29T07:41:25.081528+00:00", "processed_at": "2026-04-29T07:41:24.709+00:00", "refund_amount": 170500.00, "refund_method": "mobile_money", "deduction_amount": 17050.00, "deduction_percent": 10.00, "net_refund_amount": 153450.00, "transaction_reference": null}	Changed: status, processed_at	2026-04-29 09:41:25.081528+02
661	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	delete_seat_assignments	seat_assignments	18	{"id": 18, "trip_id": 66, "created_at": "2026-04-28T12:19:39.1454+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 3, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 18}	\N	\N	2026-04-29 11:12:32.375492+02
662	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_seat_assignments	seat_assignments	20	\N	{"id": 20, "trip_id": 67, "created_at": "2026-04-29T09:12:33.597142+00:00", "seat_label": "1B", "boarding_rank": 0, "alighting_rank": 0, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 18}	\N	2026-04-29 11:12:33.597142+02
663	665a127e-0619-4505-9538-34df0b6d5f7a	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_bookings	bookings	21	\N	{"id": 21, "status": "confirmed", "trip_id": 67, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-29T12:01:43.638612+00:00", "expires_at": "2026-04-30T06:00:00+00:00", "total_fare": 340000.00, "updated_at": "2026-04-29T12:01:43.638612+00:00", "booking_type": "walkin", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 4, "original_booking_id": null, "booked_by_profile_id": "e60a8d5b-b935-447a-9cb1-8c0595dc159b"}	\N	2026-04-29 14:01:43.638612+02
664	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_booking_passengers	booking_passengers	20	\N	{"id": 20, "name": "ygygyyt", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "28825e10-5ae9-46d7-ac22-2c606f3596fe", "checked_in_at": null, "checked_in_by": null, "contact_phone": "90009999090", "ticket_number": "TE-C6A28FB6", "linked_profile_id": null}	\N	2026-04-29 14:01:44.20214+02
665	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_booking_passengers	booking_passengers	21	\N	{"id": 21, "name": "ygygyyt - Passenger 2", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "dc74fd78-4135-49b0-bf3c-ea08aa4d0408", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-0FA6D055", "linked_profile_id": null}	\N	2026-04-29 14:01:44.20214+02
666	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_booking_passengers	booking_passengers	22	\N	{"id": 22, "name": "ygygyyt - Passenger 3", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "acc9c8d6-1f9f-44d3-91d6-99abb8935998", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-9DD4AB08", "linked_profile_id": null}	\N	2026-04-29 14:01:44.20214+02
667	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_booking_passengers	booking_passengers	23	\N	{"id": 23, "name": "ygygyyt - Passenger 4", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "db240c2d-baee-43fe-8c65-c76f06274046", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-395E0D88", "linked_profile_id": null}	\N	2026-04-29 14:01:44.20214+02
668	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_seat_assignments	seat_assignments	21	\N	{"id": 21, "trip_id": 67, "created_at": "2026-04-29T12:01:44.882332+00:00", "seat_label": "1B", "boarding_rank": 0, "alighting_rank": 3, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 20}	\N	2026-04-29 14:01:44.882332+02
669	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_seat_assignments	seat_assignments	22	\N	{"id": 22, "trip_id": 67, "created_at": "2026-04-29T12:01:44.882332+00:00", "seat_label": "1C", "boarding_rank": 0, "alighting_rank": 3, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 21}	\N	2026-04-29 14:01:44.882332+02
670	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_seat_assignments	seat_assignments	23	\N	{"id": 23, "trip_id": 67, "created_at": "2026-04-29T12:01:44.882332+00:00", "seat_label": "1D", "boarding_rank": 0, "alighting_rank": 3, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 22}	\N	2026-04-29 14:01:44.882332+02
671	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_seat_assignments	seat_assignments	24	\N	{"id": 24, "trip_id": 67, "created_at": "2026-04-29T12:01:44.882332+00:00", "seat_label": "1E", "boarding_rank": 0, "alighting_rank": 3, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 23}	\N	2026-04-29 14:01:44.882332+02
672	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	insert_payments	payments	19	\N	{"id": 19, "amount": 340000.00, "status": "completed", "paid_at": "2026-04-29T12:01:45.055+00:00", "booking_id": 21, "created_at": "2026-04-29T12:01:45.961674+00:00", "payment_method": "cash", "transaction_reference": "DASH-1777464105055"}	\N	2026-04-29 14:01:45.961674+02
673	544618e1-b774-4eb4-abf9-c3cb2d99265f	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	22	\N	{"id": 22, "status": "confirmed", "trip_id": 246, "route_id": null, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-29T14:14:50.70171+00:00", "expires_at": "2026-05-29T14:14:50.70171+00:00", "total_fare": 170500.00, "updated_at": "2026-04-29T14:14:50.70171+00:00", "booking_type": "online", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 2, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-29 16:14:50.70171+02
674	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	24	\N	{"id": 24, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 22, "created_at": "2026-04-29T14:14:51.145792+00:00", "national_id": null, "return_date": null, "ticket_token": "464af47b-c77c-4a09-98b2-db2fb5ca1f9d", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-601B82F6", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-29 16:14:51.145792+02
675	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	25	\N	{"id": 25, "trip_id": 246, "created_at": "2026-04-29T14:14:51.529675+00:00", "seat_label": "1A", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 24}	\N	2026-04-29 16:14:51.529675+02
676	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	25	\N	{"id": 25, "name": "Vamp2o5 - Passenger 2", "is_child": false, "is_return": false, "booking_id": 22, "created_at": "2026-04-29T14:14:51.867114+00:00", "national_id": null, "return_date": null, "ticket_token": "62cb4fae-4039-42e9-9878-858549cfec8c", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-2AC2F48F", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-29 16:14:51.867114+02
677	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	26	\N	{"id": 26, "trip_id": 246, "created_at": "2026-04-29T14:14:52.185029+00:00", "seat_label": "1B", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 25}	\N	2026-04-29 16:14:52.185029+02
678	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	20	\N	{"id": 20, "amount": 170500.00, "status": "completed", "paid_at": "2026-04-29T16:14:51.897624+00:00", "booking_id": 22, "created_at": "2026-04-29T14:14:52.62387+00:00", "payment_method": "mobile_money", "transaction_reference": "681c526e-8504-44d7-a996-2b30e81ee5db"}	\N	2026-04-29 16:14:52.62387+02
679	\N	\N	insert_profiles	profiles	7f5445c4-4ce4-47c0-961f-e9c33841a1f8	\N	{"id": "7f5445c4-4ce4-47c0-961f-e9c33841a1f8", "role": "passenger", "email": null, "phone": "+265885705304", "full_name": "vampUSSD", "tenant_id": null, "created_at": "2026-04-29T21:14:24.260933+00:00", "updated_at": "2026-04-29T21:14:24.260933+00:00", "national_id": "1234hff4", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": null}	\N	2026-04-29 23:14:24.260933+02
680	\N	\N	update_profiles	profiles	7f5445c4-4ce4-47c0-961f-e9c33841a1f8	{"id": "7f5445c4-4ce4-47c0-961f-e9c33841a1f8", "role": "passenger", "email": null, "phone": "+265885705304", "full_name": "vampUSSD", "tenant_id": null, "created_at": "2026-04-29T21:14:24.260933+00:00", "updated_at": "2026-04-29T21:14:24.260933+00:00", "national_id": "1234hff4", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": null}	{"id": "7f5445c4-4ce4-47c0-961f-e9c33841a1f8", "role": "passenger", "email": null, "phone": "+265885705304", "full_name": "vampUSSD", "tenant_id": null, "created_at": "2026-04-29T21:14:24.260933+00:00", "updated_at": "2026-04-29T21:14:25.007838+00:00", "national_id": "1234hff4", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": "$2y$12$Cdqe35wxMrb8dTtpksgC5OrbWC14c00c/n6.oeShzIPLKuSdtP1CK"}	Changed: payment_pin_hash	2026-04-29 23:14:25.007838+02
681	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	insert_bookings	bookings	23	\N	{"id": 23, "status": "confirmed", "trip_id": 8, "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-29T21:23:35.979525+00:00", "expires_at": "2026-05-29T21:23:35.979525+00:00", "total_fare": 85000.00, "updated_at": "2026-04-29T21:23:35.979525+00:00", "booking_type": "ussd", "booking_token": "049ab20e-d8bc-4d6e-963a-93d966fa4ef3", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-04-29 23:23:35.979525+02
682	\N	\N	insert_booking_passengers	booking_passengers	26	\N	{"id": 26, "name": "vampUSSD", "is_child": false, "is_return": false, "booking_id": 23, "created_at": "2026-04-29T21:23:35.979525+00:00", "national_id": null, "return_date": null, "ticket_token": "bdaf76b7-af0b-4c6a-b17e-e795c98f3ad9", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265885705304", "ticket_number": "TE-67E1A1FF", "linked_profile_id": null}	\N	2026-04-29 23:23:35.979525+02
683	\N	\N	insert_seat_assignments	seat_assignments	27	\N	{"id": 27, "trip_id": 8, "created_at": "2026-04-29T21:23:35.979525+00:00", "seat_label": "10A", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 26}	\N	2026-04-29 23:23:35.979525+02
684	\N	\N	insert_payments	payments	21	\N	{"id": 21, "amount": 85000.00, "status": "completed", "paid_at": "2026-04-29T21:23:35.979525+00:00", "booking_id": 23, "created_at": "2026-04-29T21:23:35.979525+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-D45DFEA5C469"}	\N	2026-04-29 23:23:35.979525+02
685	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	insert_bookings	bookings	24	\N	{"id": 24, "status": "confirmed", "trip_id": 37, "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-29T21:59:35.089507+00:00", "expires_at": "2026-05-29T21:59:35.089507+00:00", "total_fare": 85000.00, "updated_at": "2026-04-29T21:59:35.089507+00:00", "booking_type": "ussd", "booking_token": "65dd0ea1-7c9e-488d-8d55-20c71fd36e0b", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-04-29 23:59:35.089507+02
686	\N	\N	insert_booking_passengers	booking_passengers	27	\N	{"id": 27, "name": "vampUSSD", "is_child": false, "is_return": false, "booking_id": 24, "created_at": "2026-04-29T21:59:35.089507+00:00", "national_id": null, "return_date": null, "ticket_token": "c395d939-803e-49a0-bb5e-d782d08d8fcd", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265885705304", "ticket_number": "TE-AC5BA9ED", "linked_profile_id": null}	\N	2026-04-29 23:59:35.089507+02
687	\N	\N	insert_seat_assignments	seat_assignments	28	\N	{"id": 28, "trip_id": 37, "created_at": "2026-04-29T21:59:35.089507+00:00", "seat_label": "10A", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 27}	\N	2026-04-29 23:59:35.089507+02
688	\N	\N	insert_payments	payments	22	\N	{"id": 22, "amount": 85000.00, "status": "completed", "paid_at": "2026-04-29T21:59:35.089507+00:00", "booking_id": 24, "created_at": "2026-04-29T21:59:35.089507+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-3C05DB3BB92F"}	\N	2026-04-29 23:59:35.089507+02
689	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	insert_bookings	bookings	25	\N	{"id": 25, "status": "confirmed", "trip_id": 216, "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-29T22:06:39.84265+00:00", "expires_at": "2026-05-29T22:06:39.84265+00:00", "total_fare": 85000.00, "updated_at": "2026-04-29T22:06:39.84265+00:00", "booking_type": "ussd", "booking_token": "70a03709-c29f-4f97-b2b3-c323c63a8e2e", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-04-30 00:06:39.84265+02
690	\N	\N	insert_booking_passengers	booking_passengers	28	\N	{"id": 28, "name": "vampUSSD", "is_child": false, "is_return": false, "booking_id": 25, "created_at": "2026-04-29T22:06:39.84265+00:00", "national_id": null, "return_date": null, "ticket_token": "f51ae1cc-d0ed-4812-8138-a8df08f2e8de", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265885705304", "ticket_number": "TE-437B7ACF", "linked_profile_id": null}	\N	2026-04-30 00:06:39.84265+02
691	\N	\N	insert_seat_assignments	seat_assignments	29	\N	{"id": 29, "trip_id": 216, "created_at": "2026-04-29T22:06:39.84265+00:00", "seat_label": "10A", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 28}	\N	2026-04-30 00:06:39.84265+02
692	\N	\N	insert_payments	payments	23	\N	{"id": 23, "amount": 85000.00, "status": "completed", "paid_at": "2026-04-29T22:06:39.84265+00:00", "booking_id": 25, "created_at": "2026-04-29T22:06:39.84265+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-84DE837FCD88"}	\N	2026-04-30 00:06:39.84265+02
693	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	7	{"id": 7, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-29T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 7, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-29T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
694	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	96	{"id": 96, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-29T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 96, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-29T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
695	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	156	{"id": 156, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 156, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
696	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	246	{"id": 246, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 246, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
697	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	276	{"id": 276, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 276, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
698	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	7	{"id": 7, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-29T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 7, "bus_id": 1, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-29T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
699	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	96	{"id": 96, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-29T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 96, "bus_id": 4, "status": "completed", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-29T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
700	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	156	{"id": 156, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 156, "bus_id": 5, "status": "completed", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
701	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	246	{"id": 246, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 246, "bus_id": 8, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
702	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	276	{"id": 276, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 276, "bus_id": 7, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
703	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	37	{"id": 37, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 37, "bus_id": 2, "status": "completed", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
704	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	66	{"id": 66, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 66, "bus_id": 4, "status": "completed", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-29T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
705	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	126	{"id": 126, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 126, "bus_id": 5, "status": "completed", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-29T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-29T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
706	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	186	{"id": 186, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 186, "bus_id": 7, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
707	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	216	{"id": 216, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-29T07:18:33.763091+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 216, "bus_id": 8, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-30T00:05:00.307926+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-29T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-29T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-04-30 02:05:00.307926+02
708	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	7	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
709	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	96	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
710	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	156	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
711	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	246	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
712	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	276	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
713	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	37	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
714	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	66	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
715	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	126	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
716	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	186	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
717	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	system_auto_status_update	trip	216	\N	\N	Auto changed from completed to completed (past date)	2026-04-30 02:05:00.307926+02
718	665a127e-0619-4505-9538-34df0b6d5f7a	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	26	\N	{"id": 26, "status": "confirmed", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:29:05.615367+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-30 11:29:05.615367+02
719	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	29	\N	{"id": 29, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 26, "created_at": "2026-04-30T09:29:06.826975+00:00", "national_id": null, "return_date": null, "ticket_token": "bb8dd9f1-1b53-4dc7-b0ca-7e1b0ce198ff", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-64AB1332", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-30 11:29:06.826975+02
720	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	30	\N	{"id": 30, "trip_id": 72, "created_at": "2026-04-30T09:29:07.506075+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 3, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 29}	\N	2026-04-30 11:29:07.506075+02
721	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	24	\N	{"id": 24, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-30T11:28:47.640378+00:00", "booking_id": 26, "created_at": "2026-04-30T09:29:07.862263+00:00", "payment_method": "mobile_money", "transaction_reference": "34b26e5b-5e43-49c5-9b6d-8c0063f6dbc3"}	\N	2026-04-30 11:29:07.862263+02
730	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	25	\N	{"id": 25, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-30T11:52:54.428601+00:00", "booking_id": 27, "created_at": "2026-04-30T09:53:14.731672+00:00", "payment_method": "mobile_money", "transaction_reference": "cc20e8e1-3e3e-4668-bd01-f9839996a4ab"}	\N	2026-04-30 11:53:14.731672+02
731	544618e1-b774-4eb4-abf9-c3cb2d99265f	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	28	\N	{"id": 28, "status": "confirmed", "trip_id": 218, "route_id": null, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-30T09:56:35.0754+00:00", "expires_at": "2026-05-30T09:56:35.0754+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:56:35.0754+00:00", "booking_type": "online", "booking_token": "175bf4dc-c997-45b3-a71f-cf8cfdb57e5b", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-30 11:56:35.0754+02
722	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_bookings	bookings	26	{"id": 26, "status": "confirmed", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:35:54.129996+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 26, "status": "cancelled", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:36:09.34269+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: status	2026-04-30 11:36:09.34269+02
724	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_bookings	bookings	26	{"id": 26, "status": "cancelled", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:36:09.34269+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 26, "status": "confirmed", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:38:02.110065+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: status	2026-04-30 11:38:02.110065+02
725	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_bookings	bookings	26	{"id": 26, "status": "confirmed", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:38:02.110065+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 26, "status": "cancelled", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:38:30.373515+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: status	2026-04-30 11:38:30.373515+02
726	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_bookings	bookings	26	{"id": 26, "status": "cancelled", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:38:30.373515+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 26, "status": "confirmed", "trip_id": 72, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T09:29:05.615367+00:00", "expires_at": "2026-05-30T09:29:05.615367+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:38:41.669375+00:00", "booking_type": "online", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: status	2026-04-30 11:38:41.669375+02
727	544618e1-b774-4eb4-abf9-c3cb2d99265f	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	27	\N	{"id": 27, "status": "confirmed", "trip_id": 219, "route_id": null, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-30T09:53:13.351555+00:00", "expires_at": "2026-05-30T09:53:13.351555+00:00", "total_fare": 85500.00, "updated_at": "2026-04-30T09:53:13.351555+00:00", "booking_type": "online", "booking_token": "7d16b9fd-402b-4b4d-aa9f-9e7bf457ba23", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-30 11:53:13.351555+02
728	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	30	\N	{"id": 30, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 27, "created_at": "2026-04-30T09:53:13.989504+00:00", "national_id": null, "return_date": null, "ticket_token": "1c9dcaf9-8938-46d9-8788-8c4f2c91a898", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-539CCDE7", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-30 11:53:13.989504+02
729	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	31	\N	{"id": 31, "trip_id": 219, "created_at": "2026-04-30T09:53:14.343482+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 30}	\N	2026-04-30 11:53:14.343482+02
732	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	31	\N	{"id": 31, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 28, "created_at": "2026-04-30T09:56:36.680295+00:00", "national_id": null, "return_date": null, "ticket_token": "68b021f8-8481-4dbe-9e6b-f3a26c29fe25", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-50FE35E9", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-30 11:56:36.680295+02
734	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	26	\N	{"id": 26, "amount": 85500.00, "status": "completed", "paid_at": "2026-04-30T11:56:17.429761+00:00", "booking_id": 28, "created_at": "2026-04-30T09:56:38.053905+00:00", "payment_method": "mobile_money", "transaction_reference": "601f2bac-3874-40d5-8eef-3fdf3dc212f2"}	\N	2026-04-30 11:56:38.053905+02
733	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	32	\N	{"id": 32, "trip_id": 218, "created_at": "2026-04-30T09:56:37.134241+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 31}	\N	2026-04-30 11:56:37.134241+02
735	665a127e-0619-4505-9538-34df0b6d5f7a	dfd092e2-457f-4887-a196-1c55c2627cda	insert_bookings	bookings	29	\N	{"id": 29, "status": "confirmed", "trip_id": 132, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T10:49:29.599305+00:00", "expires_at": "2026-05-30T10:49:29.599305+00:00", "total_fare": 100500.00, "updated_at": "2026-04-30T10:49:29.599305+00:00", "booking_type": "online", "booking_token": "7740428d-d681-403f-b6cf-e960ee90a038", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-30 12:49:29.599305+02
736	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_booking_passengers	booking_passengers	32	\N	{"id": 32, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 29, "created_at": "2026-04-30T10:49:30.032957+00:00", "national_id": null, "return_date": null, "ticket_token": "1ce7a920-fa49-4946-a84f-da7c1122b919", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-2F435526", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	\N	2026-04-30 12:49:30.032957+02
737	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_seat_assignments	seat_assignments	33	\N	{"id": 33, "trip_id": 132, "created_at": "2026-04-30T10:49:30.377872+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 32}	\N	2026-04-30 12:49:30.377872+02
738	\N	dfd092e2-457f-4887-a196-1c55c2627cda	insert_payments	payments	27	\N	{"id": 27, "amount": 100500.00, "status": "completed", "paid_at": "2026-04-30T12:49:29.760164+00:00", "booking_id": 29, "created_at": "2026-04-30T10:49:30.781087+00:00", "payment_method": "mobile_money", "transaction_reference": "252eae62-9f75-43de-a374-f871cb72c2a7"}	\N	2026-04-30 12:49:30.781087+02
739	\N	e60a8d5b-b935-447a-9cb1-8c0595dc159b	update_booking_passengers	booking_passengers	20	{"id": 20, "name": "ygygyyt", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "28825e10-5ae9-46d7-ac22-2c606f3596fe", "checked_in_at": null, "checked_in_by": null, "contact_phone": "90009999090", "ticket_number": "TE-C6A28FB6", "linked_profile_id": null}	{"id": 20, "name": "ygygyyt", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "28825e10-5ae9-46d7-ac22-2c606f3596fe", "checked_in_at": "2026-04-30T18:25:08.525821+00:00", "checked_in_by": "e60a8d5b-b935-447a-9cb1-8c0595dc159b", "contact_phone": "90009999090", "ticket_number": "TE-C6A28FB6", "linked_profile_id": null}	Changed: checked_in_at, checked_in_by	2026-04-30 20:25:08.525821+02
740	\N	f9755628-51c0-40f9-abb4-371f85908664	update_booking_passengers	booking_passengers	23	{"id": 23, "name": "ygygyyt - Passenger 4", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "db240c2d-baee-43fe-8c65-c76f06274046", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-395E0D88", "linked_profile_id": null}	{"id": 23, "name": "ygygyyt - Passenger 4", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "db240c2d-baee-43fe-8c65-c76f06274046", "checked_in_at": "2026-04-30T18:47:56.447397+00:00", "checked_in_by": "f9755628-51c0-40f9-abb4-371f85908664", "contact_phone": null, "ticket_number": "TE-395E0D88", "linked_profile_id": null}	Changed: checked_in_at, checked_in_by	2026-04-30 20:47:56.447397+02
741	\N	f9755628-51c0-40f9-abb4-371f85908664	update_booking_passengers	booking_passengers	21	{"id": 21, "name": "ygygyyt - Passenger 2", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "dc74fd78-4135-49b0-bf3c-ea08aa4d0408", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-0FA6D055", "linked_profile_id": null}	{"id": 21, "name": "ygygyyt - Passenger 2", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "dc74fd78-4135-49b0-bf3c-ea08aa4d0408", "checked_in_at": "2026-04-30T19:37:59.252451+00:00", "checked_in_by": "f9755628-51c0-40f9-abb4-371f85908664", "contact_phone": null, "ticket_number": "TE-0FA6D055", "linked_profile_id": null}	Changed: checked_in_at, checked_in_by	2026-04-30 21:37:59.252451+02
742	\N	f9755628-51c0-40f9-abb4-371f85908664	update_booking_passengers	booking_passengers	22	{"id": 22, "name": "ygygyyt - Passenger 3", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "acc9c8d6-1f9f-44d3-91d6-99abb8935998", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-9DD4AB08", "linked_profile_id": null}	{"id": 22, "name": "ygygyyt - Passenger 3", "is_child": false, "is_return": false, "booking_id": 21, "created_at": "2026-04-29T12:01:44.20214+00:00", "national_id": null, "return_date": null, "ticket_token": "acc9c8d6-1f9f-44d3-91d6-99abb8935998", "checked_in_at": "2026-04-30T20:10:46.821231+00:00", "checked_in_by": "f9755628-51c0-40f9-abb4-371f85908664", "contact_phone": null, "ticket_number": "TE-9DD4AB08", "linked_profile_id": null}	Changed: checked_in_at, checked_in_by	2026-04-30 22:10:46.821231+02
743	\N	\N	insert_profiles	profiles	b4e9b96b-916d-4ada-9ae1-56de0e9726da	\N	{"id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da", "role": "passenger", "email": "fecaja3921@reopst.com", "phone": null, "full_name": "BENJAMIN MWAMBAKULU", "tenant_id": null, "created_at": "2026-04-30T21:25:34.25973+00:00", "updated_at": "2026-04-30T21:25:34.25973+00:00", "national_id": null, "profile_url": "", "supa_auth_id": "d5f230ce-1ab1-45a1-8bbd-5cfe1a4c4877", "payment_pin_hash": null}	\N	2026-04-30 23:25:34.25973+02
744	665a127e-0619-4505-9538-34df0b6d5f7a	b4e9b96b-916d-4ada-9ae1-56de0e9726da	insert_bookings	bookings	30	\N	{"id": 30, "status": "confirmed", "trip_id": 157, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-30T22:18:09.744843+00:00", "expires_at": "2026-05-30T22:18:09.744843+00:00", "total_fare": 100500.00, "updated_at": "2026-04-30T22:18:09.744843+00:00", "booking_type": "online", "booking_token": "1741ac98-d542-4271-a553-8ee430845aad", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da"}	\N	2026-05-01 00:18:09.744843+02
745	\N	b4e9b96b-916d-4ada-9ae1-56de0e9726da	insert_booking_passengers	booking_passengers	33	\N	{"id": 33, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 30, "created_at": "2026-04-30T22:18:10.530633+00:00", "national_id": null, "return_date": null, "ticket_token": "2a97241c-b32f-4db8-a9c7-7db86938aaef", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-C7ABC7F9", "linked_profile_id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da"}	\N	2026-05-01 00:18:10.530633+02
746	\N	b4e9b96b-916d-4ada-9ae1-56de0e9726da	insert_seat_assignments	seat_assignments	34	\N	{"id": 34, "trip_id": 157, "created_at": "2026-04-30T22:18:10.990756+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 33}	\N	2026-05-01 00:18:10.990756+02
747	\N	b4e9b96b-916d-4ada-9ae1-56de0e9726da	insert_payments	payments	28	\N	{"id": 28, "amount": 100500.00, "status": "completed", "paid_at": "2026-05-01T00:18:10.587307+00:00", "booking_id": 30, "created_at": "2026-04-30T22:18:11.347831+00:00", "payment_method": "mobile_money", "transaction_reference": "967b8864-bbd1-4de2-8561-852b6fac4bde"}	\N	2026-05-01 00:18:11.347831+02
748	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	8	{"id": 8, "bus_id": 1, "status": "scheduled", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-04-23T18:51:05.42981+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-30T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 8, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-30T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
749	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	38	{"id": 38, "bus_id": 2, "status": "scheduled", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-04-23T19:02:08.117478+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 38, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
750	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	67	{"id": 67, "bus_id": 4, "status": "scheduled", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-04-26T08:39:45.758516+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 67, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
751	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	97	{"id": 97, "bus_id": 4, "status": "scheduled", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-04-26T08:40:31.871268+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-30T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 97, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-30T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
752	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	127	{"id": 127, "bus_id": 5, "status": "scheduled", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-04-26T08:44:25.218603+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 127, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
753	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	157	{"id": 157, "bus_id": 5, "status": "scheduled", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-04-26T08:45:05.562627+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 157, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
769	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	38	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
770	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	67	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
771	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	97	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
754	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	187	{"id": 187, "bus_id": 7, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-04-26T09:03:42.237938+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 187, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
755	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	217	{"id": 217, "bus_id": 8, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-04-26T09:04:24.648751+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 217, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
756	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	247	{"id": 247, "bus_id": 8, "status": "scheduled", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-04-26T09:05:40.108108+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 247, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
757	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	277	{"id": 277, "bus_id": 7, "status": "scheduled", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-04-26T09:06:51.59765+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 277, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
758	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	8	{"id": 8, "bus_id": 1, "status": "active", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-30T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	{"id": 8, "bus_id": 1, "status": "completed", "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T18:51:05.42981+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 1, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 3, "alighting_stage_id": 2, "departure_datetime": "2026-04-30T11:30:00+00:00", "schedule_master_id": 1, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
759	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	update_trips	trips	38	{"id": 38, "bus_id": 2, "status": "active", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	{"id": 38, "bus_id": 2, "status": "completed", "route_id": 2, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-04-23T19:02:08.117478+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 2, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 2, "alighting_stage_id": 3, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": 2, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
760	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	67	{"id": 67, "bus_id": 4, "status": "active", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 67, "bus_id": 4, "status": "completed", "route_id": 5, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:39:45.758516+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T11:30:00+00:00", "boarding_stage_id": 8, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
772	665a127e-0619-4505-9538-34df0b6d5f7a	\N	system_auto_status_update	trip	127	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
761	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	97	{"id": 97, "bus_id": 4, "status": "active", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-30T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 97, "bus_id": 4, "status": "completed", "route_id": 6, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:40:31.871268+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 4, "arrival_datetime": "2026-04-30T15:40:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 8, "departure_datetime": "2026-04-30T12:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
762	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	127	{"id": 127, "bus_id": 5, "status": "active", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 127, "bus_id": 5, "status": "completed", "route_id": 7, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:44:25.218603+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T14:00:00+00:00", "boarding_stage_id": 7, "alighting_stage_id": 6, "departure_datetime": "2026-04-30T06:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
763	665a127e-0619-4505-9538-34df0b6d5f7a	\N	update_trips	trips	157	{"id": 157, "bus_id": 5, "status": "active", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 157, "bus_id": 5, "status": "completed", "route_id": 8, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-04-26T08:45:05.562627+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 5, "arrival_datetime": "2026-04-30T21:00:00+00:00", "boarding_stage_id": 6, "alighting_stage_id": 7, "departure_datetime": "2026-04-30T15:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
764	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	187	{"id": 187, "bus_id": 7, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 187, "bus_id": 7, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:03:42.237938+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
765	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	217	{"id": 217, "bus_id": 8, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 217, "bus_id": 8, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:04:24.648751+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T10:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T05:30:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
766	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	247	{"id": 247, "bus_id": 8, "status": "active", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 247, "bus_id": 8, "status": "completed", "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:05:40.108108+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 8, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 14, "alighting_stage_id": 13, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
767	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	update_trips	trips	277	{"id": 277, "bus_id": 7, "status": "active", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	{"id": 277, "bus_id": 7, "status": "completed", "route_id": 10, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-04-26T09:06:51.59765+00:00", "updated_at": "2026-05-01T00:05:00.203974+00:00", "original_bus_id": 7, "arrival_datetime": "2026-04-30T15:30:00+00:00", "boarding_stage_id": 13, "alighting_stage_id": 14, "departure_datetime": "2026-04-30T11:00:00+00:00", "schedule_master_id": null, "seat_conflict_warning": false}	Changed: status	2026-05-01 02:05:00.203974+02
768	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	system_auto_status_update	trip	8	\N	\N	Auto changed from completed to completed (past date)	2026-05-01 02:05:00.203974+02
778	\N	\N	insert_profiles	profiles	5fdc80eb-bce9-4363-8a4a-96586aed6811	\N	{"id": "5fdc80eb-bce9-4363-8a4a-96586aed6811", "role": "passenger", "email": null, "phone": "+265986026135", "full_name": "Vamp2o5USSD2", "tenant_id": null, "created_at": "2026-05-01T05:50:10.913129+00:00", "updated_at": "2026-05-01T05:50:10.913129+00:00", "national_id": "gygey78", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": null}	\N	2026-05-01 07:50:10.913129+02
779	\N	\N	update_profiles	profiles	5fdc80eb-bce9-4363-8a4a-96586aed6811	{"id": "5fdc80eb-bce9-4363-8a4a-96586aed6811", "role": "passenger", "email": null, "phone": "+265986026135", "full_name": "Vamp2o5USSD2", "tenant_id": null, "created_at": "2026-05-01T05:50:10.913129+00:00", "updated_at": "2026-05-01T05:50:10.913129+00:00", "national_id": "gygey78", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": null}	{"id": "5fdc80eb-bce9-4363-8a4a-96586aed6811", "role": "passenger", "email": null, "phone": "+265986026135", "full_name": "Vamp2o5USSD2", "tenant_id": null, "created_at": "2026-05-01T05:50:10.913129+00:00", "updated_at": "2026-05-01T05:50:12.987278+00:00", "national_id": "gygey78", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": "$2y$12$9Va8E2kKiYG/KdnfxBRFMOF6A52iHeeRv/dPqMuL7G8jVvGQRlZ72"}	Changed: payment_pin_hash	2026-05-01 07:50:12.987278+02
780	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	\N	insert_bookings	bookings	31	\N	{"id": 31, "status": "confirmed", "trip_id": 9, "route_id": 1, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-05-01T06:42:59.01153+00:00", "expires_at": "2026-05-31T06:42:59.01153+00:00", "total_fare": 85000.00, "updated_at": "2026-05-01T06:42:59.01153+00:00", "booking_type": "ussd", "booking_token": "601589b3-f04d-428b-be2d-f7994f3e392f", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-05-01 08:42:59.01153+02
781	\N	\N	insert_booking_passengers	booking_passengers	34	\N	{"id": 34, "name": "Vamp2o5USSD2", "is_child": false, "is_return": false, "booking_id": 31, "created_at": "2026-05-01T06:42:59.01153+00:00", "national_id": null, "return_date": null, "ticket_token": "72518792-2468-4c9e-a731-4dafec50f321", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265986026135", "ticket_number": "TE-D8AAEDC0", "linked_profile_id": null}	\N	2026-05-01 08:42:59.01153+02
782	\N	\N	insert_seat_assignments	seat_assignments	35	\N	{"id": 35, "trip_id": 9, "created_at": "2026-05-01T06:42:59.01153+00:00", "seat_label": "10A", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 34}	\N	2026-05-01 08:42:59.01153+02
783	\N	\N	insert_payments	payments	29	\N	{"id": 29, "amount": 85000.00, "status": "completed", "paid_at": "2026-05-01T06:42:59.01153+00:00", "booking_id": 31, "created_at": "2026-05-01T06:42:59.01153+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-EBD42F0681D3"}	\N	2026-05-01 08:42:59.01153+02
784	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	insert_bookings	bookings	32	\N	{"id": 32, "status": "confirmed", "trip_id": 188, "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-05-01T06:55:47.336956+00:00", "expires_at": "2026-05-31T06:55:47.336956+00:00", "total_fare": 85000.00, "updated_at": "2026-05-01T06:55:47.336956+00:00", "booking_type": "ussd", "booking_token": "f64788db-0704-4493-8b7a-448197d7c4b6", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-05-01 08:55:47.336956+02
785	\N	\N	insert_booking_passengers	booking_passengers	35	\N	{"id": 35, "name": "Vamp2o5USSD2", "is_child": false, "is_return": false, "booking_id": 32, "created_at": "2026-05-01T06:55:47.336956+00:00", "national_id": null, "return_date": null, "ticket_token": "be2e84a3-f5a7-4a6e-884a-ebc6a46bbfb5", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265986026135", "ticket_number": "TE-74F70EA1", "linked_profile_id": null}	\N	2026-05-01 08:55:47.336956+02
786	\N	\N	insert_seat_assignments	seat_assignments	36	\N	{"id": 36, "trip_id": 188, "created_at": "2026-05-01T06:55:47.336956+00:00", "seat_label": "10A", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 35}	\N	2026-05-01 08:55:47.336956+02
787	\N	\N	insert_payments	payments	30	\N	{"id": 30, "amount": 85000.00, "status": "completed", "paid_at": "2026-05-01T06:55:47.336956+00:00", "booking_id": 32, "created_at": "2026-05-01T06:55:47.336956+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-0C0113DCFC7A"}	\N	2026-05-01 08:55:47.336956+02
788	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	insert_bookings	bookings	33	\N	{"id": 33, "status": "confirmed", "trip_id": 188, "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-05-01T07:47:10.870569+00:00", "expires_at": "2026-05-31T07:47:10.870569+00:00", "total_fare": 85000.00, "updated_at": "2026-05-01T07:47:10.870569+00:00", "booking_type": "ussd", "booking_token": "65947555-7cfe-46bb-8934-ccee2eab07c1", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-05-01 09:47:10.870569+02
789	\N	\N	insert_booking_passengers	booking_passengers	36	\N	{"id": 36, "name": "Vamp2o5USSD2", "is_child": false, "is_return": false, "booking_id": 33, "created_at": "2026-05-01T07:47:10.870569+00:00", "national_id": null, "return_date": null, "ticket_token": "022b43ea-8f06-4ab3-8514-c29c204baac1", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265986026135", "ticket_number": "TE-76266179", "linked_profile_id": null}	\N	2026-05-01 09:47:10.870569+02
790	\N	\N	insert_seat_assignments	seat_assignments	37	\N	{"id": 37, "trip_id": 188, "created_at": "2026-05-01T07:47:10.870569+00:00", "seat_label": "10B", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 36}	\N	2026-05-01 09:47:10.870569+02
791	\N	\N	insert_payments	payments	31	\N	{"id": 31, "amount": 85000.00, "status": "completed", "paid_at": "2026-05-01T07:47:10.870569+00:00", "booking_id": 33, "created_at": "2026-05-01T07:47:10.870569+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-69071871294D"}	\N	2026-05-01 09:47:10.870569+02
792	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	insert_bookings	bookings	34	\N	{"id": 34, "status": "confirmed", "trip_id": 188, "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-05-01T07:50:57.302155+00:00", "expires_at": "2026-05-31T07:50:57.302155+00:00", "total_fare": 85000.00, "updated_at": "2026-05-01T07:50:57.302155+00:00", "booking_type": "ussd", "booking_token": "ad176ebf-5e60-4e0c-b4af-7b7dd7b0e2e6", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-05-01 09:50:57.302155+02
793	\N	\N	insert_booking_passengers	booking_passengers	37	\N	{"id": 37, "name": "Vamp2o5USSD2", "is_child": false, "is_return": false, "booking_id": 34, "created_at": "2026-05-01T07:50:57.302155+00:00", "national_id": null, "return_date": null, "ticket_token": "b78bf53d-f4d9-4641-b890-9152e3be2e34", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265986026135", "ticket_number": "TE-2F94373A", "linked_profile_id": null}	\N	2026-05-01 09:50:57.302155+02
795	\N	\N	insert_payments	payments	32	\N	{"id": 32, "amount": 85000.00, "status": "completed", "paid_at": "2026-05-01T07:50:57.302155+00:00", "booking_id": 34, "created_at": "2026-05-01T07:50:57.302155+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-B380C868DFA6"}	\N	2026-05-01 09:50:57.302155+02
796	\N	\N	insert_profiles	profiles	27e4996d-75c8-40bd-85c5-dc7fc506042c	\N	{"id": "27e4996d-75c8-40bd-85c5-dc7fc506042c", "role": "passenger", "email": null, "phone": "+265997079547", "full_name": "wisdom", "tenant_id": null, "created_at": "2026-05-01T07:53:48.162515+00:00", "updated_at": "2026-05-01T07:53:48.162515+00:00", "national_id": "672644", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": null}	\N	2026-05-01 09:53:48.162515+02
797	\N	\N	update_profiles	profiles	27e4996d-75c8-40bd-85c5-dc7fc506042c	{"id": "27e4996d-75c8-40bd-85c5-dc7fc506042c", "role": "passenger", "email": null, "phone": "+265997079547", "full_name": "wisdom", "tenant_id": null, "created_at": "2026-05-01T07:53:48.162515+00:00", "updated_at": "2026-05-01T07:53:48.162515+00:00", "national_id": "672644", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": null}	{"id": "27e4996d-75c8-40bd-85c5-dc7fc506042c", "role": "passenger", "email": null, "phone": "+265997079547", "full_name": "wisdom", "tenant_id": null, "created_at": "2026-05-01T07:53:48.162515+00:00", "updated_at": "2026-05-01T07:53:49.576557+00:00", "national_id": "672644", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": "$2y$12$ROyV8Bo0QpplLehtVLZGee4IW.aSlesrRaeWy4mp.Z9qKcqIgIFp."}	Changed: payment_pin_hash	2026-05-01 09:53:49.576557+02
798	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	insert_bookings	bookings	35	\N	{"id": 35, "status": "confirmed", "trip_id": 188, "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-05-01T07:56:18.063271+00:00", "expires_at": "2026-05-31T07:56:18.063271+00:00", "total_fare": 85000.00, "updated_at": "2026-05-01T07:56:18.063271+00:00", "booking_type": "ussd", "booking_token": "629ef53b-f3b0-43c4-b17b-9b23d2792a57", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-05-01 09:56:18.063271+02
799	\N	\N	insert_booking_passengers	booking_passengers	38	\N	{"id": 38, "name": "wisdom", "is_child": false, "is_return": false, "booking_id": 35, "created_at": "2026-05-01T07:56:18.063271+00:00", "national_id": null, "return_date": null, "ticket_token": "1914ccaf-5e7a-4a94-8be9-8cb907ce97f0", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265997079547", "ticket_number": "TE-3ECAB68A", "linked_profile_id": null}	\N	2026-05-01 09:56:18.063271+02
800	\N	\N	insert_seat_assignments	seat_assignments	39	\N	{"id": 39, "trip_id": 188, "created_at": "2026-05-01T07:56:18.063271+00:00", "seat_label": "10D", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 38}	\N	2026-05-01 09:56:18.063271+02
801	\N	\N	insert_payments	payments	33	\N	{"id": 33, "amount": 85000.00, "status": "completed", "paid_at": "2026-05-01T07:56:18.063271+00:00", "booking_id": 35, "created_at": "2026-05-01T07:56:18.063271+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-5809785CD307"}	\N	2026-05-01 09:56:18.063271+02
802	\N	\N	insert_profiles	profiles	6e90bdd1-c418-4bfd-bc2c-3f6306ee6bf7	\N	{"id": "6e90bdd1-c418-4bfd-bc2c-3f6306ee6bf7", "role": "passenger", "email": null, "phone": "+265882227954", "full_name": "Lameck", "tenant_id": null, "created_at": "2026-05-01T08:14:43.551451+00:00", "updated_at": "2026-05-01T08:14:43.551451+00:00", "national_id": "64672", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": null}	\N	2026-05-01 10:14:43.551451+02
803	\N	\N	update_profiles	profiles	6e90bdd1-c418-4bfd-bc2c-3f6306ee6bf7	{"id": "6e90bdd1-c418-4bfd-bc2c-3f6306ee6bf7", "role": "passenger", "email": null, "phone": "+265882227954", "full_name": "Lameck", "tenant_id": null, "created_at": "2026-05-01T08:14:43.551451+00:00", "updated_at": "2026-05-01T08:14:43.551451+00:00", "national_id": "64672", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": null}	{"id": "6e90bdd1-c418-4bfd-bc2c-3f6306ee6bf7", "role": "passenger", "email": null, "phone": "+265882227954", "full_name": "Lameck", "tenant_id": null, "created_at": "2026-05-01T08:14:43.551451+00:00", "updated_at": "2026-05-01T08:14:44.750224+00:00", "national_id": "64672", "profile_url": "", "supa_auth_id": null, "payment_pin_hash": "$2y$12$7T9WVE37i8QE2hYN.QHxP.to9Vfkr.EtV8Qn9VYQ3EIA.hbOcr/Rm"}	Changed: payment_pin_hash	2026-05-01 10:14:44.750224+02
804	544618e1-b774-4eb4-abf9-c3cb2d99265f	\N	insert_bookings	bookings	36	\N	{"id": 36, "status": "confirmed", "trip_id": 188, "route_id": 9, "tenant_id": "544618e1-b774-4eb4-abf9-c3cb2d99265f", "created_at": "2026-05-01T08:16:47.520585+00:00", "expires_at": "2026-05-31T08:16:47.520585+00:00", "total_fare": 85000.00, "updated_at": "2026-05-01T08:16:47.520585+00:00", "booking_type": "ussd", "booking_token": "1e617e55-3557-4900-ab71-b44b0c557374", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": null}	\N	2026-05-01 10:16:47.520585+02
805	\N	\N	insert_booking_passengers	booking_passengers	39	\N	{"id": 39, "name": "Lameck", "is_child": false, "is_return": false, "booking_id": 36, "created_at": "2026-05-01T08:16:47.520585+00:00", "national_id": null, "return_date": null, "ticket_token": "c9e882f3-885b-45b2-ba2f-2dcffd8ce68b", "checked_in_at": null, "checked_in_by": null, "contact_phone": "+265882227954", "ticket_number": "TE-84F2C21C", "linked_profile_id": null}	\N	2026-05-01 10:16:47.520585+02
806	\N	\N	insert_seat_assignments	seat_assignments	40	\N	{"id": 40, "trip_id": 188, "created_at": "2026-05-01T08:16:47.520585+00:00", "seat_label": "11A", "boarding_rank": null, "alighting_rank": null, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 39}	\N	2026-05-01 10:16:47.520585+02
807	\N	\N	insert_payments	payments	34	\N	{"id": 34, "amount": 85000.00, "status": "completed", "paid_at": "2026-05-01T08:16:47.520585+00:00", "booking_id": 36, "created_at": "2026-05-01T08:16:47.520585+00:00", "payment_method": "mobile_money", "transaction_reference": "USSD-11655137B61E"}	\N	2026-05-01 10:16:47.520585+02
808	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	b4e9b96b-916d-4ada-9ae1-56de0e9726da	insert_bookings	bookings	37	\N	{"id": 37, "status": "confirmed", "trip_id": 39, "route_id": null, "tenant_id": "6dab27c3-9d15-4e79-a7fe-209cdaee3b40", "created_at": "2026-05-01T08:26:17.261506+00:00", "expires_at": "2026-05-31T08:26:17.261506+00:00", "total_fare": 85500.00, "updated_at": "2026-05-01T08:26:17.261506+00:00", "booking_type": "online", "booking_token": "0e935708-c587-49c5-983f-04837985d1c9", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da"}	\N	2026-05-01 10:26:17.261506+02
809	\N	b4e9b96b-916d-4ada-9ae1-56de0e9726da	insert_booking_passengers	booking_passengers	40	\N	{"id": 40, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 37, "created_at": "2026-05-01T08:26:17.900709+00:00", "national_id": null, "return_date": null, "ticket_token": "b015891d-f391-47b1-b1da-5245efeb9a7a", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-1176AF36", "linked_profile_id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da"}	\N	2026-05-01 10:26:17.900709+02
810	\N	b4e9b96b-916d-4ada-9ae1-56de0e9726da	insert_seat_assignments	seat_assignments	41	\N	{"id": 41, "trip_id": 39, "created_at": "2026-05-01T08:26:18.252865+00:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 40}	\N	2026-05-01 10:26:18.252865+02
811	\N	b4e9b96b-916d-4ada-9ae1-56de0e9726da	insert_payments	payments	35	\N	{"id": 35, "amount": 85500.00, "status": "completed", "paid_at": "2026-05-01T10:25:53.864245+00:00", "booking_id": 37, "created_at": "2026-05-01T08:26:18.566738+00:00", "payment_method": "mobile_money", "transaction_reference": "4ac7d9c8-2405-4c20-be1b-7c368873d5ae"}	\N	2026-05-01 10:26:18.566738+02
812	\N	\N	insert_profiles	profiles	4c79f965-771f-441b-b718-012ea3abc041	\N	{"id": "4c79f965-771f-441b-b718-012ea3abc041", "role": "passenger", "email": "mbambanatasha169@gmail.com", "phone": null, "full_name": "Natasha Mbamba", "tenant_id": null, "created_at": "2026-05-01T14:17:59.359815+02:00", "updated_at": "2026-05-01T14:17:59.359815+02:00", "national_id": null, "profile_url": "", "supa_auth_id": "8989adee-edf7-42da-b734-a120f0032f0b", "payment_pin_hash": null}	\N	2026-05-01 14:17:59.359815+02
813	665a127e-0619-4505-9538-34df0b6d5f7a	4c79f965-771f-441b-b718-012ea3abc041	insert_bookings	bookings	38	\N	{"id": 38, "status": "confirmed", "trip_id": 158, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-05-01T14:30:38.135432+02:00", "expires_at": "2026-05-31T14:30:38.135432+02:00", "total_fare": 100500.00, "updated_at": "2026-05-01T14:30:38.135432+02:00", "booking_type": "online", "booking_token": "f135360f-2ef6-406c-ba46-93381b8ac5cc", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "4c79f965-771f-441b-b718-012ea3abc041"}	\N	2026-05-01 14:30:38.135432+02
814	\N	4c79f965-771f-441b-b718-012ea3abc041	insert_booking_passengers	booking_passengers	41	\N	{"id": 41, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 38, "created_at": "2026-05-01T14:30:38.896771+02:00", "national_id": null, "return_date": null, "ticket_token": "5e5fa59d-dda2-444d-8988-ff089c02354c", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-9BEE2D7A", "linked_profile_id": "4c79f965-771f-441b-b718-012ea3abc041"}	\N	2026-05-01 14:30:38.896771+02
815	\N	4c79f965-771f-441b-b718-012ea3abc041	insert_seat_assignments	seat_assignments	42	\N	{"id": 42, "trip_id": 158, "created_at": "2026-05-01T14:30:39.422928+02:00", "seat_label": "1A", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 41}	\N	2026-05-01 14:30:39.422928+02
816	\N	4c79f965-771f-441b-b718-012ea3abc041	insert_payments	payments	36	\N	{"id": 36, "amount": 100500.00, "status": "completed", "paid_at": "2026-05-01T14:30:38.306714+02:00", "booking_id": 38, "created_at": "2026-05-01T14:30:39.856731+02:00", "payment_method": "mobile_money", "transaction_reference": "b30f7331-6e59-4987-9815-09bc1157bcf7"}	\N	2026-05-01 14:30:39.856731+02
817	665a127e-0619-4505-9538-34df0b6d5f7a	4c79f965-771f-441b-b718-012ea3abc041	insert_bookings	bookings	39	\N	{"id": 39, "status": "confirmed", "trip_id": 158, "route_id": null, "tenant_id": "665a127e-0619-4505-9538-34df0b6d5f7a", "created_at": "2026-05-01T14:32:14.921938+02:00", "expires_at": "2026-05-31T14:32:14.921938+02:00", "total_fare": 100500.00, "updated_at": "2026-05-01T14:32:14.921938+02:00", "booking_type": "online", "booking_token": "e01af25f-fdca-4d71-93aa-f751826fd9ed", "is_open_ticket": false, "reschedule_count": 0, "total_passengers": 1, "original_booking_id": null, "booked_by_profile_id": "4c79f965-771f-441b-b718-012ea3abc041"}	\N	2026-05-01 14:32:14.921938+02
818	\N	4c79f965-771f-441b-b718-012ea3abc041	insert_booking_passengers	booking_passengers	42	\N	{"id": 42, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 39, "created_at": "2026-05-01T14:32:15.619006+02:00", "national_id": null, "return_date": null, "ticket_token": "96d47017-559b-4904-84b9-a6a40666f98b", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-615638B4", "linked_profile_id": "4c79f965-771f-441b-b718-012ea3abc041"}	\N	2026-05-01 14:32:15.619006+02
819	\N	4c79f965-771f-441b-b718-012ea3abc041	insert_seat_assignments	seat_assignments	43	\N	{"id": 43, "trip_id": 158, "created_at": "2026-05-01T14:32:16.187969+02:00", "seat_label": "1B", "boarding_rank": 0, "alighting_rank": 2, "boarding_stage_id": null, "alighting_stage_id": null, "booking_passenger_id": 42}	\N	2026-05-01 14:32:16.187969+02
820	\N	4c79f965-771f-441b-b718-012ea3abc041	insert_payments	payments	37	\N	{"id": 37, "amount": 100500.00, "status": "completed", "paid_at": "2026-05-01T14:32:15.12963+02:00", "booking_id": 39, "created_at": "2026-05-01T14:32:16.682161+02:00", "payment_method": "mobile_money", "transaction_reference": "6d2d039d-3fa2-4e67-8178-37daa69db73a"}	\N	2026-05-01 14:32:16.682161+02
821	\N	\N	update_booking_passengers	booking_passengers	32	{"id": 32, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 29, "created_at": "2026-04-30T12:49:30.032957+02:00", "national_id": null, "return_date": null, "ticket_token": "1ce7a920-fa49-4946-a84f-da7c1122b919", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-2F435526", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 32, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 29, "created_at": "2026-04-30T12:49:30.032957+02:00", "national_id": null, "return_date": null, "ticket_token": "1ce7a920-fa49-4946-a84f-da7c1122b919", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-2F435526", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: name	2026-05-01 16:04:34.828621+02
822	\N	\N	update_booking_passengers	booking_passengers	31	{"id": 31, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 28, "created_at": "2026-04-30T11:56:36.680295+02:00", "national_id": null, "return_date": null, "ticket_token": "68b021f8-8481-4dbe-9e6b-f3a26c29fe25", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-50FE35E9", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 31, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 28, "created_at": "2026-04-30T11:56:36.680295+02:00", "national_id": null, "return_date": null, "ticket_token": "68b021f8-8481-4dbe-9e6b-f3a26c29fe25", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-50FE35E9", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: name	2026-05-01 16:04:34.828621+02
823	\N	\N	update_booking_passengers	booking_passengers	30	{"id": 30, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 27, "created_at": "2026-04-30T11:53:13.989504+02:00", "national_id": null, "return_date": null, "ticket_token": "1c9dcaf9-8938-46d9-8788-8c4f2c91a898", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-539CCDE7", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 30, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 27, "created_at": "2026-04-30T11:53:13.989504+02:00", "national_id": null, "return_date": null, "ticket_token": "1c9dcaf9-8938-46d9-8788-8c4f2c91a898", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-539CCDE7", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: name	2026-05-01 16:04:34.828621+02
824	\N	\N	update_booking_passengers	booking_passengers	29	{"id": 29, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 26, "created_at": "2026-04-30T11:29:06.826975+02:00", "national_id": null, "return_date": null, "ticket_token": "bb8dd9f1-1b53-4dc7-b0ca-7e1b0ce198ff", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-64AB1332", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	{"id": 29, "name": "Vamp2o5", "is_child": false, "is_return": false, "booking_id": 26, "created_at": "2026-04-30T11:29:06.826975+02:00", "national_id": null, "return_date": null, "ticket_token": "bb8dd9f1-1b53-4dc7-b0ca-7e1b0ce198ff", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-64AB1332", "linked_profile_id": "dfd092e2-457f-4887-a196-1c55c2627cda"}	Changed: name	2026-05-01 16:04:34.828621+02
825	\N	\N	update_booking_passengers	booking_passengers	40	{"id": 40, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 37, "created_at": "2026-05-01T10:26:17.900709+02:00", "national_id": null, "return_date": null, "ticket_token": "b015891d-f391-47b1-b1da-5245efeb9a7a", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-1176AF36", "linked_profile_id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da"}	{"id": 40, "name": "BENJAMIN MWAMBAKULU", "is_child": false, "is_return": false, "booking_id": 37, "created_at": "2026-05-01T10:26:17.900709+02:00", "national_id": null, "return_date": null, "ticket_token": "b015891d-f391-47b1-b1da-5245efeb9a7a", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-1176AF36", "linked_profile_id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da"}	Changed: name	2026-05-01 16:04:34.828621+02
826	\N	\N	update_booking_passengers	booking_passengers	33	{"id": 33, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 30, "created_at": "2026-05-01T00:18:10.530633+02:00", "national_id": null, "return_date": null, "ticket_token": "2a97241c-b32f-4db8-a9c7-7db86938aaef", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-C7ABC7F9", "linked_profile_id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da"}	{"id": 33, "name": "BENJAMIN MWAMBAKULU", "is_child": false, "is_return": false, "booking_id": 30, "created_at": "2026-05-01T00:18:10.530633+02:00", "national_id": null, "return_date": null, "ticket_token": "2a97241c-b32f-4db8-a9c7-7db86938aaef", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-C7ABC7F9", "linked_profile_id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da"}	Changed: name	2026-05-01 16:04:34.828621+02
827	\N	\N	update_booking_passengers	booking_passengers	42	{"id": 42, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 39, "created_at": "2026-05-01T14:32:15.619006+02:00", "national_id": null, "return_date": null, "ticket_token": "96d47017-559b-4904-84b9-a6a40666f98b", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-615638B4", "linked_profile_id": "4c79f965-771f-441b-b718-012ea3abc041"}	{"id": 42, "name": "Natasha Mbamba", "is_child": false, "is_return": false, "booking_id": 39, "created_at": "2026-05-01T14:32:15.619006+02:00", "national_id": null, "return_date": null, "ticket_token": "96d47017-559b-4904-84b9-a6a40666f98b", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-615638B4", "linked_profile_id": "4c79f965-771f-441b-b718-012ea3abc041"}	Changed: name	2026-05-01 16:04:34.828621+02
828	\N	\N	update_booking_passengers	booking_passengers	41	{"id": 41, "name": "Passenger 1", "is_child": false, "is_return": false, "booking_id": 38, "created_at": "2026-05-01T14:30:38.896771+02:00", "national_id": null, "return_date": null, "ticket_token": "5e5fa59d-dda2-444d-8988-ff089c02354c", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-9BEE2D7A", "linked_profile_id": "4c79f965-771f-441b-b718-012ea3abc041"}	{"id": 41, "name": "Natasha Mbamba", "is_child": false, "is_return": false, "booking_id": 38, "created_at": "2026-05-01T14:30:38.896771+02:00", "national_id": null, "return_date": null, "ticket_token": "5e5fa59d-dda2-444d-8988-ff089c02354c", "checked_in_at": null, "checked_in_by": null, "contact_phone": null, "ticket_number": "TE-9BEE2D7A", "linked_profile_id": "4c79f965-771f-441b-b718-012ea3abc041"}	Changed: name	2026-05-01 16:04:34.828621+02
829	\N	4c79f965-771f-441b-b718-012ea3abc041	update_profiles	profiles	4c79f965-771f-441b-b718-012ea3abc041	{"id": "4c79f965-771f-441b-b718-012ea3abc041", "role": "passenger", "email": "mbambanatasha169@gmail.com", "phone": null, "full_name": "Natasha Mbamba", "tenant_id": null, "created_at": "2026-05-01T14:17:59.359815+02:00", "updated_at": "2026-05-01T14:17:59.359815+02:00", "national_id": null, "profile_url": "", "supa_auth_id": "8989adee-edf7-42da-b734-a120f0032f0b", "payment_pin_hash": null}	{"id": "4c79f965-771f-441b-b718-012ea3abc041", "role": "passenger", "email": "mbambanatasha169@gmail.com", "phone": "0881119452", "full_name": "Natasha Mbamba", "tenant_id": null, "created_at": "2026-05-01T14:17:59.359815+02:00", "updated_at": "2026-05-01T16:16:44.487235+02:00", "national_id": null, "profile_url": "", "supa_auth_id": "8989adee-edf7-42da-b734-a120f0032f0b", "payment_pin_hash": null}	Changed: phone	2026-05-01 16:16:44.487235+02
830	\N	\N	insert_profiles	profiles	db960897-0cc2-46be-a52d-4d4c803f38b5	\N	{"id": "db960897-0cc2-46be-a52d-4d4c803f38b5", "role": "passenger", "email": "adrianmasiyano@gmail.com", "phone": null, "full_name": "Boi Nado", "tenant_id": null, "created_at": "2026-05-01T17:20:32.1143+02:00", "updated_at": "2026-05-01T17:20:32.1143+02:00", "national_id": null, "profile_url": "", "supa_auth_id": "0ff21024-cf2b-4328-8bb0-e5ae6c4210c0", "payment_pin_hash": null}	\N	2026-05-01 17:20:32.1143+02
831	\N	b4e9b96b-916d-4ada-9ae1-56de0e9726da	update_profiles	profiles	b4e9b96b-916d-4ada-9ae1-56de0e9726da	{"id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da", "role": "passenger", "email": "fecaja3921@reopst.com", "phone": null, "full_name": "BENJAMIN MWAMBAKULU", "tenant_id": null, "created_at": "2026-04-30T23:25:34.25973+02:00", "updated_at": "2026-04-30T23:25:34.25973+02:00", "national_id": null, "profile_url": "", "supa_auth_id": "d5f230ce-1ab1-45a1-8bbd-5cfe1a4c4877", "payment_pin_hash": null}	{"id": "b4e9b96b-916d-4ada-9ae1-56de0e9726da", "role": "passenger", "email": "fecaja3921@reopst.com", "phone": "0885705304", "full_name": "BENJAMIN MWAMBAKULU", "tenant_id": null, "created_at": "2026-04-30T23:25:34.25973+02:00", "updated_at": "2026-05-01T17:27:31.992672+02:00", "national_id": null, "profile_url": "", "supa_auth_id": "d5f230ce-1ab1-45a1-8bbd-5cfe1a4c4877", "payment_pin_hash": null}	Changed: phone	2026-05-01 17:27:31.992672+02
\.


--
-- Data for Name: audit_log_archive; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.audit_log_archive (id, tenant_id, actor_id, action, target_type, target_id, old_value, new_value, changes, created_at) FROM stdin;
\.


--
-- Data for Name: booking_passengers; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.booking_passengers (id, booking_id, name, contact_phone, national_id, is_child, linked_profile_id, created_at, ticket_token, checked_in_at, checked_in_by, ticket_number, is_return, return_date) FROM stdin;
10	10	Vamp2o5	\N	\N	f	\N	2026-04-24 12:11:19.401908+02	aa2c82c6-7141-4080-84fd-d793fdbf4f61	\N	\N	TE-0D7896F4	f	\N
11	11	lameck nsomba	\N	\N	f	\N	2026-04-24 12:11:36.764039+02	e38da37b-f7ea-42cc-b522-84282397fd5c	\N	\N	TE-802FE49F	f	\N
12	12	Vamp2o5	\N	\N	f	\N	2026-04-24 12:14:30.851317+02	1bd666bc-9022-4063-8a28-31ba3697cd57	\N	\N	TE-9BF19690	f	\N
13	13	Vamp2o5	\N	\N	f	\N	2026-04-24 12:29:19.307704+02	92ff3495-b430-4969-9051-70cefba658b3	\N	\N	TE-219D2665	f	\N
14	14	Vamp2o5	\N	\N	f	\N	2026-04-24 15:06:15.753414+02	8dc199d9-354f-4c4f-b49a-ef64ae0a1e00	\N	\N	TE-FF2CFFC2	f	\N
15	14	smile	\N	\N	f	\N	2026-04-24 15:06:16.810963+02	1648c0d3-c681-4583-a94e-98018f225b0c	\N	\N	TE-A343941C	f	\N
16	15	Vamp2o5	\N	\N	f	\N	2026-04-27 23:41:35.913572+02	b1c89158-7fb8-4415-8cd5-9bff3eabbbc7	\N	\N	TE-10641771	f	\N
17	16	Natasha Mbamba	0881119452	123456	t	\N	2026-04-28 12:24:35.357526+02	a6fc5794-22ca-43c7-9607-2b3da3be083b	\N	\N	TE-C3B084CD	f	\N
18	19	Vamp2o5	0885705304	\N	f	\N	2026-04-28 14:19:36.498936+02	74eec408-f517-479f-8eb0-18777b235bae	\N	\N	TE-3AC9FD97	f	\N
19	20	LL 30000	090909090	\N	f	\N	2026-04-28 14:26:37.695009+02	9055db66-31e2-4de5-bded-4ba79c72656f	\N	\N	TE-EB7141FC	f	\N
24	22	Vamp2o5	\N	\N	f	dfd092e2-457f-4887-a196-1c55c2627cda	2026-04-29 16:14:51.145792+02	464af47b-c77c-4a09-98b2-db2fb5ca1f9d	\N	\N	TE-601B82F6	f	\N
25	22	Vamp2o5 - Passenger 2	\N	\N	f	dfd092e2-457f-4887-a196-1c55c2627cda	2026-04-29 16:14:51.867114+02	62cb4fae-4039-42e9-9878-858549cfec8c	\N	\N	TE-2AC2F48F	f	\N
26	23	vampUSSD	+265885705304	\N	f	\N	2026-04-29 23:23:35.979525+02	bdaf76b7-af0b-4c6a-b17e-e795c98f3ad9	\N	\N	TE-67E1A1FF	f	\N
27	24	vampUSSD	+265885705304	\N	f	\N	2026-04-29 23:59:35.089507+02	c395d939-803e-49a0-bb5e-d782d08d8fcd	\N	\N	TE-AC5BA9ED	f	\N
28	25	vampUSSD	+265885705304	\N	f	\N	2026-04-30 00:06:39.84265+02	f51ae1cc-d0ed-4812-8138-a8df08f2e8de	\N	\N	TE-437B7ACF	f	\N
20	21	ygygyyt	90009999090	\N	f	\N	2026-04-29 14:01:44.20214+02	28825e10-5ae9-46d7-ac22-2c606f3596fe	2026-04-30 20:25:08.525821+02	e60a8d5b-b935-447a-9cb1-8c0595dc159b	TE-C6A28FB6	f	\N
23	21	ygygyyt - Passenger 4	\N	\N	f	\N	2026-04-29 14:01:44.20214+02	db240c2d-baee-43fe-8c65-c76f06274046	2026-04-30 20:47:56.447397+02	f9755628-51c0-40f9-abb4-371f85908664	TE-395E0D88	f	\N
21	21	ygygyyt - Passenger 2	\N	\N	f	\N	2026-04-29 14:01:44.20214+02	dc74fd78-4135-49b0-bf3c-ea08aa4d0408	2026-04-30 21:37:59.252451+02	f9755628-51c0-40f9-abb4-371f85908664	TE-0FA6D055	f	\N
22	21	ygygyyt - Passenger 3	\N	\N	f	\N	2026-04-29 14:01:44.20214+02	acc9c8d6-1f9f-44d3-91d6-99abb8935998	2026-04-30 22:10:46.821231+02	f9755628-51c0-40f9-abb4-371f85908664	TE-9DD4AB08	f	\N
34	31	Vamp2o5USSD2	+265986026135	\N	f	\N	2026-05-01 08:42:59.01153+02	72518792-2468-4c9e-a731-4dafec50f321	\N	\N	TE-D8AAEDC0	f	\N
35	32	Vamp2o5USSD2	+265986026135	\N	f	\N	2026-05-01 08:55:47.336956+02	be2e84a3-f5a7-4a6e-884a-ebc6a46bbfb5	\N	\N	TE-74F70EA1	f	\N
36	33	Vamp2o5USSD2	+265986026135	\N	f	\N	2026-05-01 09:47:10.870569+02	022b43ea-8f06-4ab3-8514-c29c204baac1	\N	\N	TE-76266179	f	\N
37	34	Vamp2o5USSD2	+265986026135	\N	f	\N	2026-05-01 09:50:57.302155+02	b78bf53d-f4d9-4641-b890-9152e3be2e34	\N	\N	TE-2F94373A	f	\N
38	35	wisdom	+265997079547	\N	f	\N	2026-05-01 09:56:18.063271+02	1914ccaf-5e7a-4a94-8be9-8cb907ce97f0	\N	\N	TE-3ECAB68A	f	\N
39	36	Lameck	+265882227954	\N	f	\N	2026-05-01 10:16:47.520585+02	c9e882f3-885b-45b2-ba2f-2dcffd8ce68b	\N	\N	TE-84F2C21C	f	\N
32	29	Vamp2o5	\N	\N	f	dfd092e2-457f-4887-a196-1c55c2627cda	2026-04-30 12:49:30.032957+02	1ce7a920-fa49-4946-a84f-da7c1122b919	\N	\N	TE-2F435526	f	\N
31	28	Vamp2o5	\N	\N	f	dfd092e2-457f-4887-a196-1c55c2627cda	2026-04-30 11:56:36.680295+02	68b021f8-8481-4dbe-9e6b-f3a26c29fe25	\N	\N	TE-50FE35E9	f	\N
30	27	Vamp2o5	\N	\N	f	dfd092e2-457f-4887-a196-1c55c2627cda	2026-04-30 11:53:13.989504+02	1c9dcaf9-8938-46d9-8788-8c4f2c91a898	\N	\N	TE-539CCDE7	f	\N
29	26	Vamp2o5	\N	\N	f	dfd092e2-457f-4887-a196-1c55c2627cda	2026-04-30 11:29:06.826975+02	bb8dd9f1-1b53-4dc7-b0ca-7e1b0ce198ff	\N	\N	TE-64AB1332	f	\N
40	37	BENJAMIN MWAMBAKULU	\N	\N	f	b4e9b96b-916d-4ada-9ae1-56de0e9726da	2026-05-01 10:26:17.900709+02	b015891d-f391-47b1-b1da-5245efeb9a7a	\N	\N	TE-1176AF36	f	\N
33	30	BENJAMIN MWAMBAKULU	\N	\N	f	b4e9b96b-916d-4ada-9ae1-56de0e9726da	2026-05-01 00:18:10.530633+02	2a97241c-b32f-4db8-a9c7-7db86938aaef	\N	\N	TE-C7ABC7F9	f	\N
42	39	Natasha Mbamba	\N	\N	f	4c79f965-771f-441b-b718-012ea3abc041	2026-05-01 14:32:15.619006+02	96d47017-559b-4904-84b9-a6a40666f98b	\N	\N	TE-615638B4	f	\N
41	38	Natasha Mbamba	\N	\N	f	4c79f965-771f-441b-b718-012ea3abc041	2026-05-01 14:30:38.896771+02	5e5fa59d-dda2-444d-8988-ff089c02354c	\N	\N	TE-9BEE2D7A	f	\N
\.


--
-- Data for Name: booking_reschedules; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.booking_reschedules (id, tenant_id, booking_id, old_trip_id, new_trip_id, rescheduled_by_profile_id, reason, created_at) FROM stdin;
1	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	15	35	38	\N	tyty	2026-04-29 09:23:32.799937+02
\.


--
-- Data for Name: bookings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.bookings (id, tenant_id, trip_id, booked_by_profile_id, booking_type, total_passengers, total_fare, status, expires_at, reschedule_count, original_booking_id, created_at, updated_at, route_id, is_open_ticket, booking_token) FROM stdin;
10	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	dfd092e2-457f-4887-a196-1c55c2627cda	online	1	85500.00	confirmed	2026-05-24 12:11:18.932848+02	0	\N	2026-04-24 12:11:18.932848+02	2026-04-24 12:11:18.932848+02	\N	f	7e6ca3cd-4569-4329-991c-e5069e909ee9
11	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	33	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	online	1	85500.00	confirmed	2026-05-24 12:11:36.351299+02	0	\N	2026-04-24 12:11:36.351299+02	2026-04-24 12:11:36.351299+02	\N	f	91594124-ccb5-4dca-971e-8f2ac9714d7a
12	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	dfd092e2-457f-4887-a196-1c55c2627cda	online	1	85500.00	confirmed	2026-05-24 12:14:30.114853+02	0	\N	2026-04-24 12:14:30.114853+02	2026-04-24 12:14:30.114853+02	\N	f	b41c70ee-d28a-4ed6-b23d-d0f9edb60b42
13	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	dfd092e2-457f-4887-a196-1c55c2627cda	online	1	85500.00	confirmed	2026-05-24 12:29:18.910607+02	0	\N	2026-04-24 12:29:18.910607+02	2026-04-24 12:29:18.910607+02	\N	f	c50f3426-3681-43e4-b6f5-8796c1858dd4
16	665a127e-0619-4505-9538-34df0b6d5f7a	67	e60a8d5b-b935-447a-9cb1-8c0595dc159b	walkin	1	55000.00	cancelled	2026-04-30 08:00:00+02	0	\N	2026-04-28 12:24:32.664612+02	2026-04-28 12:33:49.950305+02	\N	f	51f22099-df73-4bcb-a991-873ec14c6623
19	665a127e-0619-4505-9538-34df0b6d5f7a	66	e60a8d5b-b935-447a-9cb1-8c0595dc159b	walkin	1	85000.00	confirmed	2026-04-29 08:00:00+02	0	\N	2026-04-28 14:19:34.523437+02	2026-04-28 14:19:34.523437+02	\N	f	16409f7c-6d8c-4565-89e8-8ca43df517f8
20	665a127e-0619-4505-9538-34df0b6d5f7a	303	e60a8d5b-b935-447a-9cb1-8c0595dc159b	walkin	1	100000.00	confirmed	2026-04-28 14:50:00+02	0	\N	2026-04-28 14:26:37.363877+02	2026-04-28 14:26:37.363877+02	\N	f	d5f32078-048b-4a93-90da-6ed683113ea5
15	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	38	dfd092e2-457f-4887-a196-1c55c2627cda	online	1	85500.00	confirmed	2026-05-27 23:41:35.516129+02	1	\N	2026-04-27 23:41:35.516129+02	2026-04-29 09:23:33.489457+02	\N	f	33227804-4b33-4afc-90d0-b71b54a5d45e
14	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	34	dfd092e2-457f-4887-a196-1c55c2627cda	online	2	170500.00	cancelled	2026-05-24 15:06:15.184226+02	0	\N	2026-04-24 15:06:15.184226+02	2026-04-29 09:27:21.292114+02	\N	f	0bd403d9-337f-4175-a1fb-52423ef353b5
21	665a127e-0619-4505-9538-34df0b6d5f7a	67	e60a8d5b-b935-447a-9cb1-8c0595dc159b	walkin	4	340000.00	confirmed	2026-04-30 08:00:00+02	0	\N	2026-04-29 14:01:43.638612+02	2026-04-29 14:01:43.638612+02	\N	f	b17053e5-bf9d-4636-ae74-80a8e8d92b0b
22	544618e1-b774-4eb4-abf9-c3cb2d99265f	246	dfd092e2-457f-4887-a196-1c55c2627cda	online	2	170500.00	confirmed	2026-05-29 16:14:50.70171+02	0	\N	2026-04-29 16:14:50.70171+02	2026-04-29 16:14:50.70171+02	\N	f	a058f2b0-3f13-47b5-8964-cfdbb3f5dc28
23	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	8	\N	ussd	1	85000.00	confirmed	2026-05-29 23:23:35.979525+02	0	\N	2026-04-29 23:23:35.979525+02	2026-04-29 23:23:35.979525+02	1	f	049ab20e-d8bc-4d6e-963a-93d966fa4ef3
24	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	37	\N	ussd	1	85000.00	confirmed	2026-05-29 23:59:35.089507+02	0	\N	2026-04-29 23:59:35.089507+02	2026-04-29 23:59:35.089507+02	2	f	65dd0ea1-7c9e-488d-8d55-20c71fd36e0b
25	544618e1-b774-4eb4-abf9-c3cb2d99265f	216	\N	ussd	1	85000.00	confirmed	2026-05-30 00:06:39.84265+02	0	\N	2026-04-30 00:06:39.84265+02	2026-04-30 00:06:39.84265+02	10	f	70a03709-c29f-4f97-b2b3-c323c63a8e2e
26	665a127e-0619-4505-9538-34df0b6d5f7a	72	dfd092e2-457f-4887-a196-1c55c2627cda	online	1	85500.00	confirmed	2026-05-30 11:29:05.615367+02	0	\N	2026-04-30 11:29:05.615367+02	2026-04-30 11:38:41.669375+02	\N	f	447d3e12-d05a-4625-b7cb-5bda0eccf707
27	544618e1-b774-4eb4-abf9-c3cb2d99265f	219	dfd092e2-457f-4887-a196-1c55c2627cda	online	1	85500.00	confirmed	2026-05-30 11:53:13.351555+02	0	\N	2026-04-30 11:53:13.351555+02	2026-04-30 11:53:13.351555+02	\N	f	7d16b9fd-402b-4b4d-aa9f-9e7bf457ba23
28	544618e1-b774-4eb4-abf9-c3cb2d99265f	218	dfd092e2-457f-4887-a196-1c55c2627cda	online	1	85500.00	confirmed	2026-05-30 11:56:35.0754+02	0	\N	2026-04-30 11:56:35.0754+02	2026-04-30 11:56:35.0754+02	\N	f	175bf4dc-c997-45b3-a71f-cf8cfdb57e5b
29	665a127e-0619-4505-9538-34df0b6d5f7a	132	dfd092e2-457f-4887-a196-1c55c2627cda	online	1	100500.00	confirmed	2026-05-30 12:49:29.599305+02	0	\N	2026-04-30 12:49:29.599305+02	2026-04-30 12:49:29.599305+02	\N	f	7740428d-d681-403f-b6cf-e960ee90a038
30	665a127e-0619-4505-9538-34df0b6d5f7a	157	b4e9b96b-916d-4ada-9ae1-56de0e9726da	online	1	100500.00	confirmed	2026-05-31 00:18:09.744843+02	0	\N	2026-05-01 00:18:09.744843+02	2026-05-01 00:18:09.744843+02	\N	f	1741ac98-d542-4271-a553-8ee430845aad
31	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	9	\N	ussd	1	85000.00	confirmed	2026-05-31 08:42:59.01153+02	0	\N	2026-05-01 08:42:59.01153+02	2026-05-01 08:42:59.01153+02	1	f	601589b3-f04d-428b-be2d-f7994f3e392f
32	544618e1-b774-4eb4-abf9-c3cb2d99265f	188	\N	ussd	1	85000.00	confirmed	2026-05-31 08:55:47.336956+02	0	\N	2026-05-01 08:55:47.336956+02	2026-05-01 08:55:47.336956+02	9	f	f64788db-0704-4493-8b7a-448197d7c4b6
33	544618e1-b774-4eb4-abf9-c3cb2d99265f	188	\N	ussd	1	85000.00	confirmed	2026-05-31 09:47:10.870569+02	0	\N	2026-05-01 09:47:10.870569+02	2026-05-01 09:47:10.870569+02	9	f	65947555-7cfe-46bb-8934-ccee2eab07c1
34	544618e1-b774-4eb4-abf9-c3cb2d99265f	188	\N	ussd	1	85000.00	confirmed	2026-05-31 09:50:57.302155+02	0	\N	2026-05-01 09:50:57.302155+02	2026-05-01 09:50:57.302155+02	9	f	ad176ebf-5e60-4e0c-b4af-7b7dd7b0e2e6
35	544618e1-b774-4eb4-abf9-c3cb2d99265f	188	\N	ussd	1	85000.00	confirmed	2026-05-31 09:56:18.063271+02	0	\N	2026-05-01 09:56:18.063271+02	2026-05-01 09:56:18.063271+02	9	f	629ef53b-f3b0-43c4-b17b-9b23d2792a57
36	544618e1-b774-4eb4-abf9-c3cb2d99265f	188	\N	ussd	1	85000.00	confirmed	2026-05-31 10:16:47.520585+02	0	\N	2026-05-01 10:16:47.520585+02	2026-05-01 10:16:47.520585+02	9	f	1e617e55-3557-4900-ab71-b44b0c557374
37	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	39	b4e9b96b-916d-4ada-9ae1-56de0e9726da	online	1	85500.00	confirmed	2026-05-31 10:26:17.261506+02	0	\N	2026-05-01 10:26:17.261506+02	2026-05-01 10:26:17.261506+02	\N	f	0e935708-c587-49c5-983f-04837985d1c9
38	665a127e-0619-4505-9538-34df0b6d5f7a	158	4c79f965-771f-441b-b718-012ea3abc041	online	1	100500.00	confirmed	2026-05-31 14:30:38.135432+02	0	\N	2026-05-01 14:30:38.135432+02	2026-05-01 14:30:38.135432+02	\N	f	f135360f-2ef6-406c-ba46-93381b8ac5cc
39	665a127e-0619-4505-9538-34df0b6d5f7a	158	4c79f965-771f-441b-b718-012ea3abc041	online	1	100500.00	confirmed	2026-05-31 14:32:14.921938+02	0	\N	2026-05-01 14:32:14.921938+02	2026-05-01 14:32:14.921938+02	\N	f	e01af25f-fdca-4d71-93aa-f751826fd9ed
\.


--
-- Data for Name: buses; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.buses (id, tenant_id, registration_number, capacity, seat_map, is_active, created_at, updated_at, amenities) FROM stdin;
1	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	BLK 6929	72	{"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}, "16A": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 1}, "16B": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 2}, "16C": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 3}, "16D": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 4}, "17A": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 1}, "17B": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 2}, "17C": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 3}, "17D": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 4}, "18A": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 1}, "18B": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 2}, "18C": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 3}, "18D": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D", "16A", "16B", "16C", "16D", "17A", "17B", "17C", "17D", "18A", "18B", "18C", "18D"], "column_layout": "2,2"}	t	2026-04-23 20:47:46.696976+02	2026-04-23 20:47:46.696976+02	["Wi-Fi", "AC"]
2	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	MK 89806	60	{"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D"], "column_layout": "2,2"}	t	2026-04-23 20:53:56.490233+02	2026-04-23 20:53:56.490233+02	["Snack Service"]
3	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	test1234	72	{"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}, "16A": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 1}, "16B": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 2}, "16C": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 3}, "16D": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 4}, "17A": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 1}, "17B": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 2}, "17C": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 3}, "17D": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 4}, "18A": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 1}, "18B": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 2}, "18C": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 3}, "18D": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D", "16A", "16B", "16C", "16D", "17A", "17B", "17C", "17D", "18A", "18B", "18C", "18D"], "column_layout": "2,2"}	t	2026-04-24 14:21:38.48612+02	2026-04-24 14:21:38.48612+02	["Wi-Fi"]
4	665a127e-0619-4505-9538-34df0b6d5f7a	LL 10000	65	{"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "1E": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 5}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "2E": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 5}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "3E": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 5}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "4E": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 5}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "5E": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 5}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "6E": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 5}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "7E": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 5}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "8E": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 5}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "9E": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 5}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "10E": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 5}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "11E": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 5}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "12E": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 5}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "13E": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 5}}, "seats": ["1A", "1B", "1C", "1D", "1E", "2A", "2B", "2C", "2D", "2E", "3A", "3B", "3C", "3D", "3E", "4A", "4B", "4C", "4D", "4E", "5A", "5B", "5C", "5D", "5E", "6A", "6B", "6C", "6D", "6E", "7A", "7B", "7C", "7D", "7E", "8A", "8B", "8C", "8D", "8E", "9A", "9B", "9C", "9D", "9E", "10A", "10B", "10C", "10D", "10E", "11A", "11B", "11C", "11D", "11E", "12A", "12B", "12C", "12D", "12E", "13A", "13B", "13C", "13D", "13E"], "column_layout": "2,3"}	t	2026-04-26 10:21:53.027326+02	2026-04-26 10:21:53.027326+02	["Wi-Fi", "USB Ports"]
5	665a127e-0619-4505-9538-34df0b6d5f7a	LL 20000	72	{"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}, "16A": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 1}, "16B": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 2}, "16C": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 3}, "16D": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 4}, "17A": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 1}, "17B": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 2}, "17C": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 3}, "17D": {"is_active": true, "seat_type": "standard", "row_number": 17, "column_number": 4}, "18A": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 1}, "18B": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 2}, "18C": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 3}, "18D": {"is_active": true, "seat_type": "standard", "row_number": 18, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D", "16A", "16B", "16C", "16D", "17A", "17B", "17C", "17D", "18A", "18B", "18C", "18D"], "column_layout": "2,2"}	t	2026-04-26 10:22:17.71488+02	2026-04-26 10:22:17.71488+02	["Snack Service", "Reclining Seats"]
6	665a127e-0619-4505-9538-34df0b6d5f7a	LL 30000	64	{"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}, "16A": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 1}, "16B": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 2}, "16C": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 3}, "16D": {"is_active": true, "seat_type": "standard", "row_number": 16, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D", "16A", "16B", "16C", "16D"], "column_layout": "2,2"}	t	2026-04-26 10:22:58.4505+02	2026-04-26 10:22:58.4505+02	["Wi-Fi", "Entertainment Screen", "AC", "USB Ports", "Luggage Storage"]
7	544618e1-b774-4eb4-abf9-c3cb2d99265f	KWZ 10000	60	{"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D"], "column_layout": "2,2"}	t	2026-04-26 10:58:32.770003+02	2026-04-26 10:58:32.770003+02	["Wi-Fi", "AC", "USB Ports", "Entertainment Screen", "Reclining Seats"]
8	544618e1-b774-4eb4-abf9-c3cb2d99265f	KWZ 20000	60	{"meta": {"1A": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 1}, "1B": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 2}, "1C": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 3}, "1D": {"is_active": true, "seat_type": "standard", "row_number": 1, "column_number": 4}, "2A": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 1}, "2B": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 2}, "2C": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 3}, "2D": {"is_active": true, "seat_type": "standard", "row_number": 2, "column_number": 4}, "3A": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 1}, "3B": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 2}, "3C": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 3}, "3D": {"is_active": true, "seat_type": "standard", "row_number": 3, "column_number": 4}, "4A": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 1}, "4B": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 2}, "4C": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 3}, "4D": {"is_active": true, "seat_type": "standard", "row_number": 4, "column_number": 4}, "5A": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 1}, "5B": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 2}, "5C": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 3}, "5D": {"is_active": true, "seat_type": "standard", "row_number": 5, "column_number": 4}, "6A": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 1}, "6B": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 2}, "6C": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 3}, "6D": {"is_active": true, "seat_type": "standard", "row_number": 6, "column_number": 4}, "7A": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 1}, "7B": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 2}, "7C": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 3}, "7D": {"is_active": true, "seat_type": "standard", "row_number": 7, "column_number": 4}, "8A": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 1}, "8B": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 2}, "8C": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 3}, "8D": {"is_active": true, "seat_type": "standard", "row_number": 8, "column_number": 4}, "9A": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 1}, "9B": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 2}, "9C": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 3}, "9D": {"is_active": true, "seat_type": "standard", "row_number": 9, "column_number": 4}, "10A": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 1}, "10B": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 2}, "10C": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 3}, "10D": {"is_active": true, "seat_type": "standard", "row_number": 10, "column_number": 4}, "11A": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 1}, "11B": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 2}, "11C": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 3}, "11D": {"is_active": true, "seat_type": "standard", "row_number": 11, "column_number": 4}, "12A": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 1}, "12B": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 2}, "12C": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 3}, "12D": {"is_active": true, "seat_type": "standard", "row_number": 12, "column_number": 4}, "13A": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 1}, "13B": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 2}, "13C": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 3}, "13D": {"is_active": true, "seat_type": "standard", "row_number": 13, "column_number": 4}, "14A": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 1}, "14B": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 2}, "14C": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 3}, "14D": {"is_active": true, "seat_type": "standard", "row_number": 14, "column_number": 4}, "15A": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 1}, "15B": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 2}, "15C": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 3}, "15D": {"is_active": true, "seat_type": "standard", "row_number": 15, "column_number": 4}}, "seats": ["1A", "1B", "1C", "1D", "2A", "2B", "2C", "2D", "3A", "3B", "3C", "3D", "4A", "4B", "4C", "4D", "5A", "5B", "5C", "5D", "6A", "6B", "6C", "6D", "7A", "7B", "7C", "7D", "8A", "8B", "8C", "8D", "9A", "9B", "9C", "9D", "10A", "10B", "10C", "10D", "11A", "11B", "11C", "11D", "12A", "12B", "12C", "12D", "13A", "13B", "13C", "13D", "14A", "14B", "14C", "14D", "15A", "15B", "15C", "15D"], "column_layout": "2,2"}	t	2026-04-26 10:59:05.612474+02	2026-04-26 10:59:05.612474+02	["AC", "Wi-Fi", "USB Ports", "Entertainment Screen", "Reclining Seats", "Snack Service"]
\.


--
-- Data for Name: migrations; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.migrations (id, migration, batch) FROM stdin;
1	2026_05_01_000000_add_ussd_performance_indexes	1
\.


--
-- Data for Name: notifications; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.notifications (id, user_id, title, message, category, is_read, metadata, tenant_id, created_at, profile_id, target_type, trip_id, route_id, sent_by_profile_id, expires_at, updated_at) FROM stdin;
1e07ba6a-8e8a-4572-b15e-66129f020237	\N	Bus Change Notice	Dear Passenger,\\n\\nThe bus for your trip has been upgraded to a newer vehicle with Wi-Fi and better seating.	system	t	{"trip_id": 72, "booking_id": 26, "update_type": "general", "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "is_trip_update": true}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-04-30 15:46:07.522523+02	dfd092e2-457f-4887-a196-1c55c2627cda	trip	\N	\N	\N	\N	2026-04-30 16:06:10.030499+02
324337c4-d537-47f0-87f1-4283face510b	\N	Booking Confirmed ✓	Dear Vamp2o5,\n\nYour booking for **Unknown Route** (Unknown → Unknown) on 05 May 2026, 06:00 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85500.00	booking	t	{"trip_id": 72, "route_id": null, "booking_id": 26, "route_code": "Unknown Route", "total_fare": 85500.00, "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "total_passengers": 1, "departure_datetime": "05 May 2026, 06:00"}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-04-30 11:38:41.669375+02	dfd092e2-457f-4887-a196-1c55c2627cda	user	\N	\N	\N	\N	2026-04-30 11:47:36.370477+02
6906a254-84c0-480d-8eca-acf2a60d9341	\N	Booking Confirmed ✓	Dear Vamp2o5,\n\nYour booking for **Unknown Route** (Unknown → Unknown) on 05 May 2026, 06:00 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85500.00	booking	t	{"trip_id": 72, "route_id": null, "booking_id": 26, "route_code": "Unknown Route", "total_fare": 85500.00, "booking_token": "447d3e12-d05a-4625-b7cb-5bda0eccf707", "total_passengers": 1, "departure_datetime": "05 May 2026, 06:00"}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-04-30 11:38:02.110065+02	dfd092e2-457f-4887-a196-1c55c2627cda	user	\N	\N	\N	\N	2026-04-30 11:47:37.588541+02
6d1fefa3-e2d8-4bad-b882-2f1cf9cbd7c4	\N	Trip Reminder ⏰	Dear Passenger,\n\nThis is a **TEST REMINDER** for demonstration purposes.\n\nYour booking for **Your Route** (? → ?) is scheduled for **05 May 2026, 06:00**.\n\nPlease be at the station 30 minutes early.	reminder	t	{"note": "This is a test reminder for stakeholder demo", "is_test": true, "booking_id": 29, "booking_token": "7740428d-d681-403f-b6cf-e960ee90a038"}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-04-30 15:28:53.597411+02	dfd092e2-457f-4887-a196-1c55c2627cda	user	\N	\N	\N	\N	2026-04-30 16:06:10.685075+02
04d889aa-5fe0-4119-9a7a-4f53ba319dfe	\N	Booking Confirmed ✓	Dear Vamp2o5,\n\nYour booking for **Unknown Route** on 05 May 2026, 06:00 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 100500.00	booking	t	{"trip_id": 132, "route_id": null, "booking_id": 29, "total_fare": 100500.00, "booking_token": "7740428d-d681-403f-b6cf-e960ee90a038", "total_passengers": 1}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-04-30 12:49:29.599305+02	dfd092e2-457f-4887-a196-1c55c2627cda	user	\N	\N	\N	\N	2026-04-30 16:06:13.390116+02
036d227f-321d-4fff-94d4-6fb0cfb53501	\N	Booking Confirmed ✓	Dear Vamp2o5,\n\nYour booking for **Unknown Route** (Unknown → Unknown) on 01 May 2026, 05:30 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85500.00	booking	t	{"trip_id": 218, "route_id": null, "booking_id": 28, "route_code": "Unknown Route", "total_fare": 85500.00, "booking_token": "175bf4dc-c997-45b3-a71f-cf8cfdb57e5b", "total_passengers": 1, "departure_datetime": "01 May 2026, 05:30"}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-04-30 11:56:35.0754+02	dfd092e2-457f-4887-a196-1c55c2627cda	user	\N	\N	\N	\N	2026-04-30 16:06:15.021934+02
dc9aeef8-279d-4c7d-a0c5-5337f191ace1	\N	Booking Confirmed ✓	Dear BENJAMIN MWAMBAKULU,\n\nYour booking for **Unknown Route** on 30 Apr 2026, 15:00 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 100500.00	booking	t	{"trip_id": 157, "route_id": null, "booking_id": 30, "total_fare": 100500.00, "booking_token": "1741ac98-d542-4271-a553-8ee430845aad", "total_passengers": 1}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-05-01 00:18:09.744843+02	b4e9b96b-916d-4ada-9ae1-56de0e9726da	user	\N	\N	\N	\N	2026-05-01 00:18:57.732124+02
a64f1679-537e-41d3-8eb0-e394faf7409d	\N	Booking Confirmed ✓	Dear Valued Passenger,\n\nYour booking for **Blantyre - Lilongwe - Chichiri City Mall → Grand Business Park** on 01 May 2026, 11:30 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85000.00	booking	f	{"trip_id": 9, "route_id": 1, "booking_id": 31, "total_fare": 85000.00, "booking_token": "601589b3-f04d-428b-be2d-f7994f3e392f", "total_passengers": 1}	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2026-05-01 08:42:59.01153+02	\N	user	\N	\N	\N	\N	2026-05-01 08:42:59.01153+02
3320cce7-d852-4169-afce-ddfa961edcd2	\N	Booking Confirmed	TicketEase: Booking confirmed for Vamp2o5USSD2 on 2026-05-01. Provider: Machawi. Ticket: TE-D8AAEDC0. Seat: 10A. Route: Blantyre - Lilongwe. Safe travels!	booking	f	{"route_code": "Blantyre - Lilongwe", "seat_label": "10A", "travel_date": "2026-05-01", "ticket_number": "TE-D8AAEDC0"}	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2026-05-01 08:43:04.031634+02	5fdc80eb-bce9-4363-8a4a-96586aed6811	\N	\N	\N	\N	\N	2026-05-01 08:43:04.031634+02
6171d24b-d7e5-44ab-9870-596e3d11a405	\N	Booking Confirmed ✓	Dear Valued Passenger,\n\nYour booking for **Blantyre - Lilongwe - Chichiri Mall Terminal → Gateway Mall** on 01 May 2026, 05:30 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85000.00	booking	f	{"trip_id": 188, "route_id": 9, "booking_id": 32, "total_fare": 85000.00, "booking_token": "f64788db-0704-4493-8b7a-448197d7c4b6", "total_passengers": 1}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 08:55:47.336956+02	\N	user	\N	\N	\N	\N	2026-05-01 08:55:47.336956+02
8a64fde2-45f6-43be-9426-b12964a179bf	\N	Booking Confirmed	TicketEase: Booking confirmed for Vamp2o5USSD2 on 2026-05-01. Provider: Kwezy Buses. Ticket: TE-74F70EA1. Seat: 10A. Route: Blantyre - Lilongwe. Safe travels!	booking	f	{"route_code": "Blantyre - Lilongwe", "seat_label": "10A", "travel_date": "2026-05-01", "ticket_number": "TE-74F70EA1"}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 08:55:52.337685+02	5fdc80eb-bce9-4363-8a4a-96586aed6811	\N	\N	\N	\N	\N	2026-05-01 08:55:52.337685+02
2d7f0105-b972-42ce-bb38-de6b9e4d2ab1	\N	Trip Reminder ⏰	Dear Passenger,\n\nYour booking for **Blantyre - Lilongwe** (Chichiri City Mall → Grand Business Park) is scheduled for **01 May 2026, 11:30**.\n\nPlease arrive at the station at least 30 minutes early.\n\nPassengers: 1 | Total: MWK 85000.00	reminder	f	{"trip_id": 9, "booking_id": 31, "hours_left": 4, "route_code": "Blantyre - Lilongwe", "booking_token": "601589b3-f04d-428b-be2d-f7994f3e392f", "departure_datetime": "01 May 2026, 11:30"}	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2026-05-01 09:00:00.15912+02	\N	user	\N	\N	\N	\N	2026-05-01 09:00:00.15912+02
6cb16109-5879-4211-9a22-54c2c06f68cf	\N	Booking Confirmed ✓	Dear Valued Passenger,\n\nYour booking for **Blantyre - Lilongwe - Chichiri Mall Terminal → Gateway Mall** on 01 May 2026, 05:30 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85000.00	booking	f	{"trip_id": 188, "route_id": 9, "booking_id": 33, "total_fare": 85000.00, "booking_token": "65947555-7cfe-46bb-8934-ccee2eab07c1", "total_passengers": 1}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 09:47:10.870569+02	\N	user	\N	\N	\N	\N	2026-05-01 09:47:10.870569+02
2a5ec7ff-e6c4-4efc-a88a-f5bbb452c893	\N	Booking Confirmed	TicketEase: Booking confirmed for Vamp2o5USSD2 on 2026-05-01. Provider: Kwezy Buses. Ticket: TE-76266179. Seat: 10B. Route: Blantyre - Lilongwe. Safe travels!	booking	f	{"route_code": "Blantyre - Lilongwe", "seat_label": "10B", "travel_date": "2026-05-01", "ticket_number": "TE-76266179"}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 09:47:14.372371+02	5fdc80eb-bce9-4363-8a4a-96586aed6811	\N	\N	\N	\N	\N	2026-05-01 09:47:14.372371+02
721ce6d2-2bc2-49c6-aabf-cc1c493b6bf1	\N	Booking Confirmed ✓	Dear Valued Passenger,\n\nYour booking for **Blantyre - Lilongwe - Chichiri Mall Terminal → Gateway Mall** on 01 May 2026, 05:30 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85000.00	booking	f	{"trip_id": 188, "route_id": 9, "booking_id": 34, "total_fare": 85000.00, "booking_token": "ad176ebf-5e60-4e0c-b4af-7b7dd7b0e2e6", "total_passengers": 1}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 09:50:57.302155+02	\N	user	\N	\N	\N	\N	2026-05-01 09:50:57.302155+02
81c032d0-1c9d-4f26-82f8-2de92d9d41f1	\N	Booking Confirmed	TicketEase: Booking confirmed for Vamp2o5USSD2 on 2026-05-01. Provider: Kwezy Buses. Ticket: TE-2F94373A. Seat: 10C. Route: Blantyre - Lilongwe. Safe travels!	booking	f	{"route_code": "Blantyre - Lilongwe", "seat_label": "10C", "travel_date": "2026-05-01", "ticket_number": "TE-2F94373A"}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 09:51:00.483863+02	5fdc80eb-bce9-4363-8a4a-96586aed6811	\N	\N	\N	\N	\N	2026-05-01 09:51:00.483863+02
a3adc5ae-eea1-464e-adb8-d806ecc07709	\N	Booking Confirmed ✓	Dear Valued Passenger,\n\nYour booking for **Blantyre - Lilongwe - Chichiri Mall Terminal → Gateway Mall** on 01 May 2026, 05:30 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85000.00	booking	f	{"trip_id": 188, "route_id": 9, "booking_id": 35, "total_fare": 85000.00, "booking_token": "629ef53b-f3b0-43c4-b17b-9b23d2792a57", "total_passengers": 1}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 09:56:18.063271+02	\N	user	\N	\N	\N	\N	2026-05-01 09:56:18.063271+02
49f4db14-3fd0-44fe-a21e-b346480c6896	\N	Booking Confirmed	TicketEase: Booking confirmed for wisdom on 2026-05-01. Provider: Kwezy Buses. Ticket: TE-3ECAB68A. Seat: 10D. Route: Blantyre - Lilongwe. Safe travels!	booking	f	{"route_code": "Blantyre - Lilongwe", "seat_label": "10D", "travel_date": "2026-05-01", "ticket_number": "TE-3ECAB68A"}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 09:56:21.099401+02	27e4996d-75c8-40bd-85c5-dc7fc506042c	\N	\N	\N	\N	\N	2026-05-01 09:56:21.099401+02
9b163930-9e6c-4ca3-b219-710b1522b06f	\N	Booking Confirmed ✓	Dear Valued Passenger,\n\nYour booking for **Blantyre - Lilongwe - Chichiri Mall Terminal → Gateway Mall** on 01 May 2026, 05:30 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85000.00	booking	f	{"trip_id": 188, "route_id": 9, "booking_id": 36, "total_fare": 85000.00, "booking_token": "1e617e55-3557-4900-ab71-b44b0c557374", "total_passengers": 1}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 10:16:47.520585+02	\N	user	\N	\N	\N	\N	2026-05-01 10:16:47.520585+02
2f8aeab7-60b2-4f84-9152-a4bd08cfa1df	\N	Booking Confirmed	TicketEase: Booking confirmed for Lameck on 2026-05-01. Provider: Kwezy Buses. Ticket: TE-84F2C21C. Seat: 11A. Route: Blantyre - Lilongwe. Safe travels!	booking	f	{"route_code": "Blantyre - Lilongwe", "seat_label": "11A", "travel_date": "2026-05-01", "ticket_number": "TE-84F2C21C"}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 10:16:55.620532+02	6e90bdd1-c418-4bfd-bc2c-3f6306ee6bf7	\N	\N	\N	\N	\N	2026-05-01 10:16:55.620532+02
6ae578d7-e9fa-4c40-acd0-83d7295d4c8c	\N	Booking Confirmed ✓	Dear BENJAMIN MWAMBAKULU,\n\nYour booking for **Unknown Route** on 01 May 2026, 05:30 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 85500.00	booking	t	{"trip_id": 39, "route_id": null, "booking_id": 37, "total_fare": 85500.00, "booking_token": "0e935708-c587-49c5-983f-04837985d1c9", "total_passengers": 1}	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2026-05-01 10:26:17.261506+02	b4e9b96b-916d-4ada-9ae1-56de0e9726da	user	\N	\N	\N	\N	2026-05-01 10:27:29.824095+02
c6ac1ea3-ab1d-4a55-bb79-c76f2f9dc442	\N	Booking Confirmed ✓	Dear Natasha Mbamba,\n\nYour booking for **Unknown Route** on 01 May 2026, 17:00 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 100500.00	booking	t	{"trip_id": 158, "route_id": null, "booking_id": 39, "total_fare": 100500.00, "booking_token": "e01af25f-fdca-4d71-93aa-f751826fd9ed", "total_passengers": 1}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-05-01 14:32:14.921938+02	4c79f965-771f-441b-b718-012ea3abc041	user	\N	\N	\N	\N	2026-05-01 14:39:45.534185+02
007804fa-a906-4665-9a15-91686ea20221	\N	Booking Confirmed ✓	Dear Natasha Mbamba,\n\nYour booking for **Unknown Route** on 01 May 2026, 17:00 has been confirmed successfully.\n\nPassengers: 1 | Total: MWK 100500.00	booking	t	{"trip_id": 158, "route_id": null, "booking_id": 38, "total_fare": 100500.00, "booking_token": "f135360f-2ef6-406c-ba46-93381b8ac5cc", "total_passengers": 1}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-05-01 14:30:38.135432+02	4c79f965-771f-441b-b718-012ea3abc041	user	\N	\N	\N	\N	2026-05-01 14:39:48.685821+02
f770329a-3d1d-4368-afbb-2707d0814d16	\N	Trip Reminder ⏰	Dear Passenger,\n\nYour booking for **Your Route** (? → ?) is scheduled for **02 May 2026, 07:30**.\n\nPlease arrive at the station at least 30 minutes early.\n\nPassengers: 1 | Total: MWK 85500.00	reminder	f	{"trip_id": 219, "booking_id": 27, "hours_left": 16, "route_code": null, "booking_token": "7d16b9fd-402b-4b4d-aa9f-9e7bf457ba23", "departure_datetime": "02 May 2026, 07:30"}	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-05-01 15:24:34.372248+02	dfd092e2-457f-4887-a196-1c55c2627cda	user	\N	\N	\N	\N	2026-05-01 15:24:34.372248+02
82fed043-12df-4d97-973f-e34bac597cb4	\N	Trip Reminder ⏰	Dear Natasha Mbamba,\n\nYour booking for **Mzimba - Lilongwe** (Mzuzu Terminal → Gateway Mall) is scheduled for **01 May 2026, 17:00**.\n\nPlease arrive at the station at least 30 minutes early.\n\nPassengers: 1 | Total: MWK 100500.00	reminder	t	{"origin": "Mzuzu Terminal", "trip_id": 158, "booking_id": 39, "hours_left": 1, "route_code": "Mzimba - Lilongwe", "destination": "Gateway Mall", "booking_token": "e01af25f-fdca-4d71-93aa-f751826fd9ed", "departure_datetime": "01 May 2026, 17:00"}	665a127e-0619-4505-9538-34df0b6d5f7a	2026-05-01 15:47:06.953943+02	4c79f965-771f-441b-b718-012ea3abc041	user	\N	\N	\N	\N	2026-05-01 15:47:19.118457+02
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payments (id, booking_id, amount, payment_method, status, transaction_reference, paid_at, created_at) FROM stdin;
9	10	85500.00	mobile_money	completed	2b21c632-41c4-442b-a705-dcc54f6db2e6	2026-04-24 14:11:19.042383+02	2026-04-24 12:11:20.211806+02
10	11	85500.00	mobile_money	completed	a1901e6f-bfd0-4699-9e8f-c45b00ca75f6	2026-04-24 14:11:38.005214+02	2026-04-24 12:11:37.575972+02
11	12	85500.00	mobile_money	completed	f1888113-c752-4dcf-b28d-879bfed61b49	2026-04-24 14:14:30.637555+02	2026-04-24 12:14:31.836127+02
12	13	85500.00	mobile_money	completed	9aaa6a15-9861-4c2d-afdc-bccc240976fb	2026-04-24 14:29:18.967456+02	2026-04-24 12:29:20.127176+02
13	14	170500.00	mobile_money	completed	8e63b737-8fae-402a-811c-e100dd77d077	2026-04-24 17:05:35.445309+02	2026-04-24 15:06:18.157214+02
14	15	85500.00	mobile_money	completed	fed98991-4430-416d-a186-34b9d23d1f2f	2026-04-28 01:41:35.64214+02	2026-04-27 23:41:36.632306+02
15	16	55000.00	cash	completed	DASH-1777371876831	2026-04-28 12:24:36.831+02	2026-04-28 12:24:37.516377+02
17	19	85000.00	cash	completed	DASH-1777378779364	2026-04-28 14:19:39.364+02	2026-04-28 14:19:41.185977+02
18	20	100000.00	cash	completed	DASH-1777379198557	2026-04-28 14:26:38.557+02	2026-04-28 14:26:38.786688+02
19	21	340000.00	cash	completed	DASH-1777464105055	2026-04-29 14:01:45.055+02	2026-04-29 14:01:45.961674+02
20	22	170500.00	mobile_money	completed	681c526e-8504-44d7-a996-2b30e81ee5db	2026-04-29 18:14:51.897624+02	2026-04-29 16:14:52.62387+02
21	23	85000.00	mobile_money	completed	USSD-D45DFEA5C469	2026-04-29 23:23:35.979525+02	2026-04-29 23:23:35.979525+02
22	24	85000.00	mobile_money	completed	USSD-3C05DB3BB92F	2026-04-29 23:59:35.089507+02	2026-04-29 23:59:35.089507+02
23	25	85000.00	mobile_money	completed	USSD-84DE837FCD88	2026-04-30 00:06:39.84265+02	2026-04-30 00:06:39.84265+02
24	26	85500.00	mobile_money	completed	34b26e5b-5e43-49c5-9b6d-8c0063f6dbc3	2026-04-30 13:28:47.640378+02	2026-04-30 11:29:07.862263+02
25	27	85500.00	mobile_money	completed	cc20e8e1-3e3e-4668-bd01-f9839996a4ab	2026-04-30 13:52:54.428601+02	2026-04-30 11:53:14.731672+02
26	28	85500.00	mobile_money	completed	601f2bac-3874-40d5-8eef-3fdf3dc212f2	2026-04-30 13:56:17.429761+02	2026-04-30 11:56:38.053905+02
27	29	100500.00	mobile_money	completed	252eae62-9f75-43de-a374-f871cb72c2a7	2026-04-30 14:49:29.760164+02	2026-04-30 12:49:30.781087+02
28	30	100500.00	mobile_money	completed	967b8864-bbd1-4de2-8561-852b6fac4bde	2026-05-01 02:18:10.587307+02	2026-05-01 00:18:11.347831+02
29	31	85000.00	mobile_money	completed	USSD-EBD42F0681D3	2026-05-01 08:42:59.01153+02	2026-05-01 08:42:59.01153+02
30	32	85000.00	mobile_money	completed	USSD-0C0113DCFC7A	2026-05-01 08:55:47.336956+02	2026-05-01 08:55:47.336956+02
31	33	85000.00	mobile_money	completed	USSD-69071871294D	2026-05-01 09:47:10.870569+02	2026-05-01 09:47:10.870569+02
32	34	85000.00	mobile_money	completed	USSD-B380C868DFA6	2026-05-01 09:50:57.302155+02	2026-05-01 09:50:57.302155+02
33	35	85000.00	mobile_money	completed	USSD-5809785CD307	2026-05-01 09:56:18.063271+02	2026-05-01 09:56:18.063271+02
34	36	85000.00	mobile_money	completed	USSD-11655137B61E	2026-05-01 10:16:47.520585+02	2026-05-01 10:16:47.520585+02
35	37	85500.00	mobile_money	completed	4ac7d9c8-2405-4c20-be1b-7c368873d5ae	2026-05-01 12:25:53.864245+02	2026-05-01 10:26:18.566738+02
36	38	100500.00	mobile_money	completed	b30f7331-6e59-4987-9815-09bc1157bcf7	2026-05-01 14:30:38.306714+02	2026-05-01 14:30:39.856731+02
37	39	100500.00	mobile_money	completed	6d2d039d-3fa2-4e67-8178-37daa69db73a	2026-05-01 14:32:15.12963+02	2026-05-01 14:32:16.682161+02
\.


--
-- Data for Name: profiles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.profiles (supa_auth_id, full_name, phone, national_id, role, tenant_id, created_at, updated_at, id, email, profile_url, payment_pin_hash) FROM stdin;
33b4bcc0-dcfe-4da2-852d-54bfb4897e01	Vamp2o5 Machawi	\N	\N	admin	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2026-04-23 20:46:31.247198+02	2026-04-23 21:00:19.851857+02	47bb28e7-6c61-4564-ab23-ca14e9971210	mwambakulubenjamin2o5@gmail.com	https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/profile-photos/profiles/profile-47bb28e7-6c61-4564-ab23-ca14e9971210-1776970815221.jpg	\N
0fff0cfa-219c-4a6f-8669-489daa2183e2	Tamara	\N	\N	admin	3dce9d0c-181d-4a54-911c-471959d7065d	2026-04-23 21:19:22.989139+02	2026-04-23 21:19:23.494966+02	8231bfd4-c74e-4c83-b231-69a74e5d6f29	gondwetamara557@gmail.com		\N
33c5c85d-9ad1-40b8-a35c-c8792cb5bc2d	lameck nsomba	\N	\N	passenger	\N	2026-04-24 08:26:24.288361+02	2026-04-24 08:26:24.288361+02	a3d20b4f-07ff-474d-81ca-a7b7f884fa76	lamecknsomba1@gmail.com		\N
84d8de5c-282b-45ee-8877-739bc1e9c562	Vamp2o5	\N	\N	super_admin	\N	2026-04-23 20:38:29.208447+02	2026-04-26 10:06:32.333178+02	dfd092e2-457f-4887-a196-1c55c2627cda	bit-023-22@must.ac.mw		\N
f36d71fe-8556-49f1-be0a-8c29862c20ac	Tam Tam Admin	\N	\N	admin	665a127e-0619-4505-9538-34df0b6d5f7a	2026-04-26 10:08:37.895339+02	2026-04-26 10:08:38.488748+02	e60a8d5b-b935-447a-9cb1-8c0595dc159b	yefot32203@hacknapp.com		\N
7083337e-e508-4e1a-b4d8-c6941eed7763	Kwezy Admin	\N	\N	admin	544618e1-b774-4eb4-abf9-c3cb2d99265f	2026-04-26 10:54:59.50937+02	2026-04-26 10:55:00.27621+02	f9755628-51c0-40f9-abb4-371f85908664	jvu8yuy3rs@ruutukf.com		\N
fa14e42d-4a4d-4d90-a86b-3212d001cdcf	smile Minyaliwa	\N	\N	passenger	\N	2026-04-26 22:23:11.494898+02	2026-04-26 22:23:11.494898+02	a0797122-a56d-44f3-827a-f0ff0c183dde	bit-020-22@must.ac.mw		\N
\N	vampUSSD	+265885705304	1234hff4	passenger	\N	2026-04-29 23:14:24.260933+02	2026-04-29 23:14:25.007838+02	7f5445c4-4ce4-47c0-961f-e9c33841a1f8	\N		$2y$12$Cdqe35wxMrb8dTtpksgC5OrbWC14c00c/n6.oeShzIPLKuSdtP1CK
\N	Vamp2o5USSD2	+265986026135	gygey78	passenger	\N	2026-05-01 07:50:10.913129+02	2026-05-01 07:50:12.987278+02	5fdc80eb-bce9-4363-8a4a-96586aed6811	\N		$2y$12$9Va8E2kKiYG/KdnfxBRFMOF6A52iHeeRv/dPqMuL7G8jVvGQRlZ72
\N	wisdom	+265997079547	672644	passenger	\N	2026-05-01 09:53:48.162515+02	2026-05-01 09:53:49.576557+02	27e4996d-75c8-40bd-85c5-dc7fc506042c	\N		$2y$12$ROyV8Bo0QpplLehtVLZGee4IW.aSlesrRaeWy4mp.Z9qKcqIgIFp.
\N	Lameck	+265882227954	64672	passenger	\N	2026-05-01 10:14:43.551451+02	2026-05-01 10:14:44.750224+02	6e90bdd1-c418-4bfd-bc2c-3f6306ee6bf7	\N		$2y$12$7T9WVE37i8QE2hYN.QHxP.to9Vfkr.EtV8Qn9VYQ3EIA.hbOcr/Rm
8989adee-edf7-42da-b734-a120f0032f0b	Natasha Mbamba	0881119452	\N	passenger	\N	2026-05-01 14:17:59.359815+02	2026-05-01 16:16:44.487235+02	4c79f965-771f-441b-b718-012ea3abc041	mbambanatasha169@gmail.com		\N
0ff21024-cf2b-4328-8bb0-e5ae6c4210c0	Boi Nado	\N	\N	passenger	\N	2026-05-01 17:20:32.1143+02	2026-05-01 17:20:32.1143+02	db960897-0cc2-46be-a52d-4d4c803f38b5	adrianmasiyano@gmail.com		\N
d5f230ce-1ab1-45a1-8bbd-5cfe1a4c4877	BENJAMIN MWAMBAKULU	0885705304	\N	passenger	\N	2026-04-30 23:25:34.25973+02	2026-05-01 17:27:31.992672+02	b4e9b96b-916d-4ada-9ae1-56de0e9726da	fecaja3921@reopst.com		\N
\.


--
-- Data for Name: refunds; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.refunds (id, tenant_id, booking_id, payment_id, refund_amount, deduction_percent, status, refund_method, transaction_reference, processed_at, reason, created_at, updated_at) FROM stdin;
1	665a127e-0619-4505-9538-34df0b6d5f7a	16	15	55000.00	10.00	completed	cash	\N	2026-04-28 12:53:19.442+02	Eyeyrieoers	2026-04-28 12:33:50.831972+02	2026-04-28 12:53:19.620069+02
2	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	14	13	170500.00	10.00	completed	mobile_money	\N	2026-04-29 09:41:24.709+02	rtrfg	2026-04-29 09:27:22.547954+02	2026-04-29 09:41:25.081528+02
\.


--
-- Data for Name: role_permissions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.role_permissions (id, role, permissions, description, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: route_fares; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.route_fares (id, tenant_id, route_id, boarding_stage_id, alighting_stage_id, fare_amount, currency, created_at) FROM stdin;
4	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	1	50000	MWK	2026-04-23 20:56:14.007291+02
5	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	3	85000	MWK	2026-04-23 20:56:14.007291+02
6	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	1	3	50000	MWK	2026-04-23 20:56:14.007291+02
7	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	4	5	60000	MWK	2026-04-23 20:59:52.434465+02
8	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	4	2	80000	MWK	2026-04-23 20:59:52.434465+02
9	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	4	1	100000	MWK	2026-04-23 20:59:52.434465+02
10	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	4	3	150000	MWK	2026-04-23 20:59:52.434465+02
11	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	5	2	80000	MWK	2026-04-23 20:59:52.434465+02
12	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	5	1	100000	MWK	2026-04-23 20:59:52.434465+02
13	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	5	3	100000	MWK	2026-04-23 20:59:52.434465+02
14	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	2	1	100000	MWK	2026-04-23 20:59:52.434465+02
15	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	2	3	80000	MWK	2026-04-23 20:59:52.434465+02
16	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	3	1	3	60000	MWK	2026-04-23 20:59:52.434465+02
1	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	3	1	50000	MWK	2026-04-23 20:50:04.880442+02
2	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	3	2	80000	MWK	2026-04-23 20:50:04.880442+02
3	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2	50000	MWK	2026-04-23 20:50:04.880442+02
20	665a127e-0619-4505-9538-34df0b6d5f7a	5	8	10	30000	MWK	2026-04-26 10:30:48.412282+02
21	665a127e-0619-4505-9538-34df0b6d5f7a	5	8	9	50000	MWK	2026-04-26 10:30:48.412282+02
22	665a127e-0619-4505-9538-34df0b6d5f7a	5	8	7	85000	MWK	2026-04-26 10:30:48.412282+02
23	665a127e-0619-4505-9538-34df0b6d5f7a	5	10	9	20000	MWK	2026-04-26 10:30:48.412282+02
24	665a127e-0619-4505-9538-34df0b6d5f7a	5	10	7	55000	MWK	2026-04-26 10:30:48.412282+02
25	665a127e-0619-4505-9538-34df0b6d5f7a	5	9	7	50000	MWK	2026-04-26 10:30:48.412282+02
28	665a127e-0619-4505-9538-34df0b6d5f7a	6	7	9	50000	MWK	2026-04-26 10:35:55.113954+02
30	665a127e-0619-4505-9538-34df0b6d5f7a	6	7	10	60000	MWK	2026-04-26 10:37:03.533272+02
31	665a127e-0619-4505-9538-34df0b6d5f7a	6	7	8	85000	MWK	2026-04-26 10:37:03.533272+02
32	665a127e-0619-4505-9538-34df0b6d5f7a	6	9	10	50000	MWK	2026-04-26 10:37:03.533272+02
33	665a127e-0619-4505-9538-34df0b6d5f7a	6	9	8	70000	MWK	2026-04-26 10:37:03.533272+02
34	665a127e-0619-4505-9538-34df0b6d5f7a	6	10	8	20000	MWK	2026-04-26 10:37:03.533272+02
35	665a127e-0619-4505-9538-34df0b6d5f7a	7	7	11	40000	MWK	2026-04-26 10:37:34.441337+02
26	665a127e-0619-4505-9538-34df0b6d5f7a	7	7	6	100000	MWK	2026-04-26 10:33:21.921142+02
37	665a127e-0619-4505-9538-34df0b6d5f7a	7	11	6	50000	MWK	2026-04-26 10:37:34.441337+02
38	665a127e-0619-4505-9538-34df0b6d5f7a	8	6	11	50000	MWK	2026-04-26 10:38:05.18104+02
27	665a127e-0619-4505-9538-34df0b6d5f7a	8	6	7	100000	MWK	2026-04-26 10:34:09.393823+02
40	665a127e-0619-4505-9538-34df0b6d5f7a	8	11	7	40000	MWK	2026-04-26 10:38:05.18104+02
43	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	14	12	40000	MWK	2026-04-26 11:02:28.285547+02
41	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	14	13	85000	MWK	2026-04-26 11:01:10.167807+02
45	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	12	13	50000	MWK	2026-04-26 11:02:28.285547+02
46	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	13	12	40000	MWK	2026-04-26 11:02:44.781885+02
42	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	13	14	85000	MWK	2026-04-26 11:02:01.356192+02
48	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	12	14	50000	MWK	2026-04-26 11:02:44.781885+02
\.


--
-- Data for Name: routes; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.routes (id, tenant_id, route_code, origin_stage_id, destination_stage_id, intermediate_stops, base_fare, created_at, updated_at) FROM stdin;
1	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Blantyre - Lilongwe	3	2	[{"order": 1, "location": "Ntcheu", "stage_id": 1, "stage_name": "Ntcheu Depot"}]	85000.00	2026-04-23 20:49:33.314348+02	2026-04-23 20:49:33.314348+02
2	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Lilongwe - Blantyre	2	3	[{"order": 1, "location": "Ntcheu", "stage_id": 1, "stage_name": "Ntcheu Depot"}]	85000.00	2026-04-23 20:55:52.705378+02	2026-04-23 20:55:52.705378+02
3	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Mzimba - Blantyre	4	3	[{"order": 1, "location": "Kasungu", "stage_id": 5, "stage_name": "Kasungu Stage"}, {"order": 2, "location": "Lilongwe", "stage_id": 2, "stage_name": "Grand Business Park"}, {"order": 3, "location": "Ntcheu", "stage_id": 1, "stage_name": "Ntcheu Depot"}]	150000.00	2026-04-23 20:58:38.180751+02	2026-04-23 20:58:38.180751+02
5	665a127e-0619-4505-9538-34df0b6d5f7a	Blantyre - Lilongwe	8	7	[{"order": 1, "location": "Blantyre", "stage_id": 10, "stage_name": "Zalewa"}, {"order": 2, "location": "Ntcheu", "stage_id": 9, "stage_name": "Ntcheu Depot"}]	85000.00	2026-04-26 10:29:58.47588+02	2026-04-26 10:29:58.47588+02
6	665a127e-0619-4505-9538-34df0b6d5f7a	Lilongwe - Blantyre	7	8	[{"order": 1, "location": "Ntcheu", "stage_id": 9, "stage_name": "Ntcheu Depot"}, {"order": 2, "location": "Blantyre", "stage_id": 10, "stage_name": "Zalewa"}]	85000.00	2026-04-26 10:32:02.310289+02	2026-04-26 10:32:02.310289+02
7	665a127e-0619-4505-9538-34df0b6d5f7a	Lilongwe - Mzimba	7	6	[{"order": 1, "location": "Kasungu", "stage_id": 11, "stage_name": "Kasungu Depot"}]	100000.00	2026-04-26 10:33:21.432272+02	2026-04-26 10:33:21.432272+02
8	665a127e-0619-4505-9538-34df0b6d5f7a	Mzimba - Lilongwe	6	7	[{"order": 1, "location": "Kasungu", "stage_id": 11, "stage_name": "Kasungu Depot"}]	100000.00	2026-04-26 10:34:09.044413+02	2026-04-26 10:34:09.044413+02
9	544618e1-b774-4eb4-abf9-c3cb2d99265f	Blantyre - Lilongwe	14	13	[{"order": 1, "location": "Ntcheu", "stage_id": 12, "stage_name": "Ntcheu"}]	85000.00	2026-04-26 11:01:09.628376+02	2026-04-26 11:01:09.628376+02
10	544618e1-b774-4eb4-abf9-c3cb2d99265f	Lilongwe - Blantyre	13	14	[{"order": 1, "location": "Ntcheu", "stage_id": 12, "stage_name": "Ntcheu"}]	85000.00	2026-04-26 11:02:00.418973+02	2026-04-26 11:02:00.418973+02
\.


--
-- Data for Name: schedule_masters; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.schedule_masters (id, tenant_id, route_id, bus_id, frequency, days_of_week, window_size, departure_time, arrival_time, auto_extend_enabled, last_generated_date, created_at, updated_at) FROM stdin;
1	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	daily	{0,1,2,3,4,5,6}	30	13:30:00	17:30:00	t	2026-05-22	2026-04-23 20:51:04.986446+02	2026-04-23 20:51:04.986446+02
2	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	daily	{0,1,2,3,4,5,6}	30	07:30:00	13:30:00	t	2026-05-22	2026-04-23 21:02:07.798603+02	2026-04-23 21:02:07.798603+02
\.


--
-- Data for Name: seat_assignments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.seat_assignments (id, trip_id, booking_passenger_id, seat_label, created_at, boarding_stage_id, alighting_stage_id, boarding_rank, alighting_rank) FROM stdin;
10	2	10	1A	2026-04-24 12:11:19.811345+02	\N	\N	0	2
11	33	11	1B	2026-04-24 12:11:37.181738+02	\N	\N	0	2
12	2	12	1B	2026-04-24 12:14:31.31674+02	\N	\N	0	2
13	3	13	1B	2026-04-24 12:29:19.730611+02	\N	\N	0	2
14	34	14	2B	2026-04-24 15:06:16.26912+02	\N	\N	0	2
15	34	15	2D	2026-04-24 15:06:17.577788+02	\N	\N	0	2
17	67	17	1A	2026-04-28 12:24:36.685813+02	\N	\N	1	3
19	303	19	1A	2026-04-28 14:26:38.387015+02	\N	\N	0	2
16	38	16	1A	2026-04-27 23:41:36.255208+02	\N	\N	0	2
20	67	18	1B	2026-04-29 11:12:33.597142+02	\N	\N	0	0
21	67	20	1B	2026-04-29 14:01:44.882332+02	\N	\N	0	3
22	67	21	1C	2026-04-29 14:01:44.882332+02	\N	\N	0	3
23	67	22	1D	2026-04-29 14:01:44.882332+02	\N	\N	0	3
24	67	23	1E	2026-04-29 14:01:44.882332+02	\N	\N	0	3
25	246	24	1A	2026-04-29 16:14:51.529675+02	\N	\N	\N	\N
26	246	25	1B	2026-04-29 16:14:52.185029+02	\N	\N	\N	\N
27	8	26	10A	2026-04-29 23:23:35.979525+02	\N	\N	\N	\N
28	37	27	10A	2026-04-29 23:59:35.089507+02	\N	\N	\N	\N
29	216	28	10A	2026-04-30 00:06:39.84265+02	\N	\N	\N	\N
30	72	29	1A	2026-04-30 11:29:07.506075+02	\N	\N	0	3
31	219	30	1A	2026-04-30 11:53:14.343482+02	\N	\N	0	2
32	218	31	1A	2026-04-30 11:56:37.134241+02	\N	\N	0	2
33	132	32	1A	2026-04-30 12:49:30.377872+02	\N	\N	0	2
34	157	33	1A	2026-05-01 00:18:10.990756+02	\N	\N	0	2
35	9	34	10A	2026-05-01 08:42:59.01153+02	\N	\N	\N	\N
36	188	35	10A	2026-05-01 08:55:47.336956+02	\N	\N	\N	\N
37	188	36	10B	2026-05-01 09:47:10.870569+02	\N	\N	\N	\N
38	188	37	10C	2026-05-01 09:50:57.302155+02	\N	\N	\N	\N
39	188	38	10D	2026-05-01 09:56:18.063271+02	\N	\N	\N	\N
40	188	39	11A	2026-05-01 10:16:47.520585+02	\N	\N	\N	\N
41	39	40	1A	2026-05-01 10:26:18.252865+02	\N	\N	0	2
42	158	41	1A	2026-05-01 14:30:39.422928+02	\N	\N	0	2
43	158	42	1B	2026-05-01 14:32:16.187969+02	\N	\N	0	2
\.


--
-- Data for Name: sms_logs; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.sms_logs (id, tenant_id, booking_id, passenger_id, phone, message, status, response, created_at) FROM stdin;
\.


--
-- Data for Name: stages; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.stages (id, tenant_id, stage_name, location, is_major_stage, coordinates, created_at, updated_at) FROM stdin;
1	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Ntcheu Depot	Ntcheu	f	\N	2026-04-23 20:48:15.74275+02	2026-04-23 20:48:15.74275+02
2	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Grand Business Park	Lilongwe	t	\N	2026-04-23 20:48:41.432767+02	2026-04-23 20:48:41.432767+02
3	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Chichiri City Mall	Blantyre	t	\N	2026-04-23 20:49:06.597609+02	2026-04-23 20:49:06.597609+02
4	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Mzuzu Terminal	Mzimba	t	\N	2026-04-23 20:57:11.449629+02	2026-04-23 20:57:11.449629+02
5	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Kasungu Stage	Kasungu	f	\N	2026-04-23 20:57:40.336187+02	2026-04-23 20:57:40.336187+02
6	665a127e-0619-4505-9538-34df0b6d5f7a	Mzuzu Terminal	Mzimba	t	\N	2026-04-26 10:23:39.616992+02	2026-04-26 10:23:39.616992+02
7	665a127e-0619-4505-9538-34df0b6d5f7a	Gateway Mall	Lilongwe	t	\N	2026-04-26 10:24:14.355728+02	2026-04-26 10:24:14.355728+02
8	665a127e-0619-4505-9538-34df0b6d5f7a	Wenera Terminal	Blantyre	t	\N	2026-04-26 10:24:43.962661+02	2026-04-26 10:24:43.962661+02
9	665a127e-0619-4505-9538-34df0b6d5f7a	Ntcheu Depot	Ntcheu	f	\N	2026-04-26 10:25:13.065675+02	2026-04-26 10:25:13.065675+02
10	665a127e-0619-4505-9538-34df0b6d5f7a	Zalewa	Blantyre	f	\N	2026-04-26 10:25:32.501305+02	2026-04-26 10:25:32.501305+02
11	665a127e-0619-4505-9538-34df0b6d5f7a	Kasungu Depot	Kasungu	f	\N	2026-04-26 10:25:48.675999+02	2026-04-26 10:25:48.675999+02
12	544618e1-b774-4eb4-abf9-c3cb2d99265f	Ntcheu	Ntcheu	f	\N	2026-04-26 10:59:38.325232+02	2026-04-26 10:59:38.325232+02
13	544618e1-b774-4eb4-abf9-c3cb2d99265f	Gateway Mall	Lilongwe	t	\N	2026-04-26 11:00:03.440946+02	2026-04-26 11:00:03.440946+02
14	544618e1-b774-4eb4-abf9-c3cb2d99265f	Chichiri Mall Terminal	Blantyre	t	\N	2026-04-26 11:00:28.232695+02	2026-04-26 11:00:28.232695+02
\.


--
-- Data for Name: tenants; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.tenants (id, name, contact, is_active, created_at, updated_at, settings, logo) FROM stdin;
3dce9d0c-181d-4a54-911c-471959d7065d	Sososo	0885705304	t	2026-04-23 21:19:22.856095+02	2026-04-24 13:45:18.413638+02	{"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Sososo"}, "features": {"enable_refunds": true, "enable_reschedule": true, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 25}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}	\N
665a127e-0619-4505-9538-34df0b6d5f7a	Tam Tam	0987674562	t	2026-04-26 10:08:37.797183+02	2026-04-26 10:08:37.797183+02	{}	\N
6dab27c3-9d15-4e79-a7fe-209cdaee3b40	Machawi	0885705304	t	2026-04-23 20:46:31.162243+02	2026-04-26 11:11:51.433731+02	{"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": "https://aqjfskbmiycsebzegtys.supabase.co/storage/v1/object/public/tenant-logos/new-provider/logo-1776969977318.jpg", "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": "new-provider/logo-1776969977318.jpg", "company_name_display": "Machawi"}, "features": {"enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}	\N
544618e1-b774-4eb4-abf9-c3cb2d99265f	Kwezy Buses	0987876482	t	2026-04-26 10:54:59.408617+02	2026-04-26 11:33:11.761338+02	{"social": {"twitter": "", "facebook": "", "whatsapp": "", "instagram": ""}, "ticket": {"qr_size": 200, "terms_url": "", "ticket_prefix": "SS", "include_passenger_photo": false}, "payment": {"accepted_methods": ["cash", "mobile_money"], "default_currency": "MWK", "refund_window_hours": 24, "child_discount_percent": 0, "mobile_money_providers": ["airtel_money", "tnm_mpamba"], "refund_deduction_percent": 10, "return_trip_discount_percent": 0}, "branding": {"logo_url": null, "favicon_url": null, "accent_color": "#F59E0B", "primary_color": "#3B82F6", "company_slogan": "", "secondary_color": "#10B981", "logo_storage_path": null, "company_name_display": "Kwezy Buses"}, "features": {"child_discount": 5, "enable_refunds": true, "enable_reschedule": true, "refund_percentage": 10, "enable_open_tickets": false, "enable_ussd_booking": false, "require_national_id": false, "allow_guest_checkout": false, "return_trip_discount": 10, "enable_online_booking": true, "enable_seat_selection": true, "enable_walkin_booking": true, "max_advance_booking_days": 30, "cancellation_window_hours": 24}, "receipts": {"paper_size": "58mm", "footer_text": "Valid only on date of travel. Please arrive 30 mins early.", "header_text": "Thank you for choosing our service", "include_logo": true, "show_qr_code": true}, "notifications": {"admin_email": "", "admin_phone": "", "payment_receipt_sms": true, "payment_receipt_email": true, "reminder_hours_before": 2, "booking_confirmation_sms": true, "booking_confirmation_email": true}}	\N
\.


--
-- Data for Name: trips; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.trips (id, tenant_id, route_id, bus_id, departure_datetime, arrival_datetime, boarding_stage_id, alighting_stage_id, status, created_at, updated_at, seat_conflict_warning, original_bus_id, schedule_master_id) FROM stdin;
9	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-01 13:30:00+02	2026-05-01 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
10	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-02 13:30:00+02	2026-05-02 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
11	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-03 13:30:00+02	2026-05-03 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
12	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-04 13:30:00+02	2026-05-04 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
13	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-05 13:30:00+02	2026-05-05 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
14	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-06 13:30:00+02	2026-05-06 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
15	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-07 13:30:00+02	2026-05-07 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
16	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-08 13:30:00+02	2026-05-08 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
17	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-09 13:30:00+02	2026-05-09 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
18	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-10 13:30:00+02	2026-05-10 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
19	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-11 13:30:00+02	2026-05-11 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
20	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-12 13:30:00+02	2026-05-12 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
21	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-13 13:30:00+02	2026-05-13 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
22	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-14 13:30:00+02	2026-05-14 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
23	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-15 13:30:00+02	2026-05-15 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
24	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-16 13:30:00+02	2026-05-16 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
25	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-17 13:30:00+02	2026-05-17 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
26	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-18 13:30:00+02	2026-05-18 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
27	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-19 13:30:00+02	2026-05-19 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
28	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-20 13:30:00+02	2026-05-20 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
29	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-21 13:30:00+02	2026-05-21 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
30	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-05-22 13:30:00+02	2026-05-22 17:30:00+02	3	2	scheduled	2026-04-23 20:51:05.42981+02	2026-04-23 20:51:05.42981+02	f	1	1
39	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-01 07:30:00+02	2026-05-01 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
40	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-02 07:30:00+02	2026-05-02 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
41	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-03 07:30:00+02	2026-05-03 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
42	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-04 07:30:00+02	2026-05-04 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
43	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-05 07:30:00+02	2026-05-05 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
44	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-06 07:30:00+02	2026-05-06 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
45	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-07 07:30:00+02	2026-05-07 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
46	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-08 07:30:00+02	2026-05-08 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
47	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-09 07:30:00+02	2026-05-09 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
48	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-10 07:30:00+02	2026-05-10 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
49	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-11 07:30:00+02	2026-05-11 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
50	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-12 07:30:00+02	2026-05-12 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
51	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-13 07:30:00+02	2026-05-13 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
52	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-14 07:30:00+02	2026-05-14 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
7	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-04-29 13:30:00+02	2026-04-29 17:30:00+02	3	2	completed	2026-04-23 20:51:05.42981+02	2026-04-30 02:05:00.307926+02	f	1	1
8	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-04-30 13:30:00+02	2026-04-30 17:30:00+02	3	2	completed	2026-04-23 20:51:05.42981+02	2026-05-01 02:05:00.203974+02	f	1	1
38	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-04-30 07:30:00+02	2026-04-30 13:30:00+02	2	3	completed	2026-04-23 21:02:08.117478+02	2026-05-01 02:05:00.203974+02	f	2	2
53	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-15 07:30:00+02	2026-05-15 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
54	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-16 07:30:00+02	2026-05-16 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
55	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-17 07:30:00+02	2026-05-17 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
56	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-18 07:30:00+02	2026-05-18 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
57	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-19 07:30:00+02	2026-05-19 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
58	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-20 07:30:00+02	2026-05-20 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
59	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-21 07:30:00+02	2026-05-21 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
60	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-05-22 07:30:00+02	2026-05-22 13:30:00+02	2	3	scheduled	2026-04-23 21:02:08.117478+02	2026-04-23 21:02:08.117478+02	f	2	2
62	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	\N	2026-04-25 20:43:00+02	\N	\N	\N	cancelled	2026-04-25 20:43:44.248282+02	2026-04-25 20:44:27.888588+02	f	\N	\N
68	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-01 08:00:00+02	2026-05-01 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
69	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-02 08:00:00+02	2026-05-02 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
70	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-03 08:00:00+02	2026-05-03 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
71	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-04 08:00:00+02	2026-05-04 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
72	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-05 08:00:00+02	2026-05-05 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
73	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-06 08:00:00+02	2026-05-06 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
74	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-07 08:00:00+02	2026-05-07 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
75	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-08 08:00:00+02	2026-05-08 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
76	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-09 08:00:00+02	2026-05-09 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
77	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-10 08:00:00+02	2026-05-10 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
78	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-11 08:00:00+02	2026-05-11 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
79	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-12 08:00:00+02	2026-05-12 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
80	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-13 08:00:00+02	2026-05-13 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
81	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-14 08:00:00+02	2026-05-14 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
82	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-15 08:00:00+02	2026-05-15 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
83	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-16 08:00:00+02	2026-05-16 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
84	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-17 08:00:00+02	2026-05-17 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
85	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-18 08:00:00+02	2026-05-18 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
86	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-19 08:00:00+02	2026-05-19 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
87	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-20 08:00:00+02	2026-05-20 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
88	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-21 08:00:00+02	2026-05-21 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
89	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-22 08:00:00+02	2026-05-22 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
90	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-23 08:00:00+02	2026-05-23 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
91	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-24 08:00:00+02	2026-05-24 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
92	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-05-25 08:00:00+02	2026-05-25 13:30:00+02	8	7	scheduled	2026-04-26 10:39:45.758516+02	2026-04-26 10:39:45.758516+02	f	4	\N
98	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-01 14:00:00+02	2026-05-01 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
99	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-02 14:00:00+02	2026-05-02 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
100	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-03 14:00:00+02	2026-05-03 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
101	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-04 14:00:00+02	2026-05-04 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
102	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-05 14:00:00+02	2026-05-05 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
103	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-06 14:00:00+02	2026-05-06 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
61	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	3	2026-04-25 20:41:00+02	2026-04-25 21:43:00+02	\N	\N	completed	2026-04-24 14:37:21.20186+02	2026-04-29 09:18:33.763091+02	f	\N	\N
96	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-04-29 14:00:00+02	2026-04-29 17:40:00+02	7	8	completed	2026-04-26 10:40:31.871268+02	2026-04-30 02:05:00.307926+02	f	4	\N
67	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-04-30 08:00:00+02	2026-04-30 13:30:00+02	8	7	completed	2026-04-26 10:39:45.758516+02	2026-05-01 02:05:00.203974+02	f	4	\N
97	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-04-30 14:00:00+02	2026-04-30 17:40:00+02	7	8	completed	2026-04-26 10:40:31.871268+02	2026-05-01 02:05:00.203974+02	f	4	\N
104	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-07 14:00:00+02	2026-05-07 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
105	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-08 14:00:00+02	2026-05-08 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
106	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-09 14:00:00+02	2026-05-09 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
107	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-10 14:00:00+02	2026-05-10 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
108	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-11 14:00:00+02	2026-05-11 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
109	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-12 14:00:00+02	2026-05-12 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
110	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-13 14:00:00+02	2026-05-13 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
111	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-14 14:00:00+02	2026-05-14 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
112	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-15 14:00:00+02	2026-05-15 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
113	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-16 14:00:00+02	2026-05-16 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
114	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-17 14:00:00+02	2026-05-17 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
115	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-18 14:00:00+02	2026-05-18 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
116	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-19 14:00:00+02	2026-05-19 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
117	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-20 14:00:00+02	2026-05-20 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
118	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-21 14:00:00+02	2026-05-21 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
119	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-22 14:00:00+02	2026-05-22 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
120	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-23 14:00:00+02	2026-05-23 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
121	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-24 14:00:00+02	2026-05-24 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
122	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-05-25 14:00:00+02	2026-05-25 17:40:00+02	7	8	scheduled	2026-04-26 10:40:31.871268+02	2026-04-26 10:40:31.871268+02	f	4	\N
128	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-01 08:00:00+02	2026-05-01 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
129	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-02 08:00:00+02	2026-05-02 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
130	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-03 08:00:00+02	2026-05-03 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
131	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-04 08:00:00+02	2026-05-04 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
132	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-05 08:00:00+02	2026-05-05 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
133	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-06 08:00:00+02	2026-05-06 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
134	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-07 08:00:00+02	2026-05-07 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
135	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-08 08:00:00+02	2026-05-08 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
136	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-09 08:00:00+02	2026-05-09 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
137	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-10 08:00:00+02	2026-05-10 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
138	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-11 08:00:00+02	2026-05-11 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
139	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-12 08:00:00+02	2026-05-12 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
140	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-13 08:00:00+02	2026-05-13 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
141	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-14 08:00:00+02	2026-05-14 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
142	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-15 08:00:00+02	2026-05-15 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
143	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-16 08:00:00+02	2026-05-16 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
144	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-17 08:00:00+02	2026-05-17 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
145	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-18 08:00:00+02	2026-05-18 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
146	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-19 08:00:00+02	2026-05-19 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
147	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-20 08:00:00+02	2026-05-20 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
148	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-21 08:00:00+02	2026-05-21 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
149	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-22 08:00:00+02	2026-05-22 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
150	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-23 08:00:00+02	2026-05-23 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
151	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-24 08:00:00+02	2026-05-24 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
152	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-05-25 08:00:00+02	2026-05-25 16:00:00+02	7	6	scheduled	2026-04-26 10:44:25.218603+02	2026-04-26 10:44:25.218603+02	f	5	\N
127	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-04-30 08:00:00+02	2026-04-30 16:00:00+02	7	6	completed	2026-04-26 10:44:25.218603+02	2026-05-01 02:05:00.203974+02	f	5	\N
158	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-01 17:00:00+02	2026-05-01 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
159	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-02 17:00:00+02	2026-05-02 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
160	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-03 17:00:00+02	2026-05-03 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
161	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-04 17:00:00+02	2026-05-04 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
162	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-05 17:00:00+02	2026-05-05 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
163	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-06 17:00:00+02	2026-05-06 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
164	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-07 17:00:00+02	2026-05-07 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
165	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-08 17:00:00+02	2026-05-08 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
166	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-09 17:00:00+02	2026-05-09 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
167	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-10 17:00:00+02	2026-05-10 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
168	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-11 17:00:00+02	2026-05-11 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
169	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-12 17:00:00+02	2026-05-12 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
170	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-13 17:00:00+02	2026-05-13 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
171	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-14 17:00:00+02	2026-05-14 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
172	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-15 17:00:00+02	2026-05-15 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
173	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-16 17:00:00+02	2026-05-16 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
174	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-17 17:00:00+02	2026-05-17 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
175	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-18 17:00:00+02	2026-05-18 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
176	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-19 17:00:00+02	2026-05-19 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
177	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-20 17:00:00+02	2026-05-20 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
178	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-21 17:00:00+02	2026-05-21 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
179	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-22 17:00:00+02	2026-05-22 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
180	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-23 17:00:00+02	2026-05-23 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
181	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-24 17:00:00+02	2026-05-24 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
182	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-05-25 17:00:00+02	2026-05-25 23:00:00+02	6	7	scheduled	2026-04-26 10:45:05.562627+02	2026-04-26 10:45:05.562627+02	f	5	\N
188	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-01 07:30:00+02	2026-05-01 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
189	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-02 07:30:00+02	2026-05-02 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
190	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-03 07:30:00+02	2026-05-03 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
191	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-04 07:30:00+02	2026-05-04 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
192	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-05 07:30:00+02	2026-05-05 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
193	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-06 07:30:00+02	2026-05-06 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
194	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-07 07:30:00+02	2026-05-07 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
195	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-08 07:30:00+02	2026-05-08 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
196	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-09 07:30:00+02	2026-05-09 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
197	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-10 07:30:00+02	2026-05-10 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
198	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-11 07:30:00+02	2026-05-11 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
199	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-12 07:30:00+02	2026-05-12 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
200	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-13 07:30:00+02	2026-05-13 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
201	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-14 07:30:00+02	2026-05-14 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
202	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-15 07:30:00+02	2026-05-15 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
203	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-16 07:30:00+02	2026-05-16 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
204	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-17 07:30:00+02	2026-05-17 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
205	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-18 07:30:00+02	2026-05-18 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
206	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-19 07:30:00+02	2026-05-19 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
207	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-20 07:30:00+02	2026-05-20 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
156	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-04-29 17:00:00+02	2026-04-29 23:00:00+02	6	7	completed	2026-04-26 10:45:05.562627+02	2026-04-30 02:05:00.307926+02	f	5	\N
157	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-04-30 17:00:00+02	2026-04-30 23:00:00+02	6	7	completed	2026-04-26 10:45:05.562627+02	2026-05-01 02:05:00.203974+02	f	5	\N
187	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-04-30 07:30:00+02	2026-04-30 12:30:00+02	14	13	completed	2026-04-26 11:03:42.237938+02	2026-05-01 02:05:00.203974+02	f	7	\N
208	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-21 07:30:00+02	2026-05-21 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
209	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-22 07:30:00+02	2026-05-22 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
210	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-23 07:30:00+02	2026-05-23 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
211	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-24 07:30:00+02	2026-05-24 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
212	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-05-25 07:30:00+02	2026-05-25 12:30:00+02	14	13	scheduled	2026-04-26 11:03:42.237938+02	2026-04-26 11:03:42.237938+02	f	7	\N
218	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-01 07:30:00+02	2026-05-01 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
219	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-02 07:30:00+02	2026-05-02 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
220	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-03 07:30:00+02	2026-05-03 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
221	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-04 07:30:00+02	2026-05-04 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
222	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-05 07:30:00+02	2026-05-05 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
223	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-06 07:30:00+02	2026-05-06 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
224	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-07 07:30:00+02	2026-05-07 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
225	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-08 07:30:00+02	2026-05-08 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
226	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-09 07:30:00+02	2026-05-09 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
227	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-10 07:30:00+02	2026-05-10 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
228	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-11 07:30:00+02	2026-05-11 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
229	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-12 07:30:00+02	2026-05-12 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
230	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-13 07:30:00+02	2026-05-13 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
231	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-14 07:30:00+02	2026-05-14 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
232	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-15 07:30:00+02	2026-05-15 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
233	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-16 07:30:00+02	2026-05-16 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
234	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-17 07:30:00+02	2026-05-17 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
235	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-18 07:30:00+02	2026-05-18 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
236	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-19 07:30:00+02	2026-05-19 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
237	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-20 07:30:00+02	2026-05-20 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
238	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-21 07:30:00+02	2026-05-21 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
239	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-22 07:30:00+02	2026-05-22 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
240	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-23 07:30:00+02	2026-05-23 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
241	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-24 07:30:00+02	2026-05-24 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
242	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-05-25 07:30:00+02	2026-05-25 12:30:00+02	13	14	scheduled	2026-04-26 11:04:24.648751+02	2026-04-26 11:04:24.648751+02	f	8	\N
248	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-01 13:00:00+02	2026-05-01 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
249	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-02 13:00:00+02	2026-05-02 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
250	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-03 13:00:00+02	2026-05-03 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
251	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-04 13:00:00+02	2026-05-04 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
252	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-05 13:00:00+02	2026-05-05 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
253	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-06 13:00:00+02	2026-05-06 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
254	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-07 13:00:00+02	2026-05-07 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
255	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-08 13:00:00+02	2026-05-08 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
256	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-09 13:00:00+02	2026-05-09 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
257	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-10 13:00:00+02	2026-05-10 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
258	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-11 13:00:00+02	2026-05-11 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
259	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-12 13:00:00+02	2026-05-12 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
246	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-04-29 13:00:00+02	2026-04-29 17:30:00+02	14	13	completed	2026-04-26 11:05:40.108108+02	2026-04-30 02:05:00.307926+02	f	8	\N
217	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-04-30 07:30:00+02	2026-04-30 12:30:00+02	13	14	completed	2026-04-26 11:04:24.648751+02	2026-05-01 02:05:00.203974+02	f	8	\N
247	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-04-30 13:00:00+02	2026-04-30 17:30:00+02	14	13	completed	2026-04-26 11:05:40.108108+02	2026-05-01 02:05:00.203974+02	f	8	\N
260	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-13 13:00:00+02	2026-05-13 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
261	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-14 13:00:00+02	2026-05-14 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
262	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-15 13:00:00+02	2026-05-15 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
263	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-16 13:00:00+02	2026-05-16 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
264	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-17 13:00:00+02	2026-05-17 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
265	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-18 13:00:00+02	2026-05-18 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
266	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-19 13:00:00+02	2026-05-19 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
267	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-20 13:00:00+02	2026-05-20 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
268	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-21 13:00:00+02	2026-05-21 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
269	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-22 13:00:00+02	2026-05-22 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
270	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-23 13:00:00+02	2026-05-23 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
271	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-24 13:00:00+02	2026-05-24 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
272	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-05-25 13:00:00+02	2026-05-25 17:30:00+02	14	13	scheduled	2026-04-26 11:05:40.108108+02	2026-04-26 11:05:40.108108+02	f	8	\N
278	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-01 13:00:00+02	2026-05-01 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
279	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-02 13:00:00+02	2026-05-02 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
280	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-03 13:00:00+02	2026-05-03 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
281	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-04 13:00:00+02	2026-05-04 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
282	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-05 13:00:00+02	2026-05-05 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
283	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-06 13:00:00+02	2026-05-06 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
284	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-07 13:00:00+02	2026-05-07 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
285	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-08 13:00:00+02	2026-05-08 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
286	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-09 13:00:00+02	2026-05-09 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
287	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-10 13:00:00+02	2026-05-10 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
288	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-11 13:00:00+02	2026-05-11 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
289	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-12 13:00:00+02	2026-05-12 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
290	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-13 13:00:00+02	2026-05-13 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
291	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-14 13:00:00+02	2026-05-14 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
292	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-15 13:00:00+02	2026-05-15 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
293	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-16 13:00:00+02	2026-05-16 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
294	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-17 13:00:00+02	2026-05-17 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
295	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-18 13:00:00+02	2026-05-18 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
296	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-19 13:00:00+02	2026-05-19 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
297	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-20 13:00:00+02	2026-05-20 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
298	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-21 13:00:00+02	2026-05-21 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
299	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-22 13:00:00+02	2026-05-22 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
300	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-23 13:00:00+02	2026-05-23 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
301	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-24 13:00:00+02	2026-05-24 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
302	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-05-25 13:00:00+02	2026-05-25 17:30:00+02	13	14	scheduled	2026-04-26 11:06:51.59765+02	2026-04-26 11:06:51.59765+02	f	7	\N
276	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-04-29 13:00:00+02	2026-04-29 17:30:00+02	13	14	completed	2026-04-26 11:06:51.59765+02	2026-04-30 02:05:00.307926+02	f	7	\N
277	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-04-30 13:00:00+02	2026-04-30 17:30:00+02	13	14	completed	2026-04-26 11:06:51.59765+02	2026-05-01 02:05:00.203974+02	f	7	\N
1	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-04-23 13:30:00+02	2026-04-23 17:30:00+02	3	2	completed	2026-04-23 20:51:05.42981+02	2026-04-29 09:18:33.763091+02	f	1	1
2	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-04-24 13:30:00+02	2026-04-24 17:30:00+02	3	2	completed	2026-04-23 20:51:05.42981+02	2026-04-29 09:18:33.763091+02	f	1	1
3	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-04-25 13:30:00+02	2026-04-25 17:30:00+02	3	2	completed	2026-04-23 20:51:05.42981+02	2026-04-29 09:18:33.763091+02	f	1	1
4	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-04-26 13:30:00+02	2026-04-26 17:30:00+02	3	2	completed	2026-04-23 20:51:05.42981+02	2026-04-29 09:18:33.763091+02	f	1	1
5	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-04-27 13:30:00+02	2026-04-27 17:30:00+02	3	2	completed	2026-04-23 20:51:05.42981+02	2026-04-29 09:18:33.763091+02	f	1	1
6	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	1	1	2026-04-28 13:30:00+02	2026-04-28 17:30:00+02	3	2	completed	2026-04-23 20:51:05.42981+02	2026-04-29 09:18:33.763091+02	f	1	1
31	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-04-23 07:30:00+02	2026-04-23 13:30:00+02	2	3	completed	2026-04-23 21:02:08.117478+02	2026-04-29 09:18:33.763091+02	f	2	2
32	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-04-24 07:30:00+02	2026-04-24 13:30:00+02	2	3	completed	2026-04-23 21:02:08.117478+02	2026-04-29 09:18:33.763091+02	f	2	2
303	665a127e-0619-4505-9538-34df0b6d5f7a	8	6	2026-04-28 14:50:00+02	2026-04-28 19:00:00+02	\N	\N	completed	2026-04-28 14:24:19.12221+02	2026-04-29 09:18:33.763091+02	f	\N	\N
33	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-04-25 07:30:00+02	2026-04-25 13:30:00+02	2	3	completed	2026-04-23 21:02:08.117478+02	2026-04-29 09:18:33.763091+02	f	2	2
34	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-04-26 07:30:00+02	2026-04-26 13:30:00+02	2	3	completed	2026-04-23 21:02:08.117478+02	2026-04-29 09:18:33.763091+02	f	2	2
35	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-04-27 07:30:00+02	2026-04-27 13:30:00+02	2	3	completed	2026-04-23 21:02:08.117478+02	2026-04-29 09:18:33.763091+02	f	2	2
36	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-04-28 07:30:00+02	2026-04-28 13:30:00+02	2	3	completed	2026-04-23 21:02:08.117478+02	2026-04-29 09:18:33.763091+02	f	2	2
63	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-04-26 08:00:00+02	2026-04-26 13:30:00+02	8	7	completed	2026-04-26 10:39:45.758516+02	2026-04-29 09:18:33.763091+02	f	4	\N
64	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-04-27 08:00:00+02	2026-04-27 13:30:00+02	8	7	completed	2026-04-26 10:39:45.758516+02	2026-04-29 09:18:33.763091+02	f	4	\N
65	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-04-28 08:00:00+02	2026-04-28 13:30:00+02	8	7	completed	2026-04-26 10:39:45.758516+02	2026-04-29 09:18:33.763091+02	f	4	\N
93	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-04-26 14:00:00+02	2026-04-26 17:40:00+02	7	8	completed	2026-04-26 10:40:31.871268+02	2026-04-29 09:18:33.763091+02	f	4	\N
94	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-04-27 14:00:00+02	2026-04-27 17:40:00+02	7	8	completed	2026-04-26 10:40:31.871268+02	2026-04-29 09:18:33.763091+02	f	4	\N
95	665a127e-0619-4505-9538-34df0b6d5f7a	6	4	2026-04-28 14:00:00+02	2026-04-28 17:40:00+02	7	8	completed	2026-04-26 10:40:31.871268+02	2026-04-29 09:18:33.763091+02	f	4	\N
123	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-04-26 08:00:00+02	2026-04-26 16:00:00+02	7	6	completed	2026-04-26 10:44:25.218603+02	2026-04-29 09:18:33.763091+02	f	5	\N
124	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-04-27 08:00:00+02	2026-04-27 16:00:00+02	7	6	completed	2026-04-26 10:44:25.218603+02	2026-04-29 09:18:33.763091+02	f	5	\N
37	6dab27c3-9d15-4e79-a7fe-209cdaee3b40	2	2	2026-04-29 07:30:00+02	2026-04-29 13:30:00+02	2	3	completed	2026-04-23 21:02:08.117478+02	2026-04-30 02:05:00.307926+02	f	2	2
66	665a127e-0619-4505-9538-34df0b6d5f7a	5	4	2026-04-29 08:00:00+02	2026-04-29 13:30:00+02	8	7	completed	2026-04-26 10:39:45.758516+02	2026-04-30 02:05:00.307926+02	f	4	\N
126	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-04-29 08:00:00+02	2026-04-29 16:00:00+02	7	6	completed	2026-04-26 10:44:25.218603+02	2026-04-30 02:05:00.307926+02	f	5	\N
186	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-04-29 07:30:00+02	2026-04-29 12:30:00+02	14	13	completed	2026-04-26 11:03:42.237938+02	2026-04-30 02:05:00.307926+02	f	7	\N
216	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-04-29 07:30:00+02	2026-04-29 12:30:00+02	13	14	completed	2026-04-26 11:04:24.648751+02	2026-04-30 02:05:00.307926+02	f	8	\N
125	665a127e-0619-4505-9538-34df0b6d5f7a	7	5	2026-04-28 08:00:00+02	2026-04-28 16:00:00+02	7	6	completed	2026-04-26 10:44:25.218603+02	2026-04-29 09:18:33.763091+02	f	5	\N
153	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-04-26 17:00:00+02	2026-04-26 23:00:00+02	6	7	completed	2026-04-26 10:45:05.562627+02	2026-04-29 09:18:33.763091+02	f	5	\N
154	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-04-27 17:00:00+02	2026-04-27 23:00:00+02	6	7	completed	2026-04-26 10:45:05.562627+02	2026-04-29 09:18:33.763091+02	f	5	\N
155	665a127e-0619-4505-9538-34df0b6d5f7a	8	5	2026-04-28 17:00:00+02	2026-04-28 23:00:00+02	6	7	completed	2026-04-26 10:45:05.562627+02	2026-04-29 09:18:33.763091+02	f	5	\N
183	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-04-26 07:30:00+02	2026-04-26 12:30:00+02	14	13	completed	2026-04-26 11:03:42.237938+02	2026-04-29 09:18:33.763091+02	f	7	\N
184	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-04-27 07:30:00+02	2026-04-27 12:30:00+02	14	13	completed	2026-04-26 11:03:42.237938+02	2026-04-29 09:18:33.763091+02	f	7	\N
185	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	7	2026-04-28 07:30:00+02	2026-04-28 12:30:00+02	14	13	completed	2026-04-26 11:03:42.237938+02	2026-04-29 09:18:33.763091+02	f	7	\N
213	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-04-26 07:30:00+02	2026-04-26 12:30:00+02	13	14	completed	2026-04-26 11:04:24.648751+02	2026-04-29 09:18:33.763091+02	f	8	\N
214	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-04-27 07:30:00+02	2026-04-27 12:30:00+02	13	14	completed	2026-04-26 11:04:24.648751+02	2026-04-29 09:18:33.763091+02	f	8	\N
215	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	8	2026-04-28 07:30:00+02	2026-04-28 12:30:00+02	13	14	completed	2026-04-26 11:04:24.648751+02	2026-04-29 09:18:33.763091+02	f	8	\N
243	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-04-26 13:00:00+02	2026-04-26 17:30:00+02	14	13	completed	2026-04-26 11:05:40.108108+02	2026-04-29 09:18:33.763091+02	f	8	\N
244	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-04-27 13:00:00+02	2026-04-27 17:30:00+02	14	13	completed	2026-04-26 11:05:40.108108+02	2026-04-29 09:18:33.763091+02	f	8	\N
245	544618e1-b774-4eb4-abf9-c3cb2d99265f	9	8	2026-04-28 13:00:00+02	2026-04-28 17:30:00+02	14	13	completed	2026-04-26 11:05:40.108108+02	2026-04-29 09:18:33.763091+02	f	8	\N
273	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-04-26 13:00:00+02	2026-04-26 17:30:00+02	13	14	completed	2026-04-26 11:06:51.59765+02	2026-04-29 09:18:33.763091+02	f	7	\N
274	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-04-27 13:00:00+02	2026-04-27 17:30:00+02	13	14	completed	2026-04-26 11:06:51.59765+02	2026-04-29 09:18:33.763091+02	f	7	\N
275	544618e1-b774-4eb4-abf9-c3cb2d99265f	10	7	2026-04-28 13:00:00+02	2026-04-28 17:30:00+02	13	14	completed	2026-04-26 11:06:51.59765+02	2026-04-29 09:18:33.763091+02	f	7	\N
\.


--
-- Name: ads_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.ads_id_seq', 6, true);


--
-- Name: audit_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.audit_log_id_seq', 831, true);


--
-- Name: booking_passengers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.booking_passengers_id_seq', 42, true);


--
-- Name: booking_reschedules_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.booking_reschedules_id_seq', 2, true);


--
-- Name: bookings_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.bookings_id_seq', 39, true);


--
-- Name: buses_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.buses_id_seq', 8, true);


--
-- Name: migrations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.migrations_id_seq', 1, true);


--
-- Name: payments_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.payments_id_seq', 37, true);


--
-- Name: refunds_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.refunds_id_seq', 2, true);


--
-- Name: role_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.role_permissions_id_seq', 1, false);


--
-- Name: route_fares_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.route_fares_id_seq', 48, true);


--
-- Name: routes_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.routes_id_seq', 10, true);


--
-- Name: schedule_masters_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.schedule_masters_id_seq', 2, true);


--
-- Name: seat_assignments_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.seat_assignments_id_seq', 43, true);


--
-- Name: sms_logs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.sms_logs_id_seq', 1, false);


--
-- Name: stages_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.stages_id_seq', 14, true);


--
-- Name: trips_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.trips_id_seq', 303, true);


--
-- Name: ads ads_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ads
    ADD CONSTRAINT ads_pkey PRIMARY KEY (id);


--
-- Name: audit_log_archive audit_log_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log_archive
    ADD CONSTRAINT audit_log_archive_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: booking_passengers booking_passengers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_pkey PRIMARY KEY (id);


--
-- Name: booking_passengers booking_passengers_ticket_number_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_ticket_number_key UNIQUE (ticket_number);


--
-- Name: booking_reschedules booking_reschedules_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_pkey PRIMARY KEY (id);


--
-- Name: bookings bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_pkey PRIMARY KEY (id);


--
-- Name: buses buses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.buses
    ADD CONSTRAINT buses_pkey PRIMARY KEY (id);


--
-- Name: buses buses_tenant_id_registration_number_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.buses
    ADD CONSTRAINT buses_tenant_id_registration_number_key UNIQUE (tenant_id, registration_number);


--
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_national_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_national_id_key UNIQUE (national_id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_supa_auth_id_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_supa_auth_id_unique UNIQUE (supa_auth_id);


--
-- Name: refunds refunds_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_role_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_role_key UNIQUE (role);


--
-- Name: route_fares route_fares_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.route_fares
    ADD CONSTRAINT route_fares_pkey PRIMARY KEY (id);


--
-- Name: route_fares route_fares_route_id_boarding_stage_id_alighting_stage_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.route_fares
    ADD CONSTRAINT route_fares_route_id_boarding_stage_id_alighting_stage_id_key UNIQUE (route_id, boarding_stage_id, alighting_stage_id);


--
-- Name: routes routes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_pkey PRIMARY KEY (id);


--
-- Name: routes routes_tenant_id_route_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_tenant_id_route_code_key UNIQUE (tenant_id, route_code);


--
-- Name: schedule_masters schedule_masters_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schedule_masters
    ADD CONSTRAINT schedule_masters_pkey PRIMARY KEY (id);


--
-- Name: seat_assignments seat_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_pkey PRIMARY KEY (id);


--
-- Name: sms_logs sms_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sms_logs
    ADD CONSTRAINT sms_logs_pkey PRIMARY KEY (id);


--
-- Name: stages stages_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_pkey PRIMARY KEY (id);


--
-- Name: stages stages_tenant_id_stage_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_tenant_id_stage_name_key UNIQUE (tenant_id, stage_name);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: trips trips_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_pkey PRIMARY KEY (id);


--
-- Name: idx_audit_log_action; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_log_action ON public.audit_log USING btree (action);


--
-- Name: idx_audit_log_actor; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_log_actor ON public.audit_log USING btree (actor_id);


--
-- Name: idx_audit_log_target; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_log_target ON public.audit_log USING btree (target_type, target_id);


--
-- Name: idx_audit_log_tenant_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_log_tenant_created ON public.audit_log USING btree (tenant_id, created_at DESC);


--
-- Name: idx_booking_passengers_booking; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_booking_passengers_booking ON public.booking_passengers USING btree (booking_id);


--
-- Name: idx_bookings_booking_token; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bookings_booking_token ON public.bookings USING btree (booking_token);


--
-- Name: idx_bookings_expires; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bookings_expires ON public.bookings USING btree (expires_at);


--
-- Name: idx_bookings_open_tickets; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bookings_open_tickets ON public.bookings USING btree (tenant_id, status) WHERE (trip_id IS NULL);


--
-- Name: idx_bookings_route_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bookings_route_id ON public.bookings USING btree (route_id);


--
-- Name: idx_bookings_tenant_trip; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bookings_tenant_trip ON public.bookings USING btree (tenant_id, trip_id);


--
-- Name: idx_notifications_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_created ON public.notifications USING btree (created_at DESC);


--
-- Name: idx_notifications_profile; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_profile ON public.notifications USING btree (profile_id);


--
-- Name: idx_notifications_tenant; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_tenant ON public.notifications USING btree (tenant_id);


--
-- Name: idx_notifications_trip; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_trip ON public.notifications USING btree (trip_id);


--
-- Name: idx_notifications_unread; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_unread ON public.notifications USING btree (is_read) WHERE (is_read = false);


--
-- Name: idx_passengers_ticket_token; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_passengers_ticket_token ON public.booking_passengers USING btree (ticket_token);


--
-- Name: idx_profiles_phone; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_profiles_phone ON public.profiles USING btree (phone);


--
-- Name: idx_profiles_phone_tenant; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_profiles_phone_tenant ON public.profiles USING btree (phone, tenant_id);


--
-- Name: idx_routes_route_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_routes_route_code ON public.routes USING btree (route_code) WHERE (route_code IS NOT NULL);


--
-- Name: idx_routes_tenant; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_routes_tenant ON public.routes USING btree (tenant_id);


--
-- Name: idx_schedule_masters_auto_extend; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_schedule_masters_auto_extend ON public.schedule_masters USING btree (tenant_id, auto_extend_enabled) WHERE (auto_extend_enabled = true);


--
-- Name: idx_schedule_masters_route; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_schedule_masters_route ON public.schedule_masters USING btree (route_id);


--
-- Name: idx_schedule_masters_tenant; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_schedule_masters_tenant ON public.schedule_masters USING btree (tenant_id);


--
-- Name: idx_seat_assignments_trip; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_seat_assignments_trip ON public.seat_assignments USING btree (trip_id);


--
-- Name: idx_stages_tenant; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_stages_tenant ON public.stages USING btree (tenant_id);


--
-- Name: idx_tenants_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenants_active ON public.tenants USING btree (is_active) WHERE (is_active = true);


--
-- Name: idx_tenants_settings; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenants_settings ON public.tenants USING gin (settings);


--
-- Name: idx_trips_bus_datetime; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_trips_bus_datetime ON public.trips USING btree (tenant_id, bus_id, departure_datetime, arrival_datetime) WHERE (status = ANY (ARRAY['scheduled'::text, 'active'::text]));


--
-- Name: idx_trips_departure; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_trips_departure ON public.trips USING btree (departure_datetime);


--
-- Name: idx_trips_departure_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_trips_departure_date ON public.trips USING btree (tenant_id, departure_datetime);


--
-- Name: idx_trips_route_status_departure; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_trips_route_status_departure ON public.trips USING btree (route_id, status, departure_datetime);


--
-- Name: idx_trips_route_tenant_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_trips_route_tenant_date ON public.trips USING btree (route_id, tenant_id, status, public.immutable_date(departure_datetime));


--
-- Name: idx_trips_schedule_master; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_trips_schedule_master ON public.trips USING btree (schedule_master_id);


--
-- Name: idx_trips_tenant_route; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_trips_tenant_route ON public.trips USING btree (tenant_id, route_id);


--
-- Name: booking_passengers audit_booking_passengers; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_booking_passengers AFTER INSERT OR DELETE OR UPDATE ON public.booking_passengers FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: booking_reschedules audit_booking_reschedules; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_booking_reschedules AFTER INSERT OR DELETE OR UPDATE ON public.booking_reschedules FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: bookings audit_bookings; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_bookings AFTER INSERT OR DELETE OR UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: buses audit_buses; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_buses AFTER INSERT OR DELETE OR UPDATE ON public.buses FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: payments audit_payments; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_payments AFTER INSERT OR DELETE OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: profiles audit_profiles; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_profiles AFTER INSERT OR DELETE OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: refunds audit_refunds; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_refunds AFTER INSERT OR DELETE OR UPDATE ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: routes audit_routes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_routes AFTER INSERT OR DELETE OR UPDATE ON public.routes FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: schedule_masters audit_schedule_masters; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_schedule_masters AFTER INSERT OR DELETE OR UPDATE ON public.schedule_masters FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: seat_assignments audit_seat_assignments; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_seat_assignments AFTER INSERT OR DELETE OR UPDATE ON public.seat_assignments FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: sms_logs audit_sms_logs; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_sms_logs AFTER INSERT OR DELETE OR UPDATE ON public.sms_logs FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: stages audit_stages; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_stages AFTER INSERT OR DELETE OR UPDATE ON public.stages FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: tenants audit_tenants; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_tenants AFTER INSERT OR DELETE OR UPDATE ON public.tenants FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: trips audit_trips; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER audit_trips AFTER INSERT OR DELETE OR UPDATE ON public.trips FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


--
-- Name: notifications entrig_notifications_insert_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER entrig_notifications_insert_trigger AFTER INSERT ON public.notifications FOR EACH ROW EXECUTE FUNCTION entrig.entrig_event_handler();


--
-- Name: bookings set_timestamp_bookings; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_bookings BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: buses set_timestamp_buses; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_buses BEFORE UPDATE ON public.buses FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: notifications set_timestamp_notifications; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_notifications BEFORE UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: profiles set_timestamp_profiles; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_profiles BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: refunds set_timestamp_refunds; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_refunds BEFORE UPDATE ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: routes set_timestamp_routes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_routes BEFORE UPDATE ON public.routes FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: schedule_masters set_timestamp_schedule_masters; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_schedule_masters BEFORE UPDATE ON public.schedule_masters FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: stages set_timestamp_stages; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_stages BEFORE UPDATE ON public.stages FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: tenants set_timestamp_tenants; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_tenants BEFORE UPDATE ON public.tenants FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: trips set_timestamp_trips; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp_trips BEFORE UPDATE ON public.trips FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: bookings trg_generate_booking_token; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_generate_booking_token BEFORE INSERT ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.generate_booking_token();


--
-- Name: booking_passengers trigger_assign_ticket_number; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_assign_ticket_number BEFORE INSERT ON public.booking_passengers FOR EACH ROW WHEN ((new.ticket_number IS NULL)) EXECUTE FUNCTION public.generate_ticket_number();


--
-- Name: bookings trigger_booking_confirmation_notification; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_booking_confirmation_notification AFTER INSERT ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.handle_booking_confirmation_notification();


--
-- Name: seat_assignments trigger_enforce_seat; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_enforce_seat BEFORE INSERT OR UPDATE ON public.seat_assignments FOR EACH ROW EXECUTE FUNCTION public.enforce_seat_assignment();


--
-- Name: profiles trigger_profile_role_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_profile_role_changes AFTER UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.log_profile_role_changes();


--
-- Name: bookings trigger_send_booking_sms; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_send_booking_sms AFTER UPDATE ON public.bookings FOR EACH ROW WHEN ((old.status IS DISTINCT FROM new.status)) EXECUTE FUNCTION public.send_booking_sms();


--
-- Name: ads ads_tenantId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ads
    ADD CONSTRAINT "ads_tenantId_fkey" FOREIGN KEY ("tenantId") REFERENCES public.tenants(id);


--
-- Name: audit_log audit_log_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: audit_log audit_log_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: booking_passengers booking_passengers_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: booking_passengers booking_passengers_checked_in_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_checked_in_by_fkey FOREIGN KEY (checked_in_by) REFERENCES public.profiles(id);


--
-- Name: booking_passengers booking_passengers_linked_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_passengers
    ADD CONSTRAINT booking_passengers_linked_profile_id_fkey FOREIGN KEY (linked_profile_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: booking_reschedules booking_reschedules_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: booking_reschedules booking_reschedules_new_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_new_trip_id_fkey FOREIGN KEY (new_trip_id) REFERENCES public.trips(id);


--
-- Name: booking_reschedules booking_reschedules_old_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_old_trip_id_fkey FOREIGN KEY (old_trip_id) REFERENCES public.trips(id);


--
-- Name: booking_reschedules booking_reschedules_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.booking_reschedules
    ADD CONSTRAINT booking_reschedules_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: bookings bookings_booked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_booked_by_fkey FOREIGN KEY (booked_by_profile_id) REFERENCES public.profiles(id);


--
-- Name: bookings bookings_original_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_original_booking_id_fkey FOREIGN KEY (original_booking_id) REFERENCES public.bookings(id) ON DELETE SET NULL;


--
-- Name: bookings bookings_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.routes(id);


--
-- Name: bookings bookings_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: bookings bookings_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_trip_id_fkey FOREIGN KEY (trip_id) REFERENCES public.trips(id);


--
-- Name: buses buses_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.buses
    ADD CONSTRAINT buses_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.profiles(id);


--
-- Name: notifications notifications_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.routes(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_sent_by_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_sent_by_profile_id_fkey FOREIGN KEY (sent_by_profile_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_trip_id_fkey FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: payments payments_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (supa_auth_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE SET NULL;


--
-- Name: refunds refunds_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: refunds refunds_payment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.payments(id);


--
-- Name: refunds refunds_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: route_fares route_fares_alighting_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.route_fares
    ADD CONSTRAINT route_fares_alighting_stage_id_fkey FOREIGN KEY (alighting_stage_id) REFERENCES public.stages(id);


--
-- Name: route_fares route_fares_boarding_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.route_fares
    ADD CONSTRAINT route_fares_boarding_stage_id_fkey FOREIGN KEY (boarding_stage_id) REFERENCES public.stages(id);


--
-- Name: route_fares route_fares_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.route_fares
    ADD CONSTRAINT route_fares_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.routes(id);


--
-- Name: route_fares route_fares_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.route_fares
    ADD CONSTRAINT route_fares_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: routes routes_destination_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_destination_stage_id_fkey FOREIGN KEY (destination_stage_id) REFERENCES public.stages(id);


--
-- Name: routes routes_origin_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_origin_stage_id_fkey FOREIGN KEY (origin_stage_id) REFERENCES public.stages(id);


--
-- Name: routes routes_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.routes
    ADD CONSTRAINT routes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: schedule_masters schedule_masters_bus_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schedule_masters
    ADD CONSTRAINT schedule_masters_bus_id_fkey FOREIGN KEY (bus_id) REFERENCES public.buses(id) ON DELETE CASCADE;


--
-- Name: schedule_masters schedule_masters_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schedule_masters
    ADD CONSTRAINT schedule_masters_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.routes(id) ON DELETE CASCADE;


--
-- Name: schedule_masters schedule_masters_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schedule_masters
    ADD CONSTRAINT schedule_masters_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: seat_assignments seat_assignments_alighting_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_alighting_stage_id_fkey FOREIGN KEY (alighting_stage_id) REFERENCES public.stages(id);


--
-- Name: seat_assignments seat_assignments_boarding_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_boarding_stage_id_fkey FOREIGN KEY (boarding_stage_id) REFERENCES public.stages(id);


--
-- Name: seat_assignments seat_assignments_booking_passenger_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_booking_passenger_id_fkey FOREIGN KEY (booking_passenger_id) REFERENCES public.booking_passengers(id);


--
-- Name: seat_assignments seat_assignments_trip_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.seat_assignments
    ADD CONSTRAINT seat_assignments_trip_id_fkey FOREIGN KEY (trip_id) REFERENCES public.trips(id);


--
-- Name: sms_logs sms_logs_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sms_logs
    ADD CONSTRAINT sms_logs_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id) ON DELETE CASCADE;


--
-- Name: sms_logs sms_logs_passenger_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sms_logs
    ADD CONSTRAINT sms_logs_passenger_id_fkey FOREIGN KEY (passenger_id) REFERENCES public.booking_passengers(id) ON DELETE CASCADE;


--
-- Name: sms_logs sms_logs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sms_logs
    ADD CONSTRAINT sms_logs_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: stages stages_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: trips trips_alighting_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_alighting_stage_id_fkey FOREIGN KEY (alighting_stage_id) REFERENCES public.stages(id);


--
-- Name: trips trips_boarding_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_boarding_stage_id_fkey FOREIGN KEY (boarding_stage_id) REFERENCES public.stages(id);


--
-- Name: trips trips_bus_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_bus_id_fkey FOREIGN KEY (bus_id) REFERENCES public.buses(id);


--
-- Name: trips trips_original_bus_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_original_bus_id_fkey FOREIGN KEY (original_bus_id) REFERENCES public.buses(id);


--
-- Name: trips trips_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.routes(id);


--
-- Name: trips trips_schedule_master_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_schedule_master_id_fkey FOREIGN KEY (schedule_master_id) REFERENCES public.schedule_masters(id) ON DELETE SET NULL;


--
-- Name: trips trips_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trips
    ADD CONSTRAINT trips_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: audit_log Audit log: admin read tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Audit log: admin read tenant" ON public.audit_log FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: audit_log Audit log: super_admin read all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Audit log: super_admin read all" ON public.audit_log FOR SELECT USING (public.is_super_admin());


--
-- Name: booking_passengers Booking passengers: passenger own bookings; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Booking passengers: passenger own bookings" ON public.booking_passengers FOR SELECT USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE (b.booked_by_profile_id = public.current_profile_id()))));


--
-- Name: booking_passengers Booking passengers: staff admin tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Booking passengers: staff admin tenant" ON public.booking_passengers FOR SELECT USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE ((b.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: booking_passengers Booking passengers: staff admin update tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Booking passengers: staff admin update tenant" ON public.booking_passengers FOR UPDATE USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE ((b.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text])))))) WITH CHECK ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE ((b.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: booking_passengers Booking passengers: super_admin all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Booking passengers: super_admin all" ON public.booking_passengers USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: bookings Bookings: passenger insert own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Bookings: passenger insert own" ON public.bookings FOR INSERT WITH CHECK (((booked_by_profile_id = public.current_profile_id()) AND (public."current_role"() = 'passenger'::text)));


--
-- Name: bookings Bookings: passenger read own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Bookings: passenger read own" ON public.bookings FOR SELECT USING ((booked_by_profile_id = public.current_profile_id()));


--
-- Name: bookings Bookings: passenger update own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Bookings: passenger update own" ON public.bookings FOR UPDATE USING ((booked_by_profile_id = public.current_profile_id())) WITH CHECK ((booked_by_profile_id = public.current_profile_id()));


--
-- Name: bookings Bookings: staff admin insert tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Bookings: staff admin insert tenant" ON public.bookings FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: bookings Bookings: staff admin read tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Bookings: staff admin read tenant" ON public.bookings FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: bookings Bookings: staff admin update tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Bookings: staff admin update tenant" ON public.bookings FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: bookings Bookings: super_admin all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Bookings: super_admin all" ON public.bookings USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: buses Buses: admin manage; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Buses: admin manage" ON public.buses USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: buses Buses: super_admin all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Buses: super_admin all" ON public.buses USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: buses Buses: tenant read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Buses: tenant read" ON public.buses FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: payments Payments: passenger own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Payments: passenger own" ON public.payments FOR SELECT USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE (b.booked_by_profile_id = public.current_profile_id()))));


--
-- Name: payments Payments: passenger update own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Payments: passenger update own" ON public.payments FOR UPDATE USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE (b.booked_by_profile_id = public.current_profile_id())))) WITH CHECK ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE (b.booked_by_profile_id = public.current_profile_id()))));


--
-- Name: payments Payments: staff admin tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Payments: staff admin tenant" ON public.payments FOR SELECT USING ((booking_id IN ( SELECT b.id
   FROM public.bookings b
  WHERE ((b.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: payments Payments: super_admin all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Payments: super_admin all" ON public.payments USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: profiles Profiles: admin read tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Profiles: admin read tenant" ON public.profiles FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: profiles Profiles: admin update tenant roles; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Profiles: admin update tenant roles" ON public.profiles FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])) AND (role = ANY (ARRAY['passenger'::text, 'staff'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (role = ANY (ARRAY['passenger'::text, 'staff'::text]))));


--
-- Name: profiles Profiles: read own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Profiles: read own" ON public.profiles FOR SELECT USING ((id = public.current_profile_id()));


--
-- Name: profiles Profiles: super_admin read all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Profiles: super_admin read all" ON public.profiles FOR SELECT USING (public.is_super_admin());


--
-- Name: profiles Profiles: update own non-role; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Profiles: update own non-role" ON public.profiles FOR UPDATE USING ((id = public.current_profile_id())) WITH CHECK (((id = public.current_profile_id()) AND (role = public."current_role"())));


--
-- Name: role_permissions Role permissions: read all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Role permissions: read all" ON public.role_permissions FOR SELECT USING (true);


--
-- Name: routes Routes: admin manage; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Routes: admin manage" ON public.routes USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: routes Routes: super_admin all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Routes: super_admin all" ON public.routes USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: routes Routes: tenant read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Routes: tenant read" ON public.routes FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: seat_assignments Seat assignments: passenger own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Seat assignments: passenger own" ON public.seat_assignments FOR SELECT USING ((booking_passenger_id IN ( SELECT bp.id
   FROM (public.booking_passengers bp
     JOIN public.bookings b ON ((b.id = bp.booking_id)))
  WHERE (b.booked_by_profile_id = public.current_profile_id()))));


--
-- Name: seat_assignments Seat assignments: staff admin manage tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Seat assignments: staff admin manage tenant" ON public.seat_assignments USING ((trip_id IN ( SELECT t.id
   FROM public.trips t
  WHERE ((t.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text])))))) WITH CHECK ((trip_id IN ( SELECT t.id
   FROM public.trips t
  WHERE ((t.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: seat_assignments Seat assignments: staff admin tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Seat assignments: staff admin tenant" ON public.seat_assignments FOR SELECT USING ((trip_id IN ( SELECT t.id
   FROM public.trips t
  WHERE ((t.tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))))));


--
-- Name: seat_assignments Seat assignments: super_admin all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Seat assignments: super_admin all" ON public.seat_assignments USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: stages Stages: admin manage; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Stages: admin manage" ON public.stages USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: stages Stages: super_admin all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Stages: super_admin all" ON public.stages USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: stages Stages: tenant read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Stages: tenant read" ON public.stages FOR SELECT USING ((tenant_id = public.current_tenant_id()));


--
-- Name: tenants Tenants: admin update own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Tenants: admin update own" ON public.tenants FOR UPDATE USING (((id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text])))) WITH CHECK (((id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: tenants Tenants: read own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Tenants: read own" ON public.tenants FOR SELECT USING ((id = public.current_tenant_id()));


--
-- Name: tenants Tenants: super_admin read all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Tenants: super_admin read all" ON public.tenants FOR SELECT USING (public.is_super_admin());


--
-- Name: trips Trips: admin delete tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Trips: admin delete tenant" ON public.trips FOR DELETE USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['admin'::text, 'super_admin'::text]))));


--
-- Name: trips Trips: passengers read published globally; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Trips: passengers read published globally" ON public.trips FOR SELECT USING (((status = ANY (ARRAY['scheduled'::text, 'active'::text])) AND (public."current_role"() = 'passenger'::text)));


--
-- Name: trips Trips: staff and admin insert tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Trips: staff and admin insert tenant" ON public.trips FOR INSERT WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: trips Trips: staff and admin read tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Trips: staff and admin read tenant" ON public.trips FOR SELECT USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: trips Trips: staff and admin update tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Trips: staff and admin update tenant" ON public.trips FOR UPDATE USING (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text])))) WITH CHECK (((tenant_id = public.current_tenant_id()) AND (public."current_role"() = ANY (ARRAY['staff'::text, 'admin'::text, 'super_admin'::text]))));


--
-- Name: trips Trips: super_admin all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Trips: super_admin all" ON public.trips USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());


--
-- Name: ads Users can view ads for their tenant; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Users can view ads for their tenant" ON public.ads FOR SELECT TO authenticated USING (("tenantId" = ((auth.jwt() ->> 'tenant_id'::text))::uuid));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: postgres
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO anon;
GRANT ALL ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION archive_old_audit_logs(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.archive_old_audit_logs() TO anon;
GRANT ALL ON FUNCTION public.archive_old_audit_logs() TO authenticated;


--
-- Name: FUNCTION audit_table_change(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.audit_table_change() TO anon;
GRANT ALL ON FUNCTION public.audit_table_change() TO authenticated;


--
-- Name: FUNCTION auto_update_trip_statuses(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.auto_update_trip_statuses() TO anon;
GRANT ALL ON FUNCTION public.auto_update_trip_statuses() TO authenticated;


--
-- Name: FUNCTION check_bus_conflicts(p_tenant_id uuid, p_bus_id bigint, p_departure_datetime timestamp with time zone, p_arrival_datetime timestamp with time zone, p_exclude_trip_id bigint); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.check_bus_conflicts(p_tenant_id uuid, p_bus_id bigint, p_departure_datetime timestamp with time zone, p_arrival_datetime timestamp with time zone, p_exclude_trip_id bigint) TO anon;
GRANT ALL ON FUNCTION public.check_bus_conflicts(p_tenant_id uuid, p_bus_id bigint, p_departure_datetime timestamp with time zone, p_arrival_datetime timestamp with time zone, p_exclude_trip_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.check_bus_conflicts(p_tenant_id uuid, p_bus_id bigint, p_departure_datetime timestamp with time zone, p_arrival_datetime timestamp with time zone, p_exclude_trip_id bigint) TO service_role;


--
-- Name: FUNCTION check_in_passenger(p_ticket_token uuid, p_staff_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.check_in_passenger(p_ticket_token uuid, p_staff_id uuid) TO anon;
GRANT ALL ON FUNCTION public.check_in_passenger(p_ticket_token uuid, p_staff_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.check_in_passenger(p_ticket_token uuid, p_staff_id uuid) TO service_role;


--
-- Name: FUNCTION current_profile_id(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.current_profile_id() TO anon;
GRANT ALL ON FUNCTION public.current_profile_id() TO authenticated;
GRANT ALL ON FUNCTION public.current_profile_id() TO service_role;


--
-- Name: FUNCTION "current_role"(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public."current_role"() TO anon;
GRANT ALL ON FUNCTION public."current_role"() TO authenticated;
GRANT ALL ON FUNCTION public."current_role"() TO service_role;


--
-- Name: FUNCTION current_tenant_id(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.current_tenant_id() TO anon;
GRANT ALL ON FUNCTION public.current_tenant_id() TO authenticated;
GRANT ALL ON FUNCTION public.current_tenant_id() TO service_role;


--
-- Name: FUNCTION enforce_seat_assignment(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.enforce_seat_assignment() TO anon;
GRANT ALL ON FUNCTION public.enforce_seat_assignment() TO authenticated;
GRANT ALL ON FUNCTION public.enforce_seat_assignment() TO service_role;


--
-- Name: FUNCTION generate_booking_token(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.generate_booking_token() TO anon;
GRANT ALL ON FUNCTION public.generate_booking_token() TO authenticated;


--
-- Name: FUNCTION generate_ticket_number(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.generate_ticket_number() TO anon;
GRANT ALL ON FUNCTION public.generate_ticket_number() TO authenticated;
GRANT ALL ON FUNCTION public.generate_ticket_number() TO service_role;


--
-- Name: FUNCTION get_booked_counts(trip_ids bigint[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.get_booked_counts(trip_ids bigint[]) TO anon;
GRANT ALL ON FUNCTION public.get_booked_counts(trip_ids bigint[]) TO authenticated;


--
-- Name: FUNCTION get_leg_fare(p_route_id bigint, p_board_id bigint, p_alight_id bigint); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.get_leg_fare(p_route_id bigint, p_board_id bigint, p_alight_id bigint) TO anon;
GRANT ALL ON FUNCTION public.get_leg_fare(p_route_id bigint, p_board_id bigint, p_alight_id bigint) TO authenticated;


--
-- Name: FUNCTION get_or_create_profile(p_full_name text, p_phone text, p_national_id text, p_tenant_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.get_or_create_profile(p_full_name text, p_phone text, p_national_id text, p_tenant_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_or_create_profile(p_full_name text, p_phone text, p_national_id text, p_tenant_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_or_create_profile(p_full_name text, p_phone text, p_national_id text, p_tenant_id uuid) TO service_role;


--
-- Name: FUNCTION get_user_permissions(user_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.get_user_permissions(user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_user_permissions(user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_user_permissions(user_id uuid) TO service_role;


--
-- Name: FUNCTION handle_booking_confirmation(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.handle_booking_confirmation() TO anon;
GRANT ALL ON FUNCTION public.handle_booking_confirmation() TO authenticated;


--
-- Name: FUNCTION handle_booking_confirmation_notification(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.handle_booking_confirmation_notification() TO anon;
GRANT ALL ON FUNCTION public.handle_booking_confirmation_notification() TO authenticated;


--
-- Name: FUNCTION handle_new_user(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.handle_new_user() TO anon;
GRANT ALL ON FUNCTION public.handle_new_user() TO authenticated;
GRANT ALL ON FUNCTION public.handle_new_user() TO service_role;


--
-- Name: FUNCTION handle_new_user_sync(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.handle_new_user_sync() TO anon;
GRANT ALL ON FUNCTION public.handle_new_user_sync() TO authenticated;
GRANT ALL ON FUNCTION public.handle_new_user_sync() TO service_role;


--
-- Name: FUNCTION immutable_date(ts timestamp with time zone); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.immutable_date(ts timestamp with time zone) TO anon;
GRANT ALL ON FUNCTION public.immutable_date(ts timestamp with time zone) TO authenticated;


--
-- Name: FUNCTION is_super_admin(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.is_super_admin() TO anon;
GRANT ALL ON FUNCTION public.is_super_admin() TO authenticated;
GRANT ALL ON FUNCTION public.is_super_admin() TO service_role;


--
-- Name: FUNCTION log_profile_role_changes(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.log_profile_role_changes() TO anon;
GRANT ALL ON FUNCTION public.log_profile_role_changes() TO authenticated;
GRANT ALL ON FUNCTION public.log_profile_role_changes() TO service_role;


--
-- Name: FUNCTION search_trips_smart(p_origin text, p_destination text, p_travel_date date); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.search_trips_smart(p_origin text, p_destination text, p_travel_date date) TO anon;
GRANT ALL ON FUNCTION public.search_trips_smart(p_origin text, p_destination text, p_travel_date date) TO authenticated;


--
-- Name: FUNCTION send_booking_reminder(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.send_booking_reminder() TO anon;
GRANT ALL ON FUNCTION public.send_booking_reminder() TO authenticated;


--
-- Name: FUNCTION send_booking_sms(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.send_booking_sms() TO anon;
GRANT ALL ON FUNCTION public.send_booking_sms() TO authenticated;


--
-- Name: FUNCTION send_notification(p_title text, p_message text, p_category public.notification_category, p_target_type text, p_profile_id uuid, p_tenant_id uuid, p_trip_id bigint, p_route_id bigint, p_sent_by_profile_id uuid, p_metadata jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.send_notification(p_title text, p_message text, p_category public.notification_category, p_target_type text, p_profile_id uuid, p_tenant_id uuid, p_trip_id bigint, p_route_id bigint, p_sent_by_profile_id uuid, p_metadata jsonb) TO anon;
GRANT ALL ON FUNCTION public.send_notification(p_title text, p_message text, p_category public.notification_category, p_target_type text, p_profile_id uuid, p_tenant_id uuid, p_trip_id bigint, p_route_id bigint, p_sent_by_profile_id uuid, p_metadata jsonb) TO authenticated;


--
-- Name: FUNCTION send_trip_delay_update(p_trip_id bigint, p_new_departure_time text, p_sent_by_profile_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.send_trip_delay_update(p_trip_id bigint, p_new_departure_time text, p_sent_by_profile_id uuid) TO anon;
GRANT ALL ON FUNCTION public.send_trip_delay_update(p_trip_id bigint, p_new_departure_time text, p_sent_by_profile_id uuid) TO authenticated;


--
-- Name: FUNCTION send_trip_update(p_trip_id bigint, p_title text, p_message text, p_sent_by_profile_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.send_trip_update(p_trip_id bigint, p_title text, p_message text, p_sent_by_profile_id uuid) TO anon;
GRANT ALL ON FUNCTION public.send_trip_update(p_trip_id bigint, p_title text, p_message text, p_sent_by_profile_id uuid) TO authenticated;


--
-- Name: FUNCTION test_send_reminder(p_profile_id uuid, p_booking_id bigint); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.test_send_reminder(p_profile_id uuid, p_booking_id bigint) TO anon;
GRANT ALL ON FUNCTION public.test_send_reminder(p_profile_id uuid, p_booking_id bigint) TO authenticated;


--
-- Name: FUNCTION trigger_set_timestamp(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.trigger_set_timestamp() TO anon;
GRANT ALL ON FUNCTION public.trigger_set_timestamp() TO authenticated;
GRANT ALL ON FUNCTION public.trigger_set_timestamp() TO service_role;


--
-- Name: FUNCTION update_user_role(target_user_id uuid, new_role text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_user_role(target_user_id uuid, new_role text) TO authenticated;
GRANT ALL ON FUNCTION public.update_user_role(target_user_id uuid, new_role text) TO anon;
GRANT ALL ON FUNCTION public.update_user_role(target_user_id uuid, new_role text) TO service_role;


--
-- Name: TABLE ads; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.ads TO anon;
GRANT ALL ON TABLE public.ads TO authenticated;
GRANT ALL ON TABLE public.ads TO service_role;


--
-- Name: SEQUENCE ads_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.ads_id_seq TO anon;
GRANT ALL ON SEQUENCE public.ads_id_seq TO authenticated;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.audit_log TO anon;
GRANT ALL ON TABLE public.audit_log TO authenticated;
GRANT ALL ON TABLE public.audit_log TO service_role;


--
-- Name: SEQUENCE audit_log_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.audit_log_id_seq TO anon;
GRANT ALL ON SEQUENCE public.audit_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.audit_log_id_seq TO service_role;


--
-- Name: TABLE audit_log_archive; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.audit_log_archive TO anon;
GRANT ALL ON TABLE public.audit_log_archive TO authenticated;
GRANT ALL ON TABLE public.audit_log_archive TO service_role;


--
-- Name: TABLE booking_passengers; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.booking_passengers TO anon;
GRANT ALL ON TABLE public.booking_passengers TO authenticated;
GRANT ALL ON TABLE public.booking_passengers TO service_role;


--
-- Name: SEQUENCE booking_passengers_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.booking_passengers_id_seq TO anon;
GRANT ALL ON SEQUENCE public.booking_passengers_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.booking_passengers_id_seq TO service_role;


--
-- Name: TABLE booking_reschedules; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.booking_reschedules TO anon;
GRANT ALL ON TABLE public.booking_reschedules TO authenticated;
GRANT ALL ON TABLE public.booking_reschedules TO service_role;


--
-- Name: SEQUENCE booking_reschedules_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.booking_reschedules_id_seq TO anon;
GRANT ALL ON SEQUENCE public.booking_reschedules_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.booking_reschedules_id_seq TO service_role;


--
-- Name: TABLE bookings; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.bookings TO anon;
GRANT ALL ON TABLE public.bookings TO authenticated;
GRANT ALL ON TABLE public.bookings TO service_role;


--
-- Name: SEQUENCE bookings_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.bookings_id_seq TO anon;
GRANT ALL ON SEQUENCE public.bookings_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.bookings_id_seq TO service_role;


--
-- Name: TABLE buses; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.buses TO anon;
GRANT ALL ON TABLE public.buses TO authenticated;
GRANT ALL ON TABLE public.buses TO service_role;


--
-- Name: SEQUENCE buses_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.buses_id_seq TO anon;
GRANT ALL ON SEQUENCE public.buses_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.buses_id_seq TO service_role;


--
-- Name: TABLE migrations; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.migrations TO anon;
GRANT ALL ON TABLE public.migrations TO authenticated;
GRANT ALL ON TABLE public.migrations TO service_role;


--
-- Name: SEQUENCE migrations_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.migrations_id_seq TO anon;
GRANT ALL ON SEQUENCE public.migrations_id_seq TO authenticated;


--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.notifications TO anon;
GRANT ALL ON TABLE public.notifications TO authenticated;
GRANT ALL ON TABLE public.notifications TO service_role;


--
-- Name: TABLE payments; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.payments TO anon;
GRANT ALL ON TABLE public.payments TO authenticated;
GRANT ALL ON TABLE public.payments TO service_role;


--
-- Name: SEQUENCE payments_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.payments_id_seq TO anon;
GRANT ALL ON SEQUENCE public.payments_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.payments_id_seq TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.profiles TO anon;
GRANT ALL ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;


--
-- Name: TABLE refunds; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.refunds TO anon;
GRANT ALL ON TABLE public.refunds TO authenticated;
GRANT ALL ON TABLE public.refunds TO service_role;


--
-- Name: SEQUENCE refunds_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.refunds_id_seq TO anon;
GRANT ALL ON SEQUENCE public.refunds_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.refunds_id_seq TO service_role;


--
-- Name: TABLE role_permissions; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.role_permissions TO anon;
GRANT ALL ON TABLE public.role_permissions TO authenticated;
GRANT ALL ON TABLE public.role_permissions TO service_role;


--
-- Name: SEQUENCE role_permissions_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.role_permissions_id_seq TO anon;
GRANT ALL ON SEQUENCE public.role_permissions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.role_permissions_id_seq TO service_role;


--
-- Name: TABLE route_fares; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.route_fares TO anon;
GRANT ALL ON TABLE public.route_fares TO authenticated;
GRANT ALL ON TABLE public.route_fares TO service_role;


--
-- Name: SEQUENCE route_fares_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.route_fares_id_seq TO anon;
GRANT ALL ON SEQUENCE public.route_fares_id_seq TO authenticated;


--
-- Name: TABLE routes; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.routes TO anon;
GRANT ALL ON TABLE public.routes TO authenticated;
GRANT ALL ON TABLE public.routes TO service_role;


--
-- Name: SEQUENCE routes_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.routes_id_seq TO anon;
GRANT ALL ON SEQUENCE public.routes_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.routes_id_seq TO service_role;


--
-- Name: TABLE schedule_masters; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.schedule_masters TO anon;
GRANT ALL ON TABLE public.schedule_masters TO authenticated;
GRANT ALL ON TABLE public.schedule_masters TO service_role;


--
-- Name: SEQUENCE schedule_masters_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.schedule_masters_id_seq TO anon;
GRANT ALL ON SEQUENCE public.schedule_masters_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.schedule_masters_id_seq TO service_role;


--
-- Name: TABLE seat_assignments; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.seat_assignments TO anon;
GRANT ALL ON TABLE public.seat_assignments TO authenticated;
GRANT ALL ON TABLE public.seat_assignments TO service_role;


--
-- Name: SEQUENCE seat_assignments_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.seat_assignments_id_seq TO anon;
GRANT ALL ON SEQUENCE public.seat_assignments_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.seat_assignments_id_seq TO service_role;


--
-- Name: TABLE sms_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sms_logs TO anon;
GRANT ALL ON TABLE public.sms_logs TO authenticated;
GRANT ALL ON TABLE public.sms_logs TO service_role;


--
-- Name: SEQUENCE sms_logs_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.sms_logs_id_seq TO anon;
GRANT ALL ON SEQUENCE public.sms_logs_id_seq TO authenticated;


--
-- Name: TABLE stages; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.stages TO anon;
GRANT ALL ON TABLE public.stages TO authenticated;
GRANT ALL ON TABLE public.stages TO service_role;


--
-- Name: SEQUENCE stages_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.stages_id_seq TO anon;
GRANT ALL ON SEQUENCE public.stages_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.stages_id_seq TO service_role;


--
-- Name: TABLE tenants; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.tenants TO anon;
GRANT ALL ON TABLE public.tenants TO authenticated;
GRANT ALL ON TABLE public.tenants TO service_role;


--
-- Name: TABLE trips; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.trips TO anon;
GRANT ALL ON TABLE public.trips TO authenticated;
GRANT ALL ON TABLE public.trips TO service_role;


--
-- Name: SEQUENCE trips_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.trips_id_seq TO anon;
GRANT ALL ON SEQUENCE public.trips_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.trips_id_seq TO service_role;


--
-- Name: TABLE v_booking_notification; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v_booking_notification TO anon;
GRANT ALL ON TABLE public.v_booking_notification TO authenticated;
GRANT ALL ON TABLE public.v_booking_notification TO service_role;


--
-- Name: TABLE v_daily_sales_report; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v_daily_sales_report TO anon;
GRANT ALL ON TABLE public.v_daily_sales_report TO authenticated;
GRANT ALL ON TABLE public.v_daily_sales_report TO service_role;


--
-- Name: TABLE v_passenger_manifest; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v_passenger_manifest TO anon;
GRANT ALL ON TABLE public.v_passenger_manifest TO authenticated;
GRANT ALL ON TABLE public.v_passenger_manifest TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--

\unrestrict P9Gr7Thc0bis1DNpczOBZkdzZCLGVoFp7Jk5hPKTsWHfP2vIn2TpqNdmj4ShOEP

