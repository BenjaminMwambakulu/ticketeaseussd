# SMS & USSD Testing Design (2026‑05‑11)

## Overview
This design defines a **hybrid testing strategy (Approach C)** for the TicketEase SMS sending and USSD interaction features. It combines fast unit tests for core logic with a small set of feature tests that validate the Laravel request pipeline, ensuring confidence while keeping maintenance low.

---

## Test Structure
```
tests/
├─ Unit/
│  └─ Services/
│     ├─ SendSmsServiceTest.php   # SMS splitting unit tests
│     └─ UssdServiceTest.php      # USSD state‑machine unit tests
├─ Feature/
│  ├─ SmsSendingTest.php          # Feature test for the SMS endpoint
│  └─ UssdFlowTest.php            # Feature test for the USSD controller
├─ Pest.php                        # Pest bootstrap (already present)
└─ TestCase.php                    # Base test case (already present)
```

### Naming Conventions
- Unit tests live under `tests/Unit/Services` and focus on **single‑method** behavior.
- Feature tests live under `tests/Feature` and exercise the **full HTTP request lifecycle** (routing, middleware, service, logging).
- Each test class mirrors the class it validates (`SendSmsServiceTest` → `SendSmsService`).

---

## Unit Test Cases
### `tests/Unit/Services/SendSmsServiceTest.php`
1. **Boundary lengths** – messages exactly at the 120‑char limit, just above, and far above (multiple parts).
2. **Multipart formatting** – verify that when `splitMessage` returns multiple parts each part is prefixed with `(n/m) `.
3. **Unicode & newline handling** – messages containing emojis or line breaks are split without breaking UTF‑8 characters and preserve line breaks.
4. **Empty message** – ensure an empty string returns a single empty part (or throws a validation exception if the service validates input).
5. **Dataset usage** – reuse edge‑case messages via Pest datasets for DRY tests.

### `tests/Unit/Services/UssdServiceTest.php`
1. **State transitions** – start a session, move through a typical navigation flow, and reach the final state.
2. **Invalid selections** – providing an out‑of‑range option returns the expected error response.
3. **Session expiration** – simulate a stale session and verify the service aborts with a timeout message.
4. **Navigation flow** – test forward/back navigation logic (if present).
5. **Dataset usage** – define reusable USSD input scenarios.

---

## Feature Test Cases
### `tests/Feature/SmsSendingTest.php`
- **Setup** – `Http::fake()` is configured in `setUp()` to intercept calls to `{$baseUrl}/messages/send`.
- **Happy path – single part** – send a short message to one recipient; assert a single HTTP request with correct payload.
- **Happy path – multipart** – send a long message; assert **multiple** HTTP requests, each containing the `(n/m)` prefix and correct `to` number.
- **Provider failure** – configure `Http::fake()` to return a 500 error for the first request; assert that the service logs the failure and the response collection contains the error response.
- **Multiple recipients** – send to several numbers; assert the request count equals `recipients × parts`.

### `tests/Feature/UssdFlowTest.php`
- **Setup** – `Http::fake()` (if USSD service calls external APIs) and `Queue::fake()` for any async jobs.
- **Controller lifecycle** – issue a `POST /api/ussd` (or the actual route) with a valid payload; assert a 200 response and correct JSON structure.
- **Session progression** – simulate a sequence of USSD inputs across multiple requests, asserting the session state evolves as expected.
- **Invalid input** – send an out‑of‑range selection; assert a 422 (or defined) error response.
- **Timeout / end‑session** – mock a stale session and verify the controller returns a timeout/end‑session message.

---

## Shared Test Utilities
- **Pest datasets** (`tests/Datasets/SmsMessages.php`, `tests/Datasets/UssdScenarios.php`) containing edge‑case message strings and USSD input sequences.
- **Factory helpers** (`tests/Helpers/UssdSessionFactory.php`) to create a persisted USSD session record (if stored) for feature tests.
- **Global test setup** – add to `tests/Pest.php`:
  ```php
  beforeEach(function () {
      Http::preventStrayRequests();
      Http::fake();
      Queue::fake();
  });
  ```
- **Deterministic timestamps** – optional `Carbon::setTestNow()` for time‑sensitive logic.

---

## CI Integration
- The test suite runs on every push via the existing GitHub Actions workflow (`phpunit` step). Ensure the workflow installs Pest (`composer require pestphp/pest --dev`).
- No external API keys are required because `Http::fake()` isolates external calls.
- Aim for **≥ 80 % line coverage** on the `SendSmsService` and `UssdService` classes; the feature tests cover the controller/route layer.

---

## Acceptance Criteria
- All unit tests pass locally with **`vendor/bin/pest`**.
- Feature tests run without real network calls and assert the correct number of HTTP requests.\
- CI reports ≥ 80 % coverage for the targeted classes.
- Documentation of the test layout is committed to the repository for future contributors.

---

*Please review this design document. If any changes are needed, let me know and I will update it before we move on to the implementation plan.*