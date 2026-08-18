# Auth email templates

Branded replacements for the six default Supabase auth emails, in the Clay
Court palette (`lib/frontend/theme/app_colors.dart`).

These files are **not deployed by anything**. There is no `supabase/config.toml`
in this repo — the project is managed from the dashboard — so the templates live
here as the source of truth and get pasted into
**Authentication → Emails → Templates**. Edit the file, paste it again.

| File | Dashboard template | Carries |
|---|---|---|
| `confirm_signup.html` | Confirm signup | `{{ .Token }}` — 6-digit code |
| `magic_link.html` | Magic Link | `{{ .Token }}` |
| `change_email.html` | Change Email Address | `{{ .Token }}` |
| `reauthentication.html` | Reauthentication | `{{ .Token }}` |
| `reset_password.html` | Reset Password | `{{ .ConfirmationURL }}` — **link, not a code** |
| `invite.html` | Invite user | `{{ .ConfirmationURL }}` |

## Subjects

Set these in the Subject field above each template. The code is in the subject
on purpose — it shows in the phone's notification, so most people never open
the email at all.

| Template | Subject |
|---|---|
| Confirm signup | `{{ .Token }} is your Padel Rivals code` |
| Magic Link | `{{ .Token }} is your Padel Rivals sign-in code` |
| Change Email Address | `{{ .Token }} — confirm your new email` |
| Reauthentication | `{{ .Token }} is your Padel Rivals confirmation code` |
| Reset Password | `Reset your Padel Rivals password` |
| Invite user | `You've been invited to Padel Rivals` |

## Do not swap Reset Password to a code

It is the one flow that **must** stay a link. `{{ .ConfirmationURL }}` redirects
to `padelrivals://reset-password/`, which Android routes to MainActivity, which
supabase_flutter turns into an `AuthChangeEvent.passwordRecovery`, which is what
puts `AuthGate` into `_Phase.recovering` → `SetPasswordScreen`. There is no
screen anywhere that accepts a typed recovery code, so switching this template
to `{{ .Token }}` mails people a code with nowhere to enter it.

Same for Invite: `create-staff` provisions accounts with `email_confirm: true`
and a temp password rather than inviting, so this template is currently unused —
keep it correct in case that changes, don't build a flow on it.

## Rules these files follow (keep them if you edit)

- **Tables, not divs, for layout.** Outlook renders through Word; flexbox and
  grid do nothing there.
- **Every style inline.** Gmail strips `<style>` blocks in some contexts, and
  there is no second chance to notice — the email just arrives unstyled.
- **No images at all.** Most clients block remote images by default, so a logo
  would land as a grey box; the wordmark is a coloured table cell with a letter
  in it. (`assets/brand/logo.png` is also 2.4 MB, which is not an email asset.)
- **Light-mode only** (`color-scheme: light`), with every background set
  explicitly. The warm palette inverts badly under client dark-mode heuristics.
- **A hidden preheader** as the first element — otherwise the inbox preview line
  is scraped from the wordmark and reads "P Padel Rivals".
- **No Go template conditionals** (`{{ if }}`). A template that fails to parse
  does not send *at all*, and for Confirm signup that means nobody can register.
  Only bare substitutions are used. If you want to greet by name, the variable
  is `{{ .Data.name }}` (signup writes it) — test it on a throwaway account
  first, because it renders empty for OAuth users.

Available variables: `{{ .Token }}`, `{{ .TokenHash }}`, `{{ .ConfirmationURL }}`,
`{{ .SiteURL }}`, `{{ .RedirectTo }}`, `{{ .Email }}`, `{{ .NewEmail }}`,
`{{ .Data.<key> }}`.

## Turning on email confirmation — order matters

1. **Check who would be locked out first.** Flipping the toggle blocks sign-in
   for any existing account with no `email_confirmed_at`:

   ```sql
   select id, email, created_at
   from auth.users
   where email_confirmed_at is null
   order by created_at;
   ```

   Accounts created while confirmation was OFF normally have it stamped already,
   and Google/Apple accounts always do — so this should come back empty or close
   to it. Confirm any stragglers by hand in **Authentication → Users → ⋯ →
   Confirm email** rather than by `update`ing `auth.users`.

2. **Paste the templates** (above). Do this *before* the toggle, so the first
   real signup gets the branded mail, not the default one.

3. **Authentication → Sign In / Providers → Email**
   - `Confirm email` → **ON**
   - `Email OTP Expiration` → `3600` (1 hour). The templates say "1 hour"; if
     you change one, change the other.

4. **Authentication → Rate Limits → "Rate limit for sending emails".** Enabling
   custom SMTP does *not* raise this — it stays at the default (30/hour) and
   silently throttles signups at launch. Raise it to match what Resend allows
   (free tier: 100/day, 3,000/month).

5. **Send yourself one of each.** The dashboard preview does not run through
   Resend, so it proves nothing about deliverability or about the subject line.

## What the app already does

- `AuthService.signUp` returns `sessionCreated: false` when confirmation is on;
  `AuthFlow` then shows `CheckEmailScreen`, which is the 6-digit code entry.
- `AuthService.verifySignupCode` calls `verifyOTP(type: signup)`. Success creates
  the session, `AuthGate` hears `signedIn` and moves the app on by itself.
- The sign-up photo is uploaded at *verify* time, not signup — with confirmation
  on there is no session (and so no storage RLS identity) until then.
- `AuthService.resendSignupCode` has a 60s client cooldown, started by `signUp`
  itself so the first tap on Resend can't burn a send for nothing.

## Phone verification

Not built. It needs a paid SMS provider (Twilio/MessageBird/Vonage) wired under
**Authentication → Sign In / Providers → Phone**, and in Egypt an NTRA-approved
sender ID before +20 numbers will accept messages. `profiles.phone` stays an
unverified self-declared field until that exists.
