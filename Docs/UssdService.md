# UssdService

This service handles the USSD booking flow for TicketEase. It reads the incoming USSD payload, manages per-session cached state, loads routes from the database, and returns plain-text responses that start with `CON` or `END`.

## Overview

The service currently supports these user paths:

- Main menu display
- Booking entry point
- Dynamic route selection from `public.routes`
- Passenger count capture
- Travel date capture and validation
- Trip selection from `public.trips`
- Booking confirmation or cancellation
- Registration flow with Supabase/Postgres via `get_or_create_profile`
- Placeholder handling for other non-implemented states

## Methods

### `handle(Request $request): string`

Entry point for every USSD request.

Responsibilities:

- Reads `sessionId`, `phoneNumber`, and `text` from the request
- Logs the inbound payload
- Parses USSD input into a token array using `*`
- Loads the current session state from cache using `ussd_{sessionId}_state`
- Shows the main menu on first request or when `text` is empty
- Routes the request to booking, registration, or continuation handlers

Cached keys used:

- `ussd_{sessionId}_state`
- `ussd_{sessionId}_phone`

Returns:

- `CON ...` to continue the session
- `END ...` to terminate the session

### `handleRegistration($sessionId, $phone, $userInput): string`

Runs the three-step registration flow.

Flow:

1. Step 1: asks for the user’s full name
2. Step 2: stores full name and asks for National ID
3. Step 3: calls `public.get_or_create_profile(...)` in the database

Cached keys used:

- `ussd_{sessionId}_reg_step`
- `ussd_{sessionId}_full_name`

Database call:

- `SELECT public.get_or_create_profile(?, ?, ?, NULL) as id`

Returns:

- `CON Enter your Full Name:`
- `CON Enter your National ID:`
- `END Registration successful! ...`
- `END Sorry, registration failed. Please try again later.`

### `startBooking($sessionId, $phone): string`

Starts the booking flow and shows available routes.

Responsibilities:

- Sets session state to `booking_route`
- Stores the caller phone number in cache
- Fetches route rows from `public.routes`
- Normalizes route rows into plain arrays before caching
- Logs the available routes
- Builds a menu from the database rows

Database query:

- `SELECT id, route_code, base_fare FROM public.routes ORDER BY id`

Cached keys used:

- `ussd_{sessionId}_state`
- `ussd_{sessionId}_phone`
- `ussd_{sessionId}_route_options`

Returns:

- A `CON` route selection menu
- `END ...` if routes cannot be loaded

### `continueFlow($sessionId, $phone, $userInput, $state): string`

Handles all non-menu states.

Current behavior:

- If the state is `booking_route`, it reads the cached route list
- If route options are missing, it reloads them by calling `startBooking()`
- Validates the selected route index
- Supports the back option
- Stores the selected route ID in cache
- Moves the state to `booking_passengers` and prompts for passenger count
- Validates passenger count (allowed range: 1-10)
- Moves to `booking_travel_date` and asks for date in `YYYY-MM-DD`
- Validates date format and blocks past dates
- Loads available trips for selected route/date and moves to `booking_trip`
- Validates trip selection and supports changing the date
- Moves to `booking_confirm` and shows booking summary (including selected trip)
- On confirm, persists booking records in DB using selected `trip_id`
- On cancel, clears booking cache and ends the session

Cached keys used:

- `ussd_{sessionId}_route_options`
- `ussd_{sessionId}_selected_route_id`
- `ussd_{sessionId}_trip_options`
- `ussd_{sessionId}_selected_trip_id`
- `ussd_{sessionId}_passenger_count`
- `ussd_{sessionId}_travel_date`
- `ussd_{sessionId}_state`

Returns:

- `CON Selected: ...`
- `CON Enter number of passengers (1-10):`
- `CON Enter travel date (YYYY-MM-DD):`
- `CON Select trip:`
- `CON Confirm Booking ...`
- `END Booking confirmed!` including DB booking reference and `ticket_token`
- `END Booking cancelled ...`
- `CON Feature coming soon...` for unimplemented states

### `startTripSelection(string $sessionId): string`

Loads trips for the selected route and travel date.

Query behavior:

- Filters by `route_id`
- Filters by date portion of `departure_datetime`
- Allows `scheduled` and `active` trips
- Orders by `departure_datetime`

State updates:

- Stores normalized trip options in `ussd_{sessionId}_trip_options`
- Moves state to `booking_trip`

### `normalizeTripOptions(array $trips): array`

Normalizes trip rows into cache-safe arrays.

Output includes:

- `id`
- `departure_datetime`
- `status`
- `display_label`

### `tripDisplayLabel(string $departureDatetime, string $status): string`

Formats one trip entry label for USSD list display.

Example:

- `07:30 (SCHEDULED)`

### `selectedTripLabel(string $sessionId): string`

Resolves the selected trip from cached options and returns its display label.

### `createTripBooking(string $sessionId, string $phone): ?array`

Creates and persists a trip booking using cached booking state.

What it writes:

- `public.bookings` row with:
    - `tenant_id`
    - `trip_id`
    - `route_id`
    - `booking_type = 'ussd'`
    - `total_passengers`
    - `total_fare`
    - `status = 'confirmed'`
    - `is_open_ticket = false`
- `public.booking_passengers` rows (one per passenger)

Returned values:

- `ticket_number` (trigger-generated)

Notes:

- Inserts are wrapped in a transaction
- Returns `null` on validation or persistence failure

### `bookingSummary(string $sessionId): string`

Builds the multi-line summary shown on the confirmation screen.

Summary fields:

- Route label
- Passenger count
- Travel date

### `selectedRouteLabel(string $sessionId): string`

Resolves the selected route label from cached route options using `selected_route_id`.

Returns:

- `display_label` for the selected route
- `Unknown Route` if no match is found

### `clearBookingSessionData(string $sessionId): void`

Clears booking-related cache keys after booking confirmation or cancellation.

Cleared keys:

- `ussd_{sessionId}_route_options`
- `ussd_{sessionId}_selected_route_id`
- `ussd_{sessionId}_passenger_count`
- `ussd_{sessionId}_travel_date`
- `ussd_{sessionId}_state`

### `normalizeRouteOptions(array $routes): array`

Converts DB rows or cached route records into plain arrays.

Why it exists:

- Laravel cache can serialize objects in ways that become fragile across requests
- Converting to arrays avoids incomplete-object issues when route options are restored from cache

Input accepted:

- Raw DB rows
- Already-cached arrays
- Cached objects from older sessions

Output shape:

```php
[
    [
        'id' => 1,
        'route_code' => 'Lilongwe - Blantyre',
        'base_fare' => '85000.00',
    ],
]
```

## Important Cache States

- `start` - initial state before menu rendering
- `menu` - main menu state
- `booking_route` - route selection state
- `booking_passengers` - asks passenger count
- `booking_travel_date` - asks and validates travel date
- `booking_trip` - asks user to choose one available trip for selected date
- `booking_confirm` - confirmation or cancellation step
- `reg_step` - registration step tracker

## Notes

- Route data comes from `public.routes`
- Booking continuation now captures passengers, date, and required trip selection before confirm/cancel
- The route selection path is now dynamic, not hardcoded
- The code currently logs available routes for debugging
